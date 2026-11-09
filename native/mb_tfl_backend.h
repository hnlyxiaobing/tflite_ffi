/*
 * mb_tfl_backend.h — tflite_ffi stub/real 双路径 dispatch 层内部头（2026-11-08）
 *
 * 【定位】native/mb_tfl_dispatch.c（17 个 mb_tfl_* shim + 私有 ABI + 白盒钩子的
 * 唯一导出点）与 native/mb_tfl_real.c（真实 tensorflowlite_c 动态加载器）之间的
 * 内部约定；stub/mb_tfl_stub.c 不依赖本头（保持「仅内部符号改名」）。
 * 本头不是公开 API，不进入 pkg.generated.mbti。
 *
 * 【失败分类】（契约 §1）
 *   F1 = 路径探测失败（不存在 / 非常规文件）
 *   F2 = 映像无效（非 PE / 必需导出符号缺失 / TfLiteSchemaVersion 不兼容）
 *   F3 = 加载失败（依赖缺失等 LoadLibrary 返回 NULL）
 *   F0 = 未尝试真实加载（stub 模式 / 默认）
 *   ok = 真实库加载并路由成功
 *
 * 【线程模型】进程级一次性解析 + 粘性路由；解析以 SRWLOCK（Windows）/
 * pthread_mutex（POSIX）+ resolved 标志实现（语义等价 InitOnceExecuteOnce，
 * 且支持白盒 `_tfl_backend_reset` 显式重解析）。
 */

#ifndef MB_TFL_BACKEND_H
#define MB_TFL_BACKEND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------- 加载状态 / 失败分类 ---------------- */
#define MB_TFL_LOAD_OK 0
#define MB_TFL_LOAD_F0 0 /* 语义上等价 OK：未尝试真实加载（stub 模式） */
#define MB_TFL_LOAD_F1 1
#define MB_TFL_LOAD_F2 2
#define MB_TFL_LOAD_F3 3

/* ---------------- 模式 / 解析结果 ---------------- */
#define MB_TFL_MODE_STUB 0
#define MB_TFL_MODE_REAL 1
#define MB_TFL_MODE_AUTO 2

#define MB_TFL_RESOLVED_STUB 0
#define MB_TFL_RESOLVED_REAL 1
#define MB_TFL_RESOLVED_REAL_FAILED 2 /* real 强制但加载失败：无活跃后端，不回退 */

/* backend_name_code() 返回值（backend_name() 映射：0 -> "stub"，其余 -> "real"） */
#define MB_TFL_NAME_STUB 0
#define MB_TFL_NAME_REAL 1
#define MB_TFL_NAME_REAL_FORCED_FAILED 2

/* _tfl_backend_reset 返回值 */
#define MB_TFL_RESET_OK 0
#define MB_TFL_RESET_LIVE_HANDLES 1 /* 有活跃句柄，拒绝重解析 */
#define MB_TFL_RESET_REAL_FORCED_FAILED 2 /* mode=real 但真实加载失败 */

/* shim ABI 版本（与 interpreter.mbt 的 expected_capi_version 一致） */
#define MB_TFL_SHIM_ABI_VERSION 0x00010001

/* TfLiteSchemaVersion 兼容区间（当前上游 schema 版本为 3） */
#define MB_TFL_SCHEMA_MIN 1
#define MB_TFL_SCHEMA_MAX 16

/* 张量元数据 ABI 上限（既有私有 ABI，见 interpreter.mbt） */
#define MB_TFL_MAX_RANK 8
#define MB_TFL_MAX_NAME 63

/* real 路径 dtype 码（与 stub/README.md 一致）：
 * 0=Float32 1=Float16 2=Int32 3=UInt8 4=Int8 5=Int64，不支持=255 */
#define MB_TFL_DTYPE_UNSUPPORTED 255

/* ---------------- 真实库函数表（动态解析） ---------------- */
/* TfLite 量化参数（ABI：float + int32，8 字节） */
typedef struct mb_tfl_quant_params {
  float scale;
  int32_t zero_point;
} mb_tfl_quant_params;

