/*
 * mb_tfl_dispatch.c — tflite_ffi stub/real 双路径 C dispatch（WP-1, 2026-11-08）
 *
 * 【定位】契约 §1「切换层」：17 个 mb_tfl_* shim（MoonBit 侧包私有 ABI）与
 * 5 个白盒钩子的唯一导出点。进程级一次性解析 + 粘性路由：
 *   real = 运行时动态加载真实 tensorflowlite_c（mb_tfl_real.c）；
 *   失败分类 F1/F2/F3 后按 env 契约回退编译进二进制的确定性 stub
 *   （stub/mb_tfl_stub.c，内部符号 mb_tfl_stub_impl_*）。
 *
 * 【env 契约】（契约 §1）
 *   MB_TFLITE_BACKEND = stub（默认）| real（强制真实，F1-F3 不回退）
 *                     | auto（优先 real，失败回退 stub）；
 *   非法值 = 视为未设置并记 env_invalid（体现在 backend_info() reason）。
 *   MB_TFLITE_LIB_PATH = <绝对路径>（UTF-8 -> LoadLibraryW，支持中文路径）；
 *   未设置 = 标准搜索（库名直接交给 LoadLibraryW / dlopen）。
 *
 * 【失败分类】F1=路径探测失败；F2=映像无效（非 PE/缺导出/schema 不兼容）；
 * F3=加载失败（依赖缺失等 LoadLibrary 返回 NULL）；F0=未尝试真实加载；
 * ok=真实库加载并路由成功（backend_info() 的 load_status 域）。
 *
 * 【mb_tfl_capi_version】正常态恒返回 shim ABI 版本 0x00010001（既有断言
 * 零改动；真实库版本校验在解析期走 TfLiteSchemaVersion，不符=F2）。
 * 例外（偏差登记，见最终报告/DESIGN.md）：「real 强制且加载失败」态返回
 * 负失败分类哨兵 -1/-2/-3，借 interpreter.mbt 既有版本断言路径让
 * from_bytes 显式抛 LibraryNotLoaded(reason)——这是冻结 interpreter.mbt
 * 零改动前提下 from_bytes 唯一可达的 LibraryNotLoaded 抬起点。
 *
 * 【句柄信封】real 路径 model_create 必须包句柄信封：dispatcher malloc 复制
 * 模型字节（TfLiteModelCreate 不拷贝且要求 model_data 活得与解释器一样久，
 * MoonBit #borrow 语义不破），信封随 model_delete 释放。options 信封记录
 * threads_set（n<1 不设 -> interpreter_create 失败，与 stub 同语义）。
 *
 * 【线程】解析在 SRWLOCK（Windows）/ pthread_mutex（POSIX）下进行；
 * 首次解析后粘性（句柄同后端创建/释放）；_tfl_backend_reset 仅当
 * live_handles()==0 才允许重解析，否则返回 1。
 */

#include "mb_tfl_backend.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#endif

/* ================= stub 实现（内部符号 mb_tfl_stub_impl_*） ================= */

int32_t mb_tfl_stub_impl_capi_version(void);
void *mb_tfl_stub_impl_model_create(uint8_t *model_bytes, int32_t size);
void mb_tfl_stub_impl_model_delete(void *model);
void *mb_tfl_stub_impl_options_create(void);
void mb_tfl_stub_impl_options_set_threads(void *options, int32_t n);
void mb_tfl_stub_impl_options_delete(void *options);
void *mb_tfl_stub_impl_interpreter_create(void *model, void *options);
void mb_tfl_stub_impl_interpreter_delete(void *interp);
int32_t mb_tfl_stub_impl_input_count(void *interp);
int32_t mb_tfl_stub_impl_output_count(void *interp);
void *mb_tfl_stub_impl_input_tensor(void *interp, int32_t index);
void *mb_tfl_stub_impl_output_tensor(void *interp, int32_t index);
int32_t mb_tfl_stub_impl_resize_input(void *interp, int32_t index,
                                      int32_t *dims, int32_t dims_len);
int32_t mb_tfl_stub_impl_allocate_tensors(void *interp);
int32_t mb_tfl_stub_impl_tensor_copy_from(void *tensor, uint8_t *src,
                                          int32_t size);
