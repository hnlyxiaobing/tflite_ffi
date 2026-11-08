/*
 * mb_tfl_real.c — 真实 tensorflowlite_c 动态加载器（WP-1, 2026-11-08）
 *
 * 【定位】契约 §1「切换层」的真实路径：运行时动态加载真实
 * `tensorflowlite_c.dll`（Windows：LoadLibraryW/GetProcAddress）或
 * `libtensorflowlite_c.so`（POSIX：dlopen/dlsym），解析 c_api.h 所需导出符号。
 * 失败分类（契约 §1）：F1=路径探测失败（不存在/非常规文件）；
 * F2=映像无效（非 PE/必需导出符号缺失/TfLiteSchemaVersion 不兼容）；
 * F3=加载失败（依赖缺失等 LoadLibrary 返回 NULL）。
 * 白盒故障注入 force_fail_class=1|2|3 时直接返回对应分类（不触盘）。
 *
 * 【平台】Windows 路径经 UTF-8 -> UTF-16 转换后走 LoadLibraryW，
 * 支持中文路径（契约 §1 env 契约）；POSIX 路径按 UTF-8 直接使用。
 */

#include "mb_tfl_backend.h"

#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

/* ---------------- 模块句柄（加载成功后驻留，unload 释放） ---------------- */
#ifdef _WIN32
static HMODULE g_module = NULL;
#else
static void *g_module = NULL;
#endif

void mb_tfl_real_unload(void) {
  if (g_module != NULL) {
#ifdef _WIN32
    FreeLibrary(g_module);
#else
    dlclose(g_module);
#endif
    g_module = NULL;
  }
}

/* ---------------- 内部工具 ---------------- */

static void result_reset(mb_tfl_real_result *r) {
  memset(r, 0, sizeof(*r));
  r->status = MB_TFL_LOAD_OK;
  r->schema_version = -1;
  r->tfl_version[0] = '\0';
  r->detail[0] = '\0';
}

static int32_t result_fail(mb_tfl_real_result *r, int32_t status, int32_t err,
                           const char *detail) {
  r->status = status;
  r->win_error = err;
  if (detail != NULL) {
    strncpy(r->detail, detail, sizeof(r->detail) - 1);
    r->detail[sizeof(r->detail) - 1] = '\0';
  }
  return status;
}

#ifdef _WIN32
/* UTF-8 -> UTF-16；非法 UTF-8 时按 ANSI 兜底（可移植性优先）。
 * out_wchars 为缓冲容量（含 NUL）。 */
static int utf8_to_wide(const char *src, int32_t src_len, wchar_t *dst,
                        int dst_cap) {
  int n;
  if (src == NULL || src_len <= 0 || dst_cap <= 0) return 0;
  n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, src, (int)src_len, dst,
                          dst_cap - 1);
  if (n <= 0) {
    n = MultiByteToWideChar(CP_ACP, 0, src, (int)src_len, dst, dst_cap - 1);
    if (n <= 0) return 0;
  }
  dst[n] = L'\0';
  return n;
}
#endif

/* 路径探测：0 = 通过（文件存在且常规），1 = F1，2 = F2（非 PE/ELF 映像）。
 * err_out 返回系统错误码。detail_out 写入分类明细。 */