/* 与 tensorflow/lite/core/c/c_api.h 一一对应的函数指针（cdecl）。 */
typedef struct mb_tfl_real_api {
  /* 版本探测 */
  const char *(*TfLiteVersion)(void);
  int (*TfLiteSchemaVersion)(void);
  /* model（句柄信封由 dispatch 层持有模型字节副本） */
  void *(*TfLiteModelCreate)(const void *model_data, size_t model_size);
  void (*TfLiteModelDelete)(void *model);
  /* options */
  void *(*TfLiteInterpreterOptionsCreate)(void);
  void (*TfLiteInterpreterOptionsDelete)(void *options);
  void (*TfLiteInterpreterOptionsSetNumThreads)(void *options,
                                                int32_t num_threads);
  /* interpreter */
  void *(*TfLiteInterpreterCreate)(const void *model, const void *options);
  void (*TfLiteInterpreterDelete)(void *interpreter);
  /* count / tensor（借用） */
  int32_t (*TfLiteInterpreterGetInputTensorCount)(const void *interpreter);
  int32_t (*TfLiteInterpreterGetOutputTensorCount)(const void *interpreter);
  void *(*TfLiteInterpreterGetInputTensor)(const void *interpreter,
                                           int32_t input_index);
  const void *(*TfLiteInterpreterGetOutputTensor)(const void *interpreter,
                                                  int32_t output_index);
  /* resize / allocate / invoke */
  int (*TfLiteInterpreterResizeInputTensor)(void *interpreter,
                                            int32_t input_index,
                                            const int *input_dims,
                                            int32_t input_dims_size);
  int (*TfLiteInterpreterAllocateTensors)(void *interpreter);
  int (*TfLiteInterpreterInvoke)(void *interpreter);
  /* tensor 元数据 / 数据搬运 */
  int (*TfLiteTensorType)(const void *tensor);
  int32_t (*TfLiteTensorNumDims)(const void *tensor);
  int32_t (*TfLiteTensorDim)(const void *tensor, int32_t dim_index);
  size_t (*TfLiteTensorByteSize)(const void *tensor);
  const char *(*TfLiteTensorName)(const void *tensor);
  mb_tfl_quant_params (*TfLiteTensorQuantizationParams)(const void *tensor);
  int (*TfLiteTensorCopyFromBuffer)(void *tensor, const void *input_data,
                                    size_t input_data_size);
  int (*TfLiteTensorCopyToBuffer)(const void *tensor, void *output_data,
                                  size_t output_data_size);
} mb_tfl_real_api;

/* ---------------- real 加载器（mb_tfl_real.c） ---------------- */
/* 加载结果：status 为 MB_TFL_LOAD_F1/F2/F3；detail 为人类可读分类明细
 * （UTF-8，如 "not_pe_image" / "missing_export:TfLiteModelCreate" /
 * "schema_incompatible:7" / "load_error:126"）。 */
typedef struct mb_tfl_real_result {
  int32_t status;      /* MB_TFL_LOAD_OK 或 F1/F2/F3 */
  int32_t win_error;   /* GetLastError()/errno 附加信息（无则 0） */
  int32_t schema_version; /* 解析到的 TfLiteSchemaVersion；未解析 = -1 */
  char tfl_version[32];   /* TfLiteVersion() 文本；未解析 = "" */
  char detail[128];       /* 分类明细（UTF-8） */
} mb_tfl_real_result;

/* 尝试加载真实库。path_utf8 为空(NULL/len<=0) = 标准搜索（库名直接交给
 * LoadLibraryW / dlopen）。force_fail_class 为 1|2|3 时注入对应失败分类
 * （白盒故障注入，不接触文件系统），0 = 不注入。
 * 成功时 api_out 填充已解析函数表并保持模块已加载；失败时模块不驻留。
 * 返回 MB_TFL_LOAD_OK 或 F1/F2/F3。 */
int32_t mb_tfl_real_try_load(const char *path_utf8, int32_t path_len,
                             int32_t force_fail_class, mb_tfl_real_api *api_out,
                             mb_tfl_real_result *result_out);

/* 释放已加载的真实库（若未加载则无操作）。 */
void mb_tfl_real_unload(void);

#ifdef __cplusplus
}
#endif

#endif /* MB_TFL_BACKEND_H */