int32_t mb_tfl_stub_impl_tensor_copy_to(void *tensor, uint8_t *dst,
                                        int32_t size);
int32_t mb_tfl_stub_impl_invoke(void *interp);
int32_t mb_tfl_stub_impl_tensor_meta(void *interp, int32_t index,
                                     int32_t is_output, int32_t *dims,
                                     int32_t *misc, double *qscale,
                                     uint8_t *name);

/* ================= 全局状态 ================= */

typedef struct {
  int32_t resolved;      /* -1=未解析; 0=stub; 1=real; 2=real 强制失败 */
  int32_t mode;          /* MB_TFL_MODE_*（生效模式） */
  int32_t env_invalid;   /* 1 = MB_TFLITE_BACKEND 非法（视为未设置） */
  int32_t load_status;   /* MB_TFL_LOAD_* */
  int32_t real_attempted;
  int32_t schema_version; /* -1 = 未知 */
  int32_t force_fail;    /* 0=无；1|2|3=下次解析注入 F1|F2|F3 */
  char tfl_version[32];
  char lib_path[520];    /* UTF-8；空 = 标准搜索 */
  char reason[256];      /* UTF-8 分类原因 */
  mb_tfl_real_api api;   /* resolved==1 时有效 */
} mb_tfl_backend_state;

static mb_tfl_backend_state g_state = {-1, MB_TFL_MODE_STUB, 0,
                                       MB_TFL_LOAD_F0, 0, -1, 0, "", "", "",
                                       {0}};

static volatile int32_t g_live_handles = 0;

#ifdef _WIN32
static SRWLOCK g_lock = SRWLOCK_INIT;
#define MB_TFL_LOCK() AcquireSRWLockExclusive(&g_lock)
#define MB_TFL_UNLOCK() ReleaseSRWLockExclusive(&g_lock)
#else
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
#define MB_TFL_LOCK() pthread_mutex_lock(&g_lock)
#define MB_TFL_UNLOCK() pthread_mutex_unlock(&g_lock)
#endif

static void live_handles_add(int32_t delta) {
#ifdef _WIN32
  if (delta >= 0) {
    InterlockedExchangeAdd((volatile LONG *)&g_live_handles, (LONG)delta);
  } else {
    InterlockedExchangeAdd((volatile LONG *)&g_live_handles, (LONG)delta);
  }
#else
  __atomic_add_fetch(&g_live_handles, delta, __ATOMIC_SEQ_CST);
#endif
}

static int32_t live_handles_get(void) {
#ifdef _WIN32
  return (int32_t)InterlockedCompareExchange((volatile LONG *)&g_live_handles,
                                             0, 0);
#else
  return __atomic_load_n(&g_live_handles, __ATOMIC_SEQ_CST);
#endif
}

/* ================= env 读取（UTF-8） ================= */

#ifdef _WIN32
static int32_t env_get_utf8(const char *name, char *out, int32_t cap) {
  wchar_t wname[64];
  wchar_t wbuf[1024];
  DWORD n;
  int m;
  if (cap <= 0) return 0;
  out[0] = '\0';
  if (MultiByteToWideChar(CP_UTF8, 0, name, -1, wname, 64) <= 0) return 0;
  n = GetEnvironmentVariableW(wname, wbuf, 1024);
  if (n == 0 || n >= 1024) return 0;
  m = WideCharToMultiByte(CP_UTF8, 0, wbuf, (int)n, out, (int)cap - 1, NULL,
                          NULL);
  if (m <= 0) {
    out[0] = '\0';
    return 0;
  }
  out[m] = '\0';
  return m;
}
#else
static int32_t env_get_utf8(const char *name, char *out, int32_t cap) {
  const char *v;
  size_t len;
  if (cap <= 0) return 0;
  out[0] = '\0';
  v = getenv(name);
  if (v == NULL) return 0;
  len = strlen(v);
  if (len > (size_t)cap - 1) len = (size_t)cap - 1;
  memcpy(out, v, len);
  out[len] = '\0';
  return (int32_t)len;
}
#endif

/* ================= 解析（调用方持锁） ================= */

static void copy_str(char *dst, int32_t cap, const char *src) {
  if (cap <= 0) return;
  strncpy(dst, src, (size_t)cap - 1);
  dst[cap - 1] = '\0';
}

