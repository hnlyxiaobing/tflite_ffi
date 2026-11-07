# tflite_ffi · 公开 API（API.md）

> 与 `pkg.generated.mbti` 一致。`declare` 函数**无实现**（预期 `0068`）；`extern "C"` 只有声明，符号由后续 `native-stub` 提供。
> `preferred_target = "native"`。错误传播统一 `raise TfLiteError`。

## 外部句柄（`#external` = C `void*`，MoonBit 不引用计数，永不跨模块传递）

| 句柄 | C 侧对应 | 释放点 |
|---|---|---|
| `TfLiteModelRaw` | `TfLiteModel*` | `Interpreter::close`（`owns_model=true`） |
| `TfLiteOptionsRaw` | `TfLiteInterpreterOptions*` | 创建 interpreter 后由 shim 释放 |
| `TfLiteInterpreterRaw` | `TfLiteInterpreter*` | `Interpreter::close` |
| `TfLiteTensorRaw` | `TfLiteTensor*` | **借用，不单独释放** |

## 外部 C shim 声明（15 个）

| shim 签名（省略 `pub extern "C" fn ... = "同名符号"`） | 所有权标注 | C 侧语义 |
|---|---|---|
| `mb_tfl_capi_version() -> Int` | — | 打包版本，用于兼容性断言 |
| `mb_tfl_model_create(model_bytes : Bytes, size : Int) -> TfLiteModelRaw` | `#borrow(model_bytes)` | 只读/复制模型字节 |
| `mb_tfl_model_delete(model)` | — | 释放 model |
| `mb_tfl_options_create() -> TfLiteOptionsRaw` | — | 创建 options |
| `mb_tfl_options_set_threads(options, n)` | — | 必须在 create interpreter 之前 |
| `mb_tfl_options_delete(options)` | — | 释放 options |
| `mb_tfl_interpreter_create(model, options) -> TfLiteInterpreterRaw` | — | 只引用 model，不转移所有权 |
| `mb_tfl_interpreter_delete(interp)` | — | 释放 interpreter（不释放 model） |
| `mb_tfl_input_count(interp) -> Int` / `mb_tfl_output_count(interp) -> Int` | — | 张量数量 |
| `mb_tfl_input_tensor(interp, index)` / `mb_tfl_output_tensor(interp, index) -> TfLiteTensorRaw` | — | 借用句柄 |
| `mb_tfl_resize_input(interp, index, dims : FixedArray[Int], dims_len) -> StatusCode` | `#borrow(dims)` | 动态尺寸 |
| `mb_tfl_allocate_tensors(interp) -> StatusCode` | — | 分配张量 |
| `mb_tfl_tensor_copy_from(tensor, src : Bytes, size) -> StatusCode` | `#borrow(src)` | 写入输入 |
| `mb_tfl_tensor_copy_to(tensor, dst : FixedArray[Byte], size) -> StatusCode` | `#borrow(dst)` | 读出输出 |
| `mb_tfl_invoke(interp) -> StatusCode` | — | 同步推理 |

> **无回调**：推理是同步调用，故不使用 `FuncRef` / `#owned`，规避跨线程问题。

## 值类型 / 错误

`Interpreter` · `InterpreterState` · `InterpreterOptions` · `TensorDesc` · `TensorDtype` · `Quantization` · `TfLiteError`（`pub suberror`，12 个构造）· `TensorIndex` · `StatusCode` · `InferenceRuntime`(trait)。

## MoonBit 侧公开 API（全部 `declare`）

| 签名 | 参数与所有权 | 返回 / 错误 | 资源与线程约束 | TODO |
|---|---|---|---|---|
| `Interpreter::from_bytes(model_bytes : Bytes, options : InterpreterOptions) -> Interpreter raise TfLiteError` | `model_bytes` 只读；失败按创建逆序释放 | 包装值 `owns_model=true` / `TfLiteError` | 同一 Interpreter 禁止并发 invoke | shim C 文件、`native-stub`、版本断言 |
| `Interpreter::close(self) -> Unit raise TfLiteError` | 消耗释放责任 | `Unit` / `AlreadyClosed` | 必须与 invoke 串行；幂等 | 三个句柄逆序释放 |
| `Interpreter::set_input(self, index : TensorIndex, data : Bytes) -> Unit raise TfLiteError` | `data` 只读 | `Unit` / `InvalidTensorIndex`、`BufferSizeMismatch`、`CopyFromBufferFailed` | 与 invoke 串行 | 形状/dtype 校验 |
| `Interpreter::output_raw(self, index : TensorIndex) -> Bytes raise TfLiteError` | `self` 只读 | 原始张量字节（不做类型解释） | 与 invoke 串行 | 输出缓冲分配与容量校验 |
| `Interpreter::invoke(self) -> Unit raise TfLiteError` | `self` 只读 | `Unit` / `InvokeFailed(code)` | **同一 Interpreter 不可并发** | 同步调用 |
| `Interpreter::output_desc(self, index : TensorIndex) -> TensorDesc raise TfLiteError` | `self` 只读 | 形状/dtype/字节数快照 | 与 invoke 串行 | 从 shim 取元数据 |

## 非目标

预处理/后处理、模型下载、模型 zoo、量化决策、GPU/delegate、Extension/opaque API、`foreign_library` 导出。

## 状态与已知阻塞

`moon check`：✅ 0 error，6 × `0068`。`moon build` / `moon test`：❌ **预期链接期失败**（shim 未实现）。API 快照：`pkg.generated.mbti`。
