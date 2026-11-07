///|
/// TensorFlow Lite / LiteRT C API 的 MoonBit FFI 契约。
///
/// 本文件是：外部句柄声明、`extern "C"` 公开 shim 签名（API.md 的 15 个）、
/// 中性值类型与错误模型。MoonBit 侧公开 API 的实现在 `interpreter.mbt`；
/// 15 个 shim 的桌面确定性 C 实现在 `stub/mb_tfl_stub.c`。
///
/// 所有权总则：`#external` 句柄是 C 侧 `void*`，MoonBit 不做引用计数；
/// 每个由 `*_create` / `*_obtain` 返回的句柄必须由对应 `*_delete` / `*_release` 释放，
/// 且只能释放一次。`Interpreter` 是 MoonBit 侧的 RAII 包装值，用于集中记录释放责任。
/// 平台约束：仅 `native` 目标（见 docs/adr/ADR-0007），Android / Linux x86-64 验证。
/// 许可：LiteRT C API 头文件 Apache-2.0；随包分发的 `.so` 与模型文件许可需单独审计。

///|
#external
pub type TfLiteModelRaw

///|
#external
pub type TfLiteOptionsRaw

///|
#external
pub type TfLiteInterpreterRaw

///|
#external
pub type TfLiteTensorRaw

///|
/// 张量数据类型（与 `TfLiteType` 对齐的子集）。
pub(all) enum TensorDtype {
  Float32
  Float16
  Int32
  UInt8
  Int8
  Int64
}

///|
/// 量化参数；无量化时 `scale = 0` 且 `zero_point = 0`。
pub(all) struct Quantization {
  scale : Double
  zero_point : Int32
}

///|
/// 张量描述（只读快照）。
pub(all) struct TensorDesc {
  name : String
  dtype : TensorDtype
  shape : Array[Int32]
  byte_size : Int32
  quantization : Quantization
}

///|
/// 解释器选项（纯值，在创建解释器时一次性传给 shim）。
pub(all) struct InterpreterOptions {
  thread_count : Int32
  allow_fp16 : Bool
}

///|
/// 推理状态。
pub(all) enum InterpreterState {
  Uninitialized
  Ready
  Invoking
  Closed
}

///|
/// MoonBit 侧解释器包装值。
/// `model` / `interp` 为 C 侧裸指针；`owns_model = true` 表示关闭时须同时释放模型。
/// 该值不可复制使用；`close` 后状态置为 `Closed`，再次调用任何方法返回 `AlreadyClosed`。
/// `state` 为 `mut`：状态机转移（Ready/Invoking/Closed）是 close 幂等语义的实现前提，
/// 字段名与类型不变。
pub(all) struct Interpreter {
  model : TfLiteModelRaw
  interp : TfLiteInterpreterRaw
  owns_model : Bool
  mut state : InterpreterState
  input_count : Int32
  output_count : Int32
}

///|
/// FFI 错误模型。C 侧 status code 一律转成可诊断的枚举值，不抛 panic。
/// `pub(all)`：测试与包外适配器需要构造/匹配具体错误构造（可见性最小纠错，签名不变）。
#derive(Debug)
pub(all) suberror TfLiteError {
  LibraryNotLoaded(String)
  ModelCreateFailed(Int32)
  InterpreterCreateFailed(Int32)
  AllocateTensorsFailed(Int32)
  InvalidTensorIndex(Int32)
  ResizeFailed(Int32, String)
  CopyFromBufferFailed(Int32)
  CopyToBufferFailed(Int32)
  InvokeFailed(Int32)
  BufferSizeMismatch(Int32, Int32)
  UnsupportedDtype(String)
  AlreadyClosed
  NullHandle(String)
}

///|
pub extend TfLiteError with Debug::{to_repr}

///|
/// 张量下标。
pub type TensorIndex = Int32

///|
/// C 侧 status code（0 = ok）。
pub type StatusCode = Int32

///|
/// 推理后端契约（供 `pose` 的组合根适配器实现；本库不依赖 `pose`）。
/// `pub(open)`：供包外实现（`pub` 只读，包外无法实现该 trait；可见性最小纠错，签名不变）。
pub(open) trait InferenceRuntime {
  fn invoke(Self) -> Unit raise TfLiteError
  fn output_count(Self) -> Int32
}

///|
/// ---- 外部 C shim 声明（API.md 的 15 个）----
/// 以下符号由 `stub/mb_tfl_stub.c`（`native-stub`）提供，一对一转发到 `c_api.h` 的语义。
/// shim 存在的意义：隔离 GObject/结构体 ABI、统一 status code、集中处理 `#borrow`/`#owned`。
/// 本轮为桌面确定性 stub；真实 libtensorflowlite_c 对接与数值对齐留待 R2。