static void resolve_locked(int32_t mode_arg, const char *path_utf8,
                           int32_t path_len) {
  int32_t mode = MB_TFL_MODE_STUB;
  int32_t env_invalid = 0;
  int32_t status;
  mb_tfl_real_result rr;
  char env_mode[32];
  char env_path[520];

  /* 清理上一次解析（粘性重解析只在 live_handles==0 时发生）。 */
  mb_tfl_real_unload();
  memset(&g_state.api, 0, sizeof(g_state.api));

  /* 模式：-1 = 按 env。 */
  if (mode_arg == -1) {
    if (env_get_utf8("MB_TFLITE_BACKEND", env_mode, (int32_t)sizeof(env_mode)) >
        0) {
      if (strcmp(env_mode, "stub") == 0) {
        mode = MB_TFL_MODE_STUB;
      } else if (strcmp(env_mode, "real") == 0) {
        mode = MB_TFL_MODE_REAL;
      } else if (strcmp(env_mode, "auto") == 0) {
        mode = MB_TFL_MODE_AUTO;
      } else {
        /* 非法 env 值 = 视为未设置并记 env_invalid */
        mode = MB_TFL_MODE_STUB;
        env_invalid = 1;
      }
    } else {
      mode = MB_TFL_MODE_STUB; /* 默认 stub */
    }
  } else if (mode_arg == MB_TFL_MODE_STUB || mode_arg == MB_TFL_MODE_REAL ||
             mode_arg == MB_TFL_MODE_AUTO) {
    mode = mode_arg;
  } else {
    mode = MB_TFL_MODE_STUB; /* 非法 mode 参数按 env 处理 */
    if (env_get_utf8("MB_TFLITE_BACKEND", env_mode, (int32_t)sizeof(env_mode)) >
        0) {
      if (strcmp(env_mode, "real") == 0) {
        mode = MB_TFL_MODE_REAL;
      } else if (strcmp(env_mode, "auto") == 0) {
        mode = MB_TFL_MODE_AUTO;
      } else if (strcmp(env_mode, "stub") == 0) {
        mode = MB_TFL_MODE_STUB;
      } else {
        env_invalid = 1;
      }
    }
  }

  /* 路径：显式 path 优先；否则 env MB_TFLITE_LIB_PATH；再否则标准搜索。 */
  g_state.lib_path[0] = '\0';
  if (path_utf8 != NULL && path_len > 0) {
    int32_t n = path_len;
    if (n > (int32_t)sizeof(g_state.lib_path) - 1)
      n = (int32_t)sizeof(g_state.lib_path) - 1;
    memcpy(g_state.lib_path, path_utf8, (size_t)n);
    g_state.lib_path[n] = '\0';
  } else {
    env_get_utf8("MB_TFLITE_LIB_PATH", env_path, (int32_t)sizeof(env_path));
    copy_str(g_state.lib_path, (int32_t)sizeof(g_state.lib_path), env_path);
  }

  g_state.mode = mode;
  g_state.env_invalid = env_invalid;
  g_state.real_attempted = 0;
  g_state.schema_version = -1;
  g_state.tfl_version[0] = '\0';
  g_state.reason[0] = '\0';

  if (mode == MB_TFL_MODE_STUB) {
    /* stub 模式：不尝试真实加载。 */
    g_state.resolved = MB_TFL_NAME_STUB;
    g_state.load_status = MB_TFL_LOAD_F0;
    copy_str(g_state.reason, (int32_t)sizeof(g_state.reason),
             "F0 stub_default_real_not_attempted");
  } else {
    /* real / auto：尝试真实加载（force_fail 注入优先）。 */
    g_state.real_attempted = 1;
    status = mb_tfl_real_try_load(
        g_state.lib_path[0] != '\0' ? g_state.lib_path : NULL,
        g_state.lib_path[0] != '\0' ? (int32_t)strlen(g_state.lib_path) : 0,
        g_state.force_fail, &g_state.api, &rr);
    g_state.load_status = status;
    if (rr.schema_version >= 0) g_state.schema_version = rr.schema_version;
    copy_str(g_state.tfl_version, (int32_t)sizeof(g_state.tfl_version),
             rr.tfl_version);
    if (status == MB_TFL_LOAD_OK) {
      g_state.resolved = MB_TFL_NAME_REAL;
      copy_str(g_state.reason, (int32_t)sizeof(g_state.reason),
               "ok real_loaded");
    } else {
      char class_text[32];
      char combined[256];
      const char *cls =
          status == MB_TFL_LOAD_F1
              ? "F1 path_probe_failed"
              : (status == MB_TFL_LOAD_F2 ? "F2 image_invalid"
                                          : "F3 load_failed");
      copy_str(class_text, (int32_t)sizeof(class_text), cls);
      if (mode == MB_TFL_MODE_REAL) {
        g_state.resolved = MB_TFL_NAME_REAL_FORCED_FAILED;
        snprintf(combined, sizeof(combined), "%s: %s; real_forced_unavailable",
                 class_text, rr.detail);
      } else {
        g_state.resolved = MB_TFL_NAME_STUB;
        snprintf(combined, sizeof(combined), "%s: %s; auto_fallback_stub",
                 class_text, rr.detail);
      }
      copy_str(g_state.reason, (int32_t)sizeof(g_state.reason), combined);
    }
  }
  if (env_invalid) {
    char combined[288];
    snprintf(combined, sizeof(combined), "env_invalid; %s", g_state.reason);
    copy_str(g_state.reason, (int32_t)sizeof(g_state.reason), combined);
  }
}

