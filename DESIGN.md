# tflite_ffi · 设计契约（DESIGN.md）

> Round-1 / 2026-11-06 ｜ 状态：架构与声明可评审，无 shim 实现、无推理逻辑

## 1. 分层位置与职责

L3 感知绑定层的**推理运行时 FFI 封装**。职责：把 LiteRT `c_api.h` 的稳定 C ABI 映射为 MoonBit 值类型与显式错误。不做任何图像处理。

## 2. 模块边界 / 依赖方向 / 数据流

```
组合根适配器 (impl pose::PoseBackend)
      │ infer(Bytes) -> Bytes
      ▼
Interpreter::set_input / invoke / output_raw     ← declare（MoonBit 侧公开 API）
      │
      ▼
mb_tfl_*  extern "C" shim（15 个，本轮只有声明）
      │
      ▼
tensorflowlite_c.so / c_api.h
```

本库**不 import `pose`**；`pose` 也不 import 本库（ADR-0004）。零跨模块 import（ADR-0002）。

## 3. 核心数据结构

| 类型 | 作用 |
|---|---|
| `TfLiteModelRaw` / `TfLiteOptionsRaw` / `TfLiteInterpreterRaw` / `TfLiteTensorRaw` | `#external` 外部句柄，C 后端 = `void*`，MoonBit **不做引用计数** |
| `Interpreter { model, interp, owns_model, state, input_count, output_count }` | MoonBit 侧 RAII 包装值，集中记录释放责任 |
| `TensorDesc` / `TensorDtype` / `Quantization` | 张量只读快照 |
| `InterpreterOptions` / `InterpreterState` | 选项纯值 / 状态机 |
| `TfLiteError` | 12 个错误构造，C status code 已枚举化 |
| `TensorIndex` / `StatusCode` | 索引 / 状态码别名 |
| `InferenceRuntime` trait | `invoke` / `output_count` 契约（供组合根适配） |

## 4. 错误模型

`TfLiteError`：`LibraryNotLoaded`、`ModelCreateFailed(code)`、`InterpreterCreateFailed(code)`、`AllocateTensorsFailed(code)`、`InvalidTensorIndex`、`ResizeFailed`、`CopyFromBufferFailed`、`CopyToBufferFailed`、`InvokeFailed`、`BufferSizeMismatch`、`UnsupportedDtype`、`AlreadyClosed`、`NullHandle`。

规则：shim 边界把每个非 0 status code 转成对应错误；禁止把裸 `Int` 泄漏给上层；禁止 panic。

## 5. 资源生命周期

| 资源 | 获取 | 唯一释放点 | 规则 |
|---|---|---|---|
| model | `mb_tfl_model_create` | `Interpreter::close`（`owns_model=true`） | 只释放一次 |
| options | `mb_tfl_options_create` | 创建 interpreter 后由 shim 释放（实现轮） | 生命周期最短 |
| interpreter | `mb_tfl_interpreter_create` | `Interpreter::close` | 只释放一次 |
| tensor | `mb_tfl_*_tensor` | **不单独释放**（借用，依附 interp） | interp 释放后失效 |

`Interpreter::close` 幂等；调用后 `state = Closed`，再次调用返回 `AlreadyClosed`。创建失败时按创建逆序释放已获取的句柄。

## 6. 线程 / 并发边界

- 同一 `Interpreter` **禁止并发 `invoke`**；不同 Interpreter 可并发。
- `close` 必须与所有 `invoke` 串行。
- `from_bytes` 在调用线程本地完成；返回包装值可由其它线程持有，但调用方须自行串行化 `invoke`。

## 7. 平台约束与外部依赖

- `preferred_target = "native"`（本轮调整）；wasm 目标下 `extern "C"` 报 E4156。
- Windows native 需 MSVC `cl.exe`/`clang-cl.exe`，MinGW 不支持；LLVM 后端不支持 FFI。
- native 后端**无法把 `foreign_library` 导出为可链接 `.so`** → Android 集成必须走「C stub + 宿主 NDK/CMake」。
- 后续依赖：`libtensorflowlite_c.so`、`native-stub` C 文件、`link.native.cc/cc-flags/cc-link-flags`（由 `moon_abi` 生成）。

## 8. 外部类型 / 句柄 / 回调 / 所有权规则

| 类别 | 声明 | 规则 |
|---|---|---|
| 外部类型 | `#external pub type TfLiteModelRaw` 等 4 个 | C 后端 `void*`；不参与 MoonBit 引用计数；**永不跨模块传递** |
| 外部函数 | `pub extern "C" fn mb_tfl_* ... = "mb_tfl_*"` 共 15 个 | 符号由后续 `native-stub` 提供；一对一转发 `c_api.h`；统一 status code |
| `#borrow` | `mb_tfl_model_create(model_bytes)`、`mb_tfl_resize_input(dims)`、`mb_tfl_tensor_copy_from(src)`、`mb_tfl_tensor_copy_to(dst)` | C 侧只读/复制或填充，不 `decref`；MoonBit 保留所有权 |
| 回调 | **本库无回调** | 推理是同步调用，避免引入 FuncRef 与线程问题 |
| 缓冲 | `FixedArray[Byte]` / `Bytes` + `size` | 必须校验 capacity；不足返回 `BufferSizeMismatch` |

> `#borrow` / `#owned` 是**写在函数声明之前的独立属性行**，不是参数注解；官方明确默认语义正从 `#owned` 迁移到 `#borrow`，因此本库全部显式标注（ADR-0007 / ADR-0009）。

## 9. 可替换性与实现细节不泄漏

上层只看到 `Interpreter` / `TensorDesc` / `Bytes`；看不到 `TfLiteModelRaw` 等裸句柄、模型路径、量化格式、引擎版本。换 ONNX / MediaPipe 后端只需组合根换适配器，`pose::detect` 不变。

## 10. 测试策略

| 层次 | 内容 |
|---|---|
| 黑盒 | 224×224 分类模型与 Python `tflite-runtime` 逐元素误差 < 1e-4 |
| 白盒 | status code → `TfLiteError` 映射；`close` 幂等；空句柄；缓冲长度不足 |
| 平台 | 桌面 x86-64 先验证；上板测 armv7/arm64 与帧率预算 |
| 门禁 | `moon fmt --check` / `moon check`（本轮不加 `--deny-warn`） |

## 11. 验收标准（实现轮）

1. 分类模型跑通且数值对齐；2. 重复 close / 空句柄不崩溃；3. 所有错误经 `TfLiteError` 传播；4. R4 `--deny-warn` 转绿。

## 12. 未解决问题 / 待验证假设

- Q10：C API 是否覆盖目标模型全部算子（当前只用 CPU，不用 delegate）。
- Q4：模型商用条款；`.so` 随包分发许可。
- E2：`#borrow` 默认语义迁移；E3：Android native 产物链路。

## 13. 当前状态与 TODO

`tflite_ffi.mbt` 已写入 4 个 `#external` 句柄、15 个 `extern "C"` shim 声明、值类型、错误模型与 6 个 `declare` API，全部公开 API 有 `///` 文档注释与 `TODO(实现轮)`。**无 C shim、无 `native-stub`、无链接配置、无业务逻辑**。

## References

`../docs/adr/ADR-0004`、`ADR-0007`、`ADR-0008` · `https://tensorflow.org/guide/versions` · `https://docs.moonbitlang.com/en/latest/language/ffi.html`