///|
/// 返回打包后的 C API 版本号；仅用于运行时兼容性断言。
pub extern "C" fn mb_tfl_capi_version() -> Int32 = "mb_tfl_capi_version"

///|
/// 从模型字节创建 model。`model_bytes` 为 `#borrow`：C 侧只读取/复制，不 decref。
#borrow(model_bytes)
pub extern "C" fn mb_tfl_model_create(
  model_bytes : Bytes,
  size : Int32,
) -> TfLiteModelRaw = "mb_tfl_model_create"

///|
/// 释放 model 句柄。所有权：调用后该句柄失效，不得再次传入任何 shim。
pub extern "C" fn mb_tfl_model_delete(model : TfLiteModelRaw) -> Unit = "mb_tfl_model_delete"

///|
/// 创建 options 句柄。
pub extern "C" fn mb_tfl_options_create() -> TfLiteOptionsRaw = "mb_tfl_options_create"

///|
/// 设置线程数（必须在 interpreter 创建之前调用）。
pub extern "C" fn mb_tfl_options_set_threads(
  options : TfLiteOptionsRaw,
  n : Int32,
) -> Unit = "mb_tfl_options_set_threads"

///|
/// 释放 options 句柄。
pub extern "C" fn mb_tfl_options_delete(options : TfLiteOptionsRaw) -> Unit = "mb_tfl_options_delete"

///|
/// 创建解释器；`model` 所有权不转移，解释器仅引用它。
pub extern "C" fn mb_tfl_interpreter_create(
  model : TfLiteModelRaw,
  options : TfLiteOptionsRaw,
) -> TfLiteInterpreterRaw = "mb_tfl_interpreter_create"

///|
/// 释放解释器句柄（不释放 model）。
pub extern "C" fn mb_tfl_interpreter_delete(
  interp : TfLiteInterpreterRaw,
) -> Unit = "mb_tfl_interpreter_delete"

///|
/// 输入 / 输出张量数量。
pub extern "C" fn mb_tfl_input_count(interp : TfLiteInterpreterRaw) -> Int32 = "mb_tfl_input_count"

///|
pub extern "C" fn mb_tfl_output_count(interp : TfLiteInterpreterRaw) -> Int32 = "mb_tfl_output_count"

///|
/// 获取张量句柄（借用语义：生命周期依附于 interp，不可单独释放）。
pub extern "C" fn mb_tfl_input_tensor(
  interp : TfLiteInterpreterRaw,
  index : Int32,
) -> TfLiteTensorRaw = "mb_tfl_input_tensor"

///|
pub extern "C" fn mb_tfl_output_tensor(
  interp : TfLiteInterpreterRaw,
  index : Int32,
) -> TfLiteTensorRaw = "mb_tfl_output_tensor"

///|
/// 动态尺寸调整；`dims` 为 `#borrow`，C 侧只读取。
#borrow(dims)
pub extern "C" fn mb_tfl_resize_input(
  interp : TfLiteInterpreterRaw,
  index : Int32,
  dims : FixedArray[Int32],
  dims_len : Int32,
) -> StatusCode = "mb_tfl_resize_input"

///|
pub extern "C" fn mb_tfl_allocate_tensors(
  interp : TfLiteInterpreterRaw,
) -> StatusCode = "mb_tfl_allocate_tensors"

///|
/// 写入输入张量；`src` 为 `#borrow`，C 侧复制到张量内部缓冲。
#borrow(src)
pub extern "C" fn mb_tfl_tensor_copy_from(
  tensor : TfLiteTensorRaw,
  src : Bytes,
  size : Int32,
) -> StatusCode = "mb_tfl_tensor_copy_from"

///|
/// 读出输出张量；`dst` 为 `#borrow`，由 C 侧填充，长度必须 >= `size`。
#borrow(dst)
pub extern "C" fn mb_tfl_tensor_copy_to(
  tensor : TfLiteTensorRaw,
  dst : FixedArray[Byte],
  size : Int32,
) -> StatusCode = "mb_tfl_tensor_copy_to"

///|
/// 执行推理。线程约束：同一 `interp` 不可并发 invoke；跨 interp 可并发。
pub extern "C" fn mb_tfl_invoke(interp : TfLiteInterpreterRaw) -> StatusCode = "mb_tfl_invoke"

///|
/// ---- MoonBit 侧公开 API ----
/// `Interpreter::{from_bytes, close, set_input, output_raw, invoke, output_desc}`
/// 的实现在 `interpreter.mbt`（签名与 API.md / `pkg.generated.mbti` 一致）。