/* 一次性解析（线程安全；解析后粘性）。 */
static void ensure_resolved(void) {
  if (g_state.resolved >= 0) return;
  MB_TFL_LOCK();
  if (g_state.resolved < 0) resolve_locked(-1, NULL, 0);
  MB_TFL_UNLOCK();
}

/* ================= 17 个 shim（docs/API.md） ================= */

int32_t mb_tfl_capi_version(void) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL_FORCED_FAILED) {
    /* 哨兵：-1/-2/-3 对应 F1/F2/F3（见文件头「偏差登记」说明）。 */
    return -g_state.load_status;
  }
  return MB_TFL_SHIM_ABI_VERSION;
}

/* real 路径句柄信封（契约 §1：dispatcher malloc 复制模型字节，信封随
 * model_delete 释放，#borrow 语义不破）。 */
typedef struct {
  uint8_t *bytes;
  void *real_model;
} mb_tfl_model_env;

typedef struct {
  void *real_options;
  int32_t threads_set;
} mb_tfl_options_env;

void *mb_tfl_model_create(uint8_t *model_bytes, int32_t size) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    mb_tfl_model_env *env;
    if (model_bytes == NULL || size <= 0) return NULL;
    env = (mb_tfl_model_env *)malloc(sizeof(mb_tfl_model_env));
    if (env == NULL) return NULL;
    env->bytes = (uint8_t *)malloc((size_t)size);
    if (env->bytes == NULL) {
      free(env);
      return NULL;
    }
    memcpy(env->bytes, model_bytes, (size_t)size);
    env->real_model = g_state.api.TfLiteModelCreate(env->bytes, (size_t)size);
    if (env->real_model == NULL) {
      free(env->bytes);
      free(env);
      return NULL;
    }
    live_handles_add(1);
    return env;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    void *h = mb_tfl_stub_impl_model_create(model_bytes, size);
    if (h != NULL) live_handles_add(1);
    return h;
  }
  return NULL;
}

void mb_tfl_model_delete(void *model) {
  if (model == NULL) return;
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    mb_tfl_model_env *env = (mb_tfl_model_env *)model;
    g_state.api.TfLiteModelDelete(env->real_model);
    free(env->bytes);
    free(env);
    live_handles_add(-1);
    return;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    mb_tfl_stub_impl_model_delete(model);
    live_handles_add(-1);
  }
}

void *mb_tfl_options_create(void) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    mb_tfl_options_env *env =
        (mb_tfl_options_env *)malloc(sizeof(mb_tfl_options_env));
    if (env == NULL) return NULL;
    env->real_options = g_state.api.TfLiteInterpreterOptionsCreate();
    if (env->real_options == NULL) {
      free(env);
      return NULL;
    }
    env->threads_set = 0;
    live_handles_add(1);
    return env;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    void *h = mb_tfl_stub_impl_options_create();
    if (h != NULL) live_handles_add(1);
    return h;
  }
  return NULL;
}

