# tflite_ffi · 公开 API（API.md）

> 与 `pkg.generated.mbti` 快照一致（快照由 `moon check` / `moon build` 自动同步；本轮**未运行 `moon info`、未手工编辑快照**，最终快照审阅由主控统一执行）。
> 状态（R2 冻结前 P0 整改轮，2026-11-07）：**全部函数为真实实现**（无 `declare` 存根、无 `0068`）；`extern "C"` shim 由 `stub/mb_tfl_stub.c`（`native-stub`，CI 默认后端）提供，`moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check` 全绿。
> `preferred_target = "native"`。错误传播统一 `raise TfLiteError`。

## 外部句柄（`#external` = C `void*`，MoonBit 不引用计数，永不跨模块传递）

| 句柄 | C 侧对应 | 释放点 |
|---|---|---|
| `TfLiteModelRaw` | `TfLiteModel*` | `Interpreter::close`（`owns_model=true`） |
| `TfLiteOptionsRaw` | `TfLiteInterpreterOptions*` | 创建 interpreter 后由 `from_bytes` 立即调用 `mb_tfl_options_delete` 释放 |
| `TfLiteInterpreterRaw` | `TfLiteInterpreter*` | `Interpreter::close` |
| `TfLiteTensorRaw` | `TfLiteTensor*` | **借用，不单独释放** |

## 外部 C shim 声明（**17 个**；包私有实现 ABI，非公共 API）

> **冻结前 P0 · 决策 6**：17 个 `mb_tfl_*` shim 的可见性由 `pub` 收紧为**包私有**，
> 因此**不再出现在 `moon info` / `pkg.generated.mbti` 快照**中；C 符号名、签名与
> `stub/mb_tfl_stub.c` 实现零改动，包内 `interpreter.mbt` 的调用点零改动
> （仅白盒测试的 2 个调用点随绑定名同步更新，见下）。
> **决策 9（数量修正）**：原文档写 15，实际为 **17**——原文把 `input_count`/`output_count`、
> `input_tensor`/`output_tensor` 各合并成一行，15 行其实对应 17 个符号；本表已拆为一行一符号。
> 以源码与快照为准：R1 快照恰有 17 个 `mb_tfl_*` 导出。

| shim 签名（`extern "C" fn ... = "同名符号"`，均无 `pub`） | 所有权标注 | C 侧语义 |
|---|---|---|
| `mb_tfl_capi_version() -> Int` | — | 打包版本，用于兼容性断言 |
| `mb_tfl_model_create(model_bytes : Bytes, size : Int) -> TfLiteModelRaw` | `#borrow(model_bytes)` | 只读/复制模型字节 |
| `mb_tfl_model_delete(model)` | — | 释放 model |
| `mb_tfl_options_create() -> TfLiteOptionsRaw` | — | 创建 options |
| `mb_tfl_options_set_threads(options, n)` | — | 必须在 create interpreter 之前 |
| `mb_tfl_options_delete(options)` | — | 释放 options |
| `mb_tfl_interpreter_create(model, options) -> TfLiteInterpreterRaw` | — | 只引用 model，不转移所有权 |
| `mb_tfl_interpreter_delete(interp)` | — | 释放 interpreter（不释放 model） |
| `mb_tfl_input_count(interp) -> Int` | — | 输入张量数量 |
| `mb_tfl_output_count(interp) -> Int` | — | 输出张量数量 |
| `mb_tfl_input_tensor(interp, index) -> TfLiteTensorRaw` | — | 借用句柄 |
| `mb_tfl_output_tensor(interp, index) -> TfLiteTensorRaw` | — | 借用句柄 |
| `_mb_tfl_resize_input(interp, index, dims : FixedArray[Int], dims_len) -> StatusCode`（C 符号 `mb_tfl_resize_input`） | `#borrow(dims)` | 动态尺寸 |
| `_mb_tfl_allocate_tensors(interp) -> StatusCode`（C 符号 `mb_tfl_allocate_tensors`） | — | 分配张量 |
| `mb_tfl_tensor_copy_from(tensor, src : Bytes, size) -> StatusCode` | `#borrow(src)` | 写入输入 |
| `mb_tfl_tensor_copy_to(tensor, dst : FixedArray[Byte], size) -> StatusCode` | `#borrow(dst)` | 读出输出 |
| `mb_tfl_invoke(interp) -> StatusCode` | — | 同步推理 |

> **`_` 前缀绑定（2 个）**：`mb_tfl_resize_input` / `mb_tfl_allocate_tensors` 在**库层当前无调用点**
> （MoonBit 层 resize/allocate API 不在冻结公开面内），而 `moon check --deny-warn` 会把无调用点的
> 私有函数报为 `unused_value`。故 MoonBit 侧绑定名写作 `_mb_tfl_resize_input` /
> `_mb_tfl_allocate_tensors`（**C 符号字符串 `= "mb_tfl_resize_input"` / `= "mb_tfl_allocate_tensors"`
> 与签名零改动**，调用点在白盒测试 `tflite_ffi_wbtest.mbt`，与包内调用同步更新）。
> R2 若暴露 MoonBit 层 resize API，去掉下划线前缀即恢复正名。
>
> 另有 4 个**私有内部 ABI** 符号（`tflite_ffi_private_{model,options,interp}_alive`、
> `tflite_ffi_private_tensor_meta`，声明于 `interpreter.mbt`），本就不属于公开面，未做改动。

> **无回调**：推理是同步调用，故不使用 `FuncRef` / `#owned`，规避跨线程问题。