static int32_t probe_path(const char *path_utf8, int32_t path_len,
                          int32_t *err_out, char *detail_out,
                          int detail_cap) {
#ifdef _WIN32
  wchar_t wpath[1024];
  DWORD attrs;
  HANDLE hf;
  unsigned char magic[2];
  DWORD got = 0;
  *err_out = 0;
  if (utf8_to_wide(path_utf8, path_len, wpath, 1024) <= 0) {
    strncpy(detail_out, "path_not_utf8", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 1; /* F1：路径无法解析 */
  }
  attrs = GetFileAttributesW(wpath);
  if (attrs == INVALID_FILE_ATTRIBUTES) {
    *err_out = (int32_t)GetLastError();
    strncpy(detail_out, "path_not_found", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 1; /* F1 */
  }
  if (attrs & FILE_ATTRIBUTE_DIRECTORY) {
    strncpy(detail_out, "not_regular_file", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 1; /* F1：非常规文件 */
  }
  hf = CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                   FILE_ATTRIBUTE_NORMAL, NULL);
  if (hf == INVALID_HANDLE_VALUE) {
    *err_out = (int32_t)GetLastError();
    strncpy(detail_out, "path_not_found", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 1; /* F1 */
  }
  if (!ReadFile(hf, magic, 2, &got, NULL) || got < 2) {
    CloseHandle(hf);
    strncpy(detail_out, "not_pe_image", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 2; /* F2：读不出 MZ 头 */
  }
  CloseHandle(hf);
  if (magic[0] != 'M' || magic[1] != 'Z') {
    strncpy(detail_out, "not_pe_image", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 2; /* F2：非 PE 映像 */
  }
  return 0;
#else
  struct stat st;
  int fd;
  unsigned char magic[4];
  ssize_t got;
  *err_out = 0;
  if (stat(path_utf8, &st) != 0) {
    *err_out = errno;
    strncpy(detail_out, "path_not_found", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 1; /* F1 */
  }
  if (!S_ISREG(st.st_mode)) {
    strncpy(detail_out, "not_regular_file", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 1; /* F1 */
  }
  fd = open(path_utf8, O_RDONLY);
  if (fd < 0) {
    *err_out = errno;
    strncpy(detail_out, "path_not_found", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 1;
  }
  got = read(fd, magic, 4);
  close(fd);
  if (got < 4 || magic[0] != 0x7F || magic[1] != 'E' || magic[2] != 'L' ||
      magic[3] != 'F') {
    strncpy(detail_out, "not_elf_image", (size_t)detail_cap - 1);
    detail_out[detail_cap - 1] = '\0';
    return 2; /* F2 */
  }
  return 0;
#endif
}

/* ---------------- 导出符号解析 ---------------- */

#ifdef _WIN32
#define MB_TFL_SYM_CAST(type, module, name) ((type)(void *)GetProcAddress(module, name))
#else
#define MB_TFL_SYM_CAST(type, module, name) ((type)(void *)dlsym(module, name))
#endif

static int32_t resolve_symbols(mb_tfl_real_api *api, char *detail_out,
                               int detail_cap) {
#define MB_TFL_REQUIRE(field, type, cname)                                    \
  do {                                                                        \
    api->field = MB_TFL_SYM_CAST(type, g_module, cname);                      \
    if (api->field == NULL) {                                                 \
      snprintf(detail_out, (size_t)detail_cap, "missing_export:%s", cname);   \
      return MB_TFL_LOAD_F2; /* F2：必需导出符号缺失 */                        \
    }                                                                         \
  } while (0)

  MB_TFL_REQUIRE(TfLiteVersion, const char *(*)(void), "TfLiteVersion");
  MB_TFL_REQUIRE(TfLiteSchemaVersion, int (*)(void), "TfLiteSchemaVersion");
  MB_TFL_REQUIRE(TfLiteModelCreate, void *(*)(const void *, size_t),
                 "TfLiteModelCreate");
  MB_TFL_REQUIRE(TfLiteModelDelete, void (*)(void *), "TfLiteModelDelete");
  MB_TFL_REQUIRE(TfLiteInterpreterOptionsCreate, void *(*)(void),
                 "TfLiteInterpreterOptionsCreate");
  MB_TFL_REQUIRE(TfLiteInterpreterOptionsDelete, void (*)(void *),
                 "TfLiteInterpreterOptionsDelete");
  MB_TFL_REQUIRE(TfLiteInterpreterOptionsSetNumThreads,
                 void (*)(void *, int32_t),
                 "TfLiteInterpreterOptionsSetNumThreads");
  MB_TFL_REQUIRE(TfLiteInterpreterCreate, void *(*)(const void *, const void *),
                 "TfLiteInterpreterCreate");
  MB_TFL_REQUIRE(TfLiteInterpreterDelete, void (*)(void *),
                 "TfLiteInterpreterDelete");
  MB_TFL_REQUIRE(TfLiteInterpreterGetInputTensorCount,
                 int32_t (*)(const void *),
                 "TfLiteInterpreterGetInputTensorCount");
  MB_TFL_REQUIRE(TfLiteInterpreterGetOutputTensorCount,
                 int32_t (*)(const void *),
                 "TfLiteInterpreterGetOutputTensorCount");
  MB_TFL_REQUIRE(TfLiteInterpreterGetInputTensor,
                 void *(*)(const void *, int32_t),
                 "TfLiteInterpreterGetInputTensor");
  MB_TFL_REQUIRE(TfLiteInterpreterGetOutputTensor,
                 const void *(*)(const void *, int32_t),
                 "TfLiteInterpreterGetOutputTensor");
  MB_TFL_REQUIRE(TfLiteInterpreterResizeInputTensor,
                 int (*)(void *, int32_t, const int *, int32_t),
                 "TfLiteInterpreterResizeInputTensor");
  MB_TFL_REQUIRE(TfLiteInterpreterAllocateTensors, int (*)(void *),
                 "TfLiteInterpreterAllocateTensors");
  MB_TFL_REQUIRE(TfLiteInterpreterInvoke, int (*)(void *),
                 "TfLiteInterpreterInvoke");
  MB_TFL_REQUIRE(TfLiteTensorType, int (*)(const void *), "TfLiteTensorType");
  MB_TFL_REQUIRE(TfLiteTensorNumDims, int32_t (*)(const void *),
                 "TfLiteTensorNumDims");
  MB_TFL_REQUIRE(TfLiteTensorDim, int32_t (*)(const void *, int32_t),
                 "TfLiteTensorDim");
  MB_TFL_REQUIRE(TfLiteTensorByteSize, size_t (*)(const void *),
                 "TfLiteTensorByteSize");
  MB_TFL_REQUIRE(TfLiteTensorName, const char *(*)(const void *),
                 "TfLiteTensorName");
  MB_TFL_REQUIRE(TfLiteTensorQuantizationParams,
                 mb_tfl_quant_params (*)(const void *),
                 "TfLiteTensorQuantizationParams");
  MB_TFL_REQUIRE(TfLiteTensorCopyFromBuffer,
                 int (*)(void *, const void *, size_t),
                 "TfLiteTensorCopyFromBuffer");
  MB_TFL_REQUIRE(TfLiteTensorCopyToBuffer,
                 int (*)(const void *, void *, size_t),
                 "TfLiteTensorCopyToBuffer");
#undef MB_TFL_REQUIRE
  return MB_TFL_LOAD_OK;
}

/* ---------------- 对外入口 ---------------- */

int32_t mb_tfl_real_try_load(const char *path_utf8, int32_t path_len,
                             int32_t force_fail_class, mb_tfl_real_api *api_out,
                             mb_tfl_real_result *result_out) {
  int32_t probe;
  int32_t status;
  const char *tfl_version;
  int schema_version;
  char detail[128];

  result_reset(result_out);
  memset(api_out, 0, sizeof(*api_out));
  detail[0] = '\0';

  /* 白盒故障注入（契约 §1 三场景 ③）：直接返回注入分类，不触盘。 */
  if (force_fail_class >= 1 && force_fail_class <= 3) {
    snprintf(detail, sizeof(detail), "injected_failure:F%d",
             (int)force_fail_class);
    return result_fail(result_out, force_fail_class, 0, detail);
  }

  /* 阶段 1：路径探测（显式路径才探测；空路径 = 标准搜索）。 */
  if (path_utf8 != NULL && path_len > 0) {
    probe = probe_path(path_utf8, path_len, &result_out->win_error, detail,
                       (int)sizeof(detail));
    if (probe != 0) {
      return result_fail(result_out, probe, result_out->win_error, detail);
    }
  }

  /* 阶段 2：加载映像。 */
#ifdef _WIN32
  if (path_utf8 != NULL && path_len > 0) {
    wchar_t wpath[1024];
    if (utf8_to_wide(path_utf8, path_len, wpath, 1024) <= 0) {
      return result_fail(result_out, MB_TFL_LOAD_F1, 0, "path_not_utf8");
    }
    g_module = LoadLibraryW(wpath);
  } else {
    g_module = LoadLibraryW(L"tensorflowlite_c.dll");
  }
  if (g_module == NULL) {
    DWORD err = GetLastError();
    if (err == ERROR_BAD_EXE_FORMAT) {
      /* 映像无效（例如 32/64 位不匹配）：F2 */
      return result_fail(result_out, MB_TFL_LOAD_F2, (int32_t)err,
                         "bad_exe_format");
    }
    if (path_utf8 == NULL || path_len <= 0) {
      if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND ||
          err == ERROR_MOD_NOT_FOUND) {
        return result_fail(result_out, MB_TFL_LOAD_F1, (int32_t)err,
                           "library_not_found");
      }
    }
    /* 依赖缺失等加载失败：F3 */
    snprintf(detail, sizeof(detail), "load_error:%lu", (unsigned long)err);
    return result_fail(result_out, MB_TFL_LOAD_F3, (int32_t)err, detail);
  }
#else
  if (path_utf8 != NULL && path_len > 0) {
    g_module = dlopen(path_utf8, RTLD_NOW | RTLD_LOCAL);
  } else {
    g_module = dlopen("libtensorflowlite_c.so", RTLD_NOW | RTLD_LOCAL);
  }
  if (g_module == NULL) {
    const char *e = dlerror();
    if (path_utf8 == NULL || path_len <= 0) {
      return result_fail(result_out, MB_TFL_LOAD_F1, 0, "library_not_found");
    }
    snprintf(detail, sizeof(detail), "load_error:%s",
             e != NULL ? e : "unknown");
    return result_fail(result_out, MB_TFL_LOAD_F3, 0, detail);
  }
#endif

  /* 阶段 3：必需导出符号（缺失 = F2）。 */
  status = resolve_symbols(api_out, detail, (int)sizeof(detail));
  if (status != MB_TFL_LOAD_OK) {
    mb_tfl_real_unload();
    return result_fail(result_out, status, 0, detail);
  }

  /* 阶段 4：TfLiteSchemaVersion 兼容性（不兼容 = F2）。 */
  schema_version = api_out->TfLiteSchemaVersion();
  result_out->schema_version = schema_version;
  if (schema_version < MB_TFL_SCHEMA_MIN || schema_version > MB_TFL_SCHEMA_MAX) {
    snprintf(detail, sizeof(detail), "schema_incompatible:%d",
             (int)schema_version);
    mb_tfl_real_unload();
    return result_fail(result_out, MB_TFL_LOAD_F2, 0, detail);
  }

  /* 记录 TfLiteVersion 文本（仅信息性）。 */
  tfl_version = api_out->TfLiteVersion();
  if (tfl_version != NULL) {
    strncpy(result_out->tfl_version, tfl_version,
            sizeof(result_out->tfl_version) - 1);
    result_out->tfl_version[sizeof(result_out->tfl_version) - 1] = '\0';
  }
  result_out->status = MB_TFL_LOAD_OK;
  return MB_TFL_LOAD_OK;
}