void mb_tfl_options_set_threads(void *options, int32_t n) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    mb_tfl_options_env *env = (mb_tfl_options_env *)options;
    if (env == NULL) return;
    /* n < 1 不设（= 创建失败同 stub） */
    if (n >= 1) {
      g_state.api.TfLiteInterpreterOptionsSetNumThreads(env->real_options, n);
      env->threads_set = 1;
    }
    return;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    mb_tfl_stub_impl_options_set_threads(options, n);
  }
}

void mb_tfl_options_delete(void *options) {
  if (options == NULL) return;
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    mb_tfl_options_env *env = (mb_tfl_options_env *)options;
    g_state.api.TfLiteInterpreterOptionsDelete(env->real_options);
    free(env);
    live_handles_add(-1);
    return;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    mb_tfl_stub_impl_options_delete(options);
    live_handles_add(-1);
  }
}

void *mb_tfl_interpreter_create(void *model, void *options) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    mb_tfl_model_env *m = (mb_tfl_model_env *)model;
    mb_tfl_options_env *o = (mb_tfl_options_env *)options;
    void *interp;
    /* 与 stub 同语义：threads 未设 >=1 -> 创建失败 */
    if (m == NULL || o == NULL || !o->threads_set) return NULL;
    interp = g_state.api.TfLiteInterpreterCreate(m->real_model, o->real_options);
    if (interp != NULL) live_handles_add(1);
    return interp;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    void *h = mb_tfl_stub_impl_interpreter_create(model, options);
    if (h != NULL) live_handles_add(1);
    return h;
  }
  return NULL;
}

void mb_tfl_interpreter_delete(void *interp) {
  if (interp == NULL) return;
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    g_state.api.TfLiteInterpreterDelete(interp);
    live_handles_add(-1);
    return;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    mb_tfl_stub_impl_interpreter_delete(interp);
    live_handles_add(-1);
  }
}

int32_t mb_tfl_input_count(void *interp) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    if (interp == NULL) return -1;
    return g_state.api.TfLiteInterpreterGetInputTensorCount(interp);
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_input_count(interp);
  }
  return -1;
}

int32_t mb_tfl_output_count(void *interp) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    if (interp == NULL) return -1;
    return g_state.api.TfLiteInterpreterGetOutputTensorCount(interp);
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_output_count(interp);
  }
  return -1;
}

void *mb_tfl_input_tensor(void *interp, int32_t index) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    if (interp == NULL) return NULL;
    return g_state.api.TfLiteInterpreterGetInputTensor(interp, index);
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_input_tensor(interp, index);
  }
  return NULL;
}

void *mb_tfl_output_tensor(void *interp, int32_t index) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    if (interp == NULL) return NULL;
    /* GetOutputTensor 返回 const TfLiteTensor*（借用）：这里仅做搬运，
     * 不经该指针写入，const 擦除安全。 */
    return (void *)g_state.api.TfLiteInterpreterGetOutputTensor(interp, index);
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_output_tensor(interp, index);
  }
  return NULL;
}

int32_t mb_tfl_resize_input(void *interp, int32_t index, int32_t *dims,
                            int32_t dims_len) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    int st;
    if (interp == NULL || dims == NULL) return 1;
    st = g_state.api.TfLiteInterpreterResizeInputTensor(interp, index,
                                                        (const int *)dims,
                                                        dims_len);
    /* real 仅 0/1（状态码 2 = NOT_ALLOCATED 仅 stub，见 docs/DESIGN.md） */
    return st == 0 ? 0 : 1;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_resize_input(interp, index, dims, dims_len);
  }
  return 1;
}

int32_t mb_tfl_allocate_tensors(void *interp) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    int st;
    if (interp == NULL) return 1;
    st = g_state.api.TfLiteInterpreterAllocateTensors(interp);
    return st == 0 ? 0 : 1;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_allocate_tensors(interp);
  }
  return 1;
}

int32_t mb_tfl_tensor_copy_from(void *tensor, uint8_t *src, int32_t size) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    int st;
    if (tensor == NULL || src == NULL || size < 0) return 1;
    st = g_state.api.TfLiteTensorCopyFromBuffer(tensor, src, (size_t)size);
    return st == 0 ? 0 : 1;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_tensor_copy_from(tensor, src, size);
  }
  return 1;
}