## 值类型 / 错误

`Interpreter`（**抽象类型**：字段全私有，包外不可读字段、不可构造字面量）· `InterpreterState` · `InterpreterOptions` · `TensorDesc` · `TensorDtype`（含 `Int64` 分支）· `Quantization` · `TfLiteError`（`pub(all) suberror`，**13** 个构造）· `TensorIndex` · `StatusCode`。

> 原 `InferenceRuntime`(trait) 已于冻结前 P0 **删除**（决策 2），见下节。

## 冻结前追认记录（R2 准备轮 · 加法性追认）

以下三项经核对**源码现状已符合**，仅在本轮文档中追认（冻结后即为契约）：

| 项 | 现状（源码） | 追认说明 |
|---|---|---|
| `TfLiteError` 为 `pub(all) suberror` | `tflite_ffi.mbt`：`#derive(Debug)` + `pub(all) suberror TfLiteError` | 包外可构造/匹配全部错误构造；13 个构造全部公开 |
| `TfLiteError::NullHandle` 构造器公开 | `pub(all)` 使其随错误类型整体公开（快照含 `NullHandle(String)`） | 测试与包外适配器可匹配 `NullHandle(_)` |
| `TensorDtype::Int64` 分支 | `pub(all) enum TensorDtype` 含 `Int64`；`dtype_of_code(5) => Int64` | 白盒 `wb dtype_of_code maps all supported codes` 覆盖 |

## MoonBit 侧公开 API（全部为真实实现，签名冻结）

| 签名 | 参数与所有权 | 返回 / 错误 | 资源与线程约束 |
|---|---|---|---|
| `Interpreter::from_bytes(model_bytes : Bytes, options : InterpreterOptions) -> Interpreter raise TfLiteError` | `model_bytes` 只读；失败按创建逆序释放 | 包装值 `owns_model=true` / `TfLiteError` | 同一 Interpreter 禁止并发 invoke |
| `Interpreter::close(self) -> Unit raise TfLiteError` | 消耗释放责任 | `Unit` / `AlreadyClosed` | 必须与 invoke 串行；**不会二次释放，重复调用返回明确错误** |
| `Interpreter::set_input(self, index : TensorIndex, data : Bytes) -> Unit raise TfLiteError` | `data` 只读 | `Unit` / `InvalidTensorIndex`、`BufferSizeMismatch`、`CopyFromBufferFailed` | 与 invoke 串行 |
| `Interpreter::output_raw(self, index : TensorIndex) -> Bytes raise TfLiteError` | `self` 只读 | 原始张量字节（不做类型解释） | 与 invoke 串行 |
| `Interpreter::invoke(self) -> Unit raise TfLiteError` | `self` 只读 | `Unit` / `InvokeFailed(code)` | **同一 Interpreter 不可并发** |
| `Interpreter::output_desc(self, index : TensorIndex) -> TensorDesc raise TfLiteError` | `self` 只读 | 形状/dtype/字节数快照 | 与 invoke 串行 |
| `Interpreter::state(self) -> InterpreterState` | 只读访问器，**无 setter** | 状态机快照 | 字段私有化后的包外唯一状态读取通道 |
| `Interpreter::input_count(self) -> Int32` | 只读访问器 | 创建时取定的输入张量数 | 不可变 |
| `Interpreter::output_count(self) -> Int32` | 只读访问器 | 创建时取定的输出张量数 | 不可变 |

### 字段可见性（冻结前 P0 · 决策 5）

MoonBit **没有字段级可见性修饰符**：`pub(all) struct` 会把 `mut state` 一并公开，而 `pub struct`
实测仍允许包外读取字段（包外 `interp.state` 可编译，仅不可写）。因此 `Interpreter` 整体收紧为
**`struct Interpreter`（无 `pub`）**——包外为抽象类型：字段与结构体字面量均不可访问
（实测包外读 `interp.state` 报 `abstract type and not a struct`），包内实现仍直接读写 `mut state`。
包外读取一律经上表 3 个只读访问器；**6 个既有公开方法签名零变化**。

### 已删除接口（冻结前 P0 · 决策 2）

`pub(open) trait InferenceRuntime { fn invoke(Self) -> Unit raise TfLiteError; fn output_count(Self) -> Int32 }`
已删除：唯一消费者是测试替身（外部实现测试随之删除），后端抽象由 `pose::PoseBackend`
（`pub(open)`）承担，组合根适配模式不变（ADR-0004）。`Interpreter` 的公开方法零变化。

## 非目标

预处理/后处理、模型下载、模型 zoo、量化决策、GPU/delegate、Extension/opaque API、`foreign_library` 导出。

## 门禁与状态（R2 冻结前 P0 实跑）

在 `tflite_ffi/` 依次实跑，全部 exit 0：

| 命令 | 结果 |
|---|---|
| `moon clean` | ✅ exit 0 |
| `moon check --deny-warn` | ✅ exit 0（0 error / 0 warning，无 `0068`、无 `unused_value`） |
| `moon build` | ✅ exit 0（链接 `stub/mb_tfl_stub.c`，无外部库） |
| `moon test` | ✅ exit 0，**21 tests 全过**（12 黑盒 + 9 白盒；R1 基线 23，删除 2 个、迁入 4 个，见 README 测试数明细） |
| `moon fmt --check` | ✅ exit 0 |

真实 `libtensorflowlite_c` 对接与数值对齐（<1e-4）留待 **R2**；本轮保持项目内 C stub 双路径，stub 为 CI 默认后端。
