///|
/// TensorFlow Lite / LiteRT C API 的 MoonBit FFI 契约。
///
/// 本文件是：外部句柄声明、`extern "C"` shim 签名（API.md 的 17 个，包私有
/// 实现 ABI，不进入 `moon info` 快照）、中性值类型与错误模型。
/// MoonBit 侧公开 API 的实现在 `interpreter.mbt`；
/// 17 个 shim 的桌面确定性 C 实现在 `stub/mb_tfl_stub.c`（CI 默认后端）。
///
/// 所有权总则：`#external` 句柄是 C 侧 `void*`，MoonBit 不做引用计数；
/// 每个由 `*_create` / `*_obtain` 返回的句柄必须由对应 `*_delete` / `*_release` 释放，
/// 且只能释放一次。`Interpreter` 是 MoonBit 侧的 RAII 包装值，用于集中记录释放责任。
/// 平台约束：仅 `native` 目标（理由见 `DECISIONS.md` §1、`DESIGN.md` §7），Android / Linux x86-64 验证。
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
/// 冻结前 P0（决策 5）：**字段全部包私有**——MoonBit 无字段级可见性修饰符，
/// `pub(all)` 会把 `mut state` 一并公开，`pub` 则只做到「字段包外只读」
/// （实测 `pub struct` 下包外仍可 `interp.state` 读取），故整体收紧为
/// **`struct Interpreter`（无 `pub`）**：包外该类型为抽象类型，字段与结构体
/// 字面量均不可见（实测包外读 `interp.state` 报「abstract type and not a struct」）。
/// 包外只读取经 `Interpreter::{state, input_count, output_count}` 访问器；
/// 6 个既有公开方法签名零变化。
/// `state` 仍为 `mut`：状态机转移（Ready/Invoking/Closed）是 close 不二次释放语义的实现前提，
/// 字段名与类型不变，仅可见性收紧；包内实现直接读写字段。
struct Interpreter {
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
/// （冻结前 P0 · 决策 2）原 `pub(open) trait InferenceRuntime` 已删除：
/// 唯一消费者是测试替身，后端抽象由 `pose::PoseBackend` 承担（组合根适配，
/// 见 `DECISIONS.md` §6），`Interpreter` 不再暴露任何 trait 接口。

///|
/// ---- 外部 C shim 声明（API.md 的 17 个；包私有实现 ABI）----
/// 以下符号由 `stub/mb_tfl_stub.c`（`native-stub`，CI 默认后端）提供，
/// 一对一转发到 `c_api.h` 的语义。
/// shim 存在的意义：隔离 GObject/结构体 ABI、统一 status code、集中处理 `#borrow`/`#owned`。
/// 冻结前 P0（决策 6）：可见性由 `pub` 收紧为包私有，**不再出现在 `moon info` 快照**；
/// 符号名、签名与实现不变，包内 `interpreter.mbt` 调用点零改动。
/// 其中 `_mb_tfl_resize_input` / `_mb_tfl_allocate_tensors` 两个绑定带 `_` 前缀
/// （库层暂无调用点，见各自注释）；C 符号仍为 `mb_tfl_*` 同名。
/// 本文件为桌面确定性 stub；真实 libtensorflowlite_c 对接与数值对齐留待真实库对接阶段。

///|
/// 返回打包后的 C API 版本号；仅用于运行时兼容性断言。
extern "C" fn mb_tfl_capi_version() -> Int32 = "mb_tfl_capi_version"

///|
/// 从模型字节创建 model。`model_bytes` 为 `#borrow`：C 侧只读取/复制，不 decref。
#borrow(model_bytes)
extern "C" fn mb_tfl_model_create(
  model_bytes : Bytes,
  size : Int32,
) -> TfLiteModelRaw = "mb_tfl_model_create"

///|
/// 释放 model 句柄。所有权：调用后该句柄失效，不得再次传入任何 shim。
extern "C" fn mb_tfl_model_delete(model : TfLiteModelRaw) -> Unit = "mb_tfl_model_delete"

///|
/// 创建 options 句柄。
extern "C" fn mb_tfl_options_create() -> TfLiteOptionsRaw = "mb_tfl_options_create"

///|
/// 设置线程数（必须在 interpreter 创建之前调用）。
extern "C" fn mb_tfl_options_set_threads(
  options : TfLiteOptionsRaw,
  n : Int32,
) -> Unit = "mb_tfl_options_set_threads"

///|
/// 释放 options 句柄。
extern "C" fn mb_tfl_options_delete(options : TfLiteOptionsRaw) -> Unit = "mb_tfl_options_delete"

///|
/// 创建解释器；`model` 所有权不转移，解释器仅引用它。
extern "C" fn mb_tfl_interpreter_create(
  model : TfLiteModelRaw,
  options : TfLiteOptionsRaw,
) -> TfLiteInterpreterRaw = "mb_tfl_interpreter_create"

///|
/// 释放解释器句柄（不释放 model）。
extern "C" fn mb_tfl_interpreter_delete(interp : TfLiteInterpreterRaw) -> Unit = "mb_tfl_interpreter_delete"

///|
/// 输入 / 输出张量数量。
extern "C" fn mb_tfl_input_count(interp : TfLiteInterpreterRaw) -> Int32 = "mb_tfl_input_count"

///|
extern "C" fn mb_tfl_output_count(interp : TfLiteInterpreterRaw) -> Int32 = "mb_tfl_output_count"

///|
/// 获取张量句柄（借用语义：生命周期依附于 interp，不可单独释放）。
extern "C" fn mb_tfl_input_tensor(
  interp : TfLiteInterpreterRaw,
  index : Int32,
) -> TfLiteTensorRaw = "mb_tfl_input_tensor"

///|
extern "C" fn mb_tfl_output_tensor(
  interp : TfLiteInterpreterRaw,
  index : Int32,
) -> TfLiteTensorRaw = "mb_tfl_output_tensor"

///|
/// 动态尺寸调整；`dims` 为 `#borrow`，C 侧只读取。
/// 绑定名 `_` 前缀：C 符号仍是 `mb_tfl_resize_input`（签名与 `stub/mb_tfl_stub.c`
/// 一对一，零改动），但**库层当前无调用点**（MoonBit 层 resize API 不在冻结
/// 公开面内），`moon check --deny-warn` 会把无调用点的私有函数报为
/// `unused_value`；`_` 前缀是 MoonBit 对「暂无调用点」的标记豁免。
/// 调用点在白盒测试（`tflite_ffi_wbtest.mbt`）。后续若暴露 MoonBit 层
/// resize API，去掉下划线前缀即恢复正名。
#borrow(dims)
extern "C" fn _mb_tfl_resize_input(
  interp : TfLiteInterpreterRaw,
  index : Int32,
  dims : FixedArray[Int32],
  dims_len : Int32,
) -> StatusCode = "mb_tfl_resize_input"

///|
/// 分配张量；绑定名 `_` 前缀理由同 `_mb_tfl_resize_input`（库层暂无调用点，
/// C 符号 `mb_tfl_allocate_tensors` 不变，调用点在白盒测试）。
extern "C" fn _mb_tfl_allocate_tensors(
  interp : TfLiteInterpreterRaw,
) -> StatusCode = "mb_tfl_allocate_tensors"

///|
/// 写入输入张量；`src` 为 `#borrow`，C 侧复制到张量内部缓冲。
#borrow(src)
extern "C" fn mb_tfl_tensor_copy_from(
  tensor : TfLiteTensorRaw,
  src : Bytes,
  size : Int32,
) -> StatusCode = "mb_tfl_tensor_copy_from"

///|
/// 读出输出张量；`dst` 为 `#borrow`，由 C 侧填充，长度必须 >= `size`。
#borrow(dst)
extern "C" fn mb_tfl_tensor_copy_to(
  tensor : TfLiteTensorRaw,
  dst : FixedArray[Byte],
  size : Int32,
) -> StatusCode = "mb_tfl_tensor_copy_to"

///|
/// 执行推理。线程约束：同一 `interp` 不可并发 invoke；跨 interp 可并发。
extern "C" fn mb_tfl_invoke(interp : TfLiteInterpreterRaw) -> StatusCode = "mb_tfl_invoke"

///|
/// ---- MoonBit 侧公开 API ----
/// `Interpreter::{from_bytes, close, set_input, output_raw, invoke, output_desc}`
/// 的实现在 `interpreter.mbt`（签名与 API.md / `pkg.generated.mbti` 一致）。