int32_t mb_tfl_tensor_copy_to(void *tensor, uint8_t *dst, int32_t size) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    int st;
    if (tensor == NULL || dst == NULL || size < 0) return 1;
    st = g_state.api.TfLiteTensorCopyToBuffer(tensor, dst, (size_t)size);
    return st == 0 ? 0 : 1;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_tensor_copy_to(tensor, dst, size);
  }
  return 1;
}

int32_t mb_tfl_invoke(void *interp) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    int st;
    if (interp == NULL) return 1;
    st = g_state.api.TfLiteInterpreterInvoke(interp);
    return st == 0 ? 0 : 1;
  }
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_invoke(interp);
  }
  return 1;
}

/* ================= 私有 ABI（MoonBit 层内部约定） ================= */

/* *_alive = h != NULL（dispatch 层，与后端无关）。 */
int32_t tflite_ffi_private_model_alive(void *h) { return h != NULL; }

int32_t tflite_ffi_private_options_alive(void *h) { return h != NULL; }

int32_t tflite_ffi_private_interp_alive(void *h) { return h != NULL; }

/* TfLiteType -> 既有 dtype 码（0=F32 1=F16 2=I32 3=U8 4=I8 5=I64，不支持=255） */
static int32_t dtype_code_of(int tflite_type) {
  switch (tflite_type) {
    case 1:  /* kTfLiteFloat32 */
      return 0;
    case 10: /* kTfLiteFloat16 */
      return 1;
    case 2:  /* kTfLiteInt32 */
      return 2;
    case 3:  /* kTfLiteUInt8 */
      return 3;
    case 9:  /* kTfLiteInt8 */
      return 4;
    case 4:  /* kTfLiteInt64 */
      return 5;
    default:
      return MB_TFL_DTYPE_UNSUPPORTED;
  }
}

/* 张量元数据查询：real 映射 TfLiteTensorName/Dims/Type/ByteSize/
 * QuantizationParams；name>63 截断、rank>8 返非 0（既有私有 ABI 上限）。 */
int32_t tflite_ffi_private_tensor_meta(void *interp, int32_t index,
                                       int32_t is_output, int32_t *dims,
                                       int32_t *misc, double *qscale,
                                       uint8_t *name) {
  ensure_resolved();
  if (g_state.resolved == MB_TFL_NAME_STUB) {
    return mb_tfl_stub_impl_tensor_meta(interp, index, is_output, dims, misc,
                                        qscale, name);
  }
  if (g_state.resolved == MB_TFL_NAME_REAL) {
    const void *t;
    const char *name_ptr;
    int32_t rank, name_len, k;
    mb_tfl_quant_params q;
    if (interp == NULL || dims == NULL || misc == NULL || qscale == NULL ||
        name == NULL)
      return 1;
    if (is_output != 0 && is_output != 1) return 1;
    if (is_output) {
      t = g_state.api.TfLiteInterpreterGetOutputTensor(interp, index);
    } else {
      t = g_state.api.TfLiteInterpreterGetInputTensor(interp, index);
    }
    if (t == NULL) return 1;
    rank = g_state.api.TfLiteTensorNumDims(t);
    if (rank < 0 || rank > MB_TFL_MAX_RANK) return 1; /* rank>8 返非 0 */
    name_ptr = g_state.api.TfLiteTensorName(t);
    name_len = 0;
    if (name_ptr != NULL) {
      while (name_len < MB_TFL_MAX_NAME && name_ptr[name_len] != '\0')
        name_len++;
      /* name>63 截断（既有私有 ABI 上限） */
    }
    dims[0] = rank;
    for (k = 0; k < MB_TFL_MAX_RANK; k++) {
      dims[1 + k] = (k < rank) ? g_state.api.TfLiteTensorDim(t, k) : 0;
    }
    misc[0] = dtype_code_of(g_state.api.TfLiteTensorType(t));
    misc[1] = (int32_t)g_state.api.TfLiteTensorByteSize(t);
    q = g_state.api.TfLiteTensorQuantizationParams(t);
    misc[2] = q.zero_point;
    misc[3] = name_len;
    qscale[0] = (double)q.scale;
    for (k = 0; k <= MB_TFL_MAX_NAME; k++) name[k] = 0;
    if (name_ptr != NULL && name_len > 0)
      memcpy(name, name_ptr, (size_t)name_len);
    return 0;
  }
  return 1;
}

/* ================= 白盒钩子（契约 §2，不进快照） ================= */

/* mode: -1=按env, 0=stub, 1=real, 2=auto；返回 0=ok, 1=活跃句柄拒绝,
 * 2=real 强制失败。 */
int32_t tflite_ffi_private_backend_reset(int32_t mode, uint8_t *path,
                                         int32_t path_len) {
  int32_t rc;
  MB_TFL_LOCK();
  if (live_handles_get() != 0) {
    MB_TFL_UNLOCK();
    return MB_TFL_RESET_LIVE_HANDLES;
  }
  resolve_locked(mode, (const char *)path, path_len);
  rc = (g_state.resolved == MB_TFL_NAME_REAL_FORCED_FAILED)
           ? MB_TFL_RESET_REAL_FORCED_FAILED
           : MB_TFL_RESET_OK;
  MB_TFL_UNLOCK();
  return rc;
}

/* 0=清除, 1|2|3=注入 F1|F2|F3（下次解析生效）；返回 0=ok, 1=非法码。 */
int32_t tflite_ffi_private_backend_force_fail(int32_t code) {
  if (code < 0 || code > 3) return 1;
  MB_TFL_LOCK();
  g_state.force_fail = code;
  MB_TFL_UNLOCK();
  return 0;
}

int32_t tflite_ffi_private_backend_live_handles(void) {
  return live_handles_get();
}

/* 0=stub, 1=real, 2=real 强制失败（backend_name() 映射：0->"stub"，其余->"real"） */
int32_t tflite_ffi_private_backend_name_code(void) {
  ensure_resolved();
  return g_state.resolved;
}

/* key=value 行文本（LF/UTF-8）：mode、resolved、lib_path、load_status、
 * reason、tfl_version、schema_version。返回写入 dst 的字节数（截断到 cap）。 */
int32_t tflite_ffi_private_backend_info_bytes(uint8_t *dst, int32_t cap) {
  char text[1280];
  int n;
  int32_t copy;
  const char *mode_name;
  const char *resolved_name;
  const char *load_status_name;
  char schema_buf[16];

  ensure_resolved();
  mode_name = g_state.mode == MB_TFL_MODE_REAL
                  ? "real"
                  : (g_state.mode == MB_TFL_MODE_AUTO ? "auto" : "stub");
  switch (g_state.resolved) {
    case MB_TFL_NAME_REAL:
      resolved_name = "real";
      break;
    case MB_TFL_NAME_REAL_FORCED_FAILED:
      resolved_name = "none";
      break;
    default:
      resolved_name = "stub";
      break;
  }
  if (g_state.load_status == MB_TFL_LOAD_OK) {
    load_status_name = g_state.real_attempted ? "ok" : "F0";
  } else if (g_state.load_status == MB_TFL_LOAD_F1) {
    load_status_name = "F1";
  } else if (g_state.load_status == MB_TFL_LOAD_F2) {
    load_status_name = "F2";
  } else {
    load_status_name = "F3";
  }
  if (g_state.schema_version >= 0) {
    snprintf(schema_buf, sizeof(schema_buf), "%d", (int)g_state.schema_version);
  } else {
    copy_str(schema_buf, (int32_t)sizeof(schema_buf), "unknown");
  }
  n = snprintf(text, sizeof(text),
               "mode=%s\n"
               "resolved=%s\n"
               "lib_path=%s\n"
               "load_status=%s\n"
               "reason=%s\n"
               "tfl_version=%s\n"
               "schema_version=%s\n",
               mode_name, resolved_name,
               g_state.lib_path[0] != '\0' ? g_state.lib_path : "",
               load_status_name, g_state.reason,
               g_state.tfl_version[0] != '\0' ? g_state.tfl_version : "unknown",
               schema_buf);
  if (n < 0) return 0;
  if (dst == NULL || cap <= 0) return 0;
  copy = (int32_t)n;
  if (copy > cap) copy = cap;
  memcpy(dst, text, (size_t)copy);
  return copy;
}
