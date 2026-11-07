# tflite_ffi · 设计契约（DESIGN.md）

> R2 冻结前 P0 整改轮 / 2026-11-07 ｜ 状态：**实现完成**（桌面确定性 C stub 双路径，
> stub 为 CI 默认后端）；`moon clean` / `moon check --deny-warn` / `moon build` /
> `moon test`（21 tests）/ `moon fmt --check` 五项门禁全绿。
> 真实 `libtensorflowlite_c` 对接与数值对齐留待 R2；**冻结前公开面只做三类变化**：
> 删除 `InferenceRuntime` 死接口、`Interpreter` 字段与 17 个 shim 私有化、文档化追认。

## 1. 分层位置与职责

L3 感知绑定层的**推理运行时 FFI 封装**。职责：把 LiteRT `c_api.h` 的稳定 C ABI 映射为 MoonBit 值类型与显式错误。不做任何图像处理。

## 2. 模块边界 / 依赖方向 / 数据流

```
组合根适配器 (impl pose::PoseBackend)
      │ infer(Bytes) -> Bytes
      ▼
Interpreter::set_input / invoke / output_raw     ← MoonBit 侧公开 API（6 方法 + 3 只读访问器，已实现）
      │
      ▼
mb_tfl_*  extern "C" shim（17 个，包私有实现 ABI，不进 moon info 快照）
      │
      ▼
stub/mb_tfl_stub.c（native-stub，CI 默认后端）
      │  R2 起可切换
      ▼
tensorflowlite_c.so / c_api.h
```

本库**不 import `pose`**；`pose` 也不 import 本库（ADR-0004）。零跨模块 import（ADR-0002）。

## 3. 核心数据结构

| 类型 | 作用 |
|---|---|
| `TfLiteModelRaw` / `TfLiteOptionsRaw` / `TfLiteInterpreterRaw` / `TfLiteTensorRaw` | `#external` 外部句柄，C 后端 = `void*`，MoonBit **不做引用计数** |
| `Interpreter`（**抽象类型，字段全私有**：`model, interp, owns_model, state, input_count, output_count`） | MoonBit 侧 RAII 包装值，集中记录释放责任；包外经 `state()` / `input_count()` / `output_count()` 只读访问 |
| `TensorDesc` / `TensorDtype`（含 `Int64`）/ `Quantization` | 张量只读快照 |
| `InterpreterOptions` / `InterpreterState` | 选项纯值 / 状态机 |
| `TfLiteError` | **13** 个错误构造（`pub(all) suberror`），C status code 已枚举化 |
| `TensorIndex` / `StatusCode` | 索引 / 状态码别名 |

> **冻结前 P0（决策 2）**：原 `pub(open) trait InferenceRuntime`（`invoke` / `output_count` 契约）
> 已删除——唯一消费者是测试替身；后端抽象由 `pose::PoseBackend` 承担（ADR-0004 组合根适配不变）。

## 4. 错误模型

`TfLiteError`：`LibraryNotLoaded`、`ModelCreateFailed(code)`、`InterpreterCreateFailed(code)`、`AllocateTensorsFailed(code)`、`InvalidTensorIndex`、`ResizeFailed`、`CopyFromBufferFailed`、`CopyToBufferFailed`、`InvokeFailed`、`BufferSizeMismatch`、`UnsupportedDtype`、`AlreadyClosed`、`NullHandle`（**13 个**）。

规则：shim 边界把每个非 0 status code 转成对应错误；禁止把裸 `Int` 泄漏给上层；禁止 panic。

## 5. 资源生命周期

| 资源 | 获取 | 唯一释放点 | 规则 |
|---|---|---|---|
| model | `mb_tfl_model_create` | `Interpreter::close`（`owns_model=true`） | 只释放一次 |
| options | `mb_tfl_options_create` | 创建 interpreter 后立即释放（`from_bytes` 内） | 生命周期最短 |
| interpreter | `mb_tfl_interpreter_create` | `Interpreter::close` | 只释放一次 |
| tensor | `mb_tfl_*_tensor` | **不单独释放**（借用，依附 interp） | interp 释放后失效 |

**close 语义（冻结前 P0 · 决策 8，与 API.md / README 统一措辞）**：
`Interpreter::close` **不会二次释放，重复调用返回明确错误**——首次调用置 `state = Closed`
并释放 interpreter → model，其后每次调用 raise `AlreadyClosed`（不触碰任何 C 句柄）。
创建失败时按创建逆序释放已获取的句柄。

## 6. 线程 / 并发边界

- 同一 `Interpreter` **禁止并发 `invoke`**；不同 Interpreter 可并发。
- `close` 必须与所有 `invoke` 串行。
- `from_bytes` 在调用线程本地完成；返回包装值可由其它线程持有，但调用方须自行串行化 `invoke`。

## 7. 平台约束与外部依赖

- `preferred_target = "native"`；wasm 目标下 `extern "C"` 报 E4156。
- Windows native 需 MSVC `cl.exe`/`clang-cl.exe`，MinGW 不支持；LLVM 后端不支持 FFI。
- native 后端**无法把 `foreign_library` 导出为可链接 `.so`** → Android 集成必须走「C stub + 宿主 NDK/CMake」。
- 依赖：`stub/mb_tfl_stub.c` 已落地（`moon.pkg` 的 `native-stub`，**CI 默认后端**，不引入任何外部库）；
  真实 `libtensorflowlite_c.so` 与 `link.native.cc/cc-flags/cc-link-flags`（由 `moon_abi` 生成）留待 R2。

## 8. 外部类型 / 句柄 / 回调 / 所有权规则

| 类别 | 声明 | 规则 |
|---|---|---|
| 外部类型 | `#external pub type TfLiteModelRaw` 等 4 个 | C 后端 `void*`；不参与 MoonBit 引用计数；**永不跨模块传递** |
| 外部函数 | `extern "C" fn mb_tfl_* ... = "mb_tfl_*"` 共 **17 个**（**包私有**，冻结前 P0 由 `pub` 收敛；其中 `resize_input` / `allocate_tensors` 的绑定带 `_` 前缀，C 符号不变，见 API.md） | 符号由 `stub/mb_tfl_stub.c` 提供；一对一转发 `c_api.h`；统一 status code；不进 `moon info` 快照 |
| `#borrow` | `mb_tfl_model_create(model_bytes)`、`mb_tfl_resize_input(dims)`、`mb_tfl_tensor_copy_from(src)`、`mb_tfl_tensor_copy_to(dst)` | C 侧只读/复制或填充，不 `decref`；MoonBit 保留所有权 |
| 回调 | **本库无回调** | 推理是同步调用，避免引入 FuncRef 与线程问题 |
| 缓冲 | `FixedArray[Byte]` / `Bytes` + `size` | 必须校验 capacity；不足返回 `BufferSizeMismatch` |

> `#borrow` / `#owned` 是**写在函数声明之前的独立属性行**，不是参数注解；官方明确默认语义正从 `#owned` 迁移到 `#borrow`，因此本库全部显式标注（ADR-0007 / ADR-0009）。

## 9. 可替换性与实现细节不泄漏

上层只看到 `Interpreter` / `TensorDesc` / `Bytes`；看不到 `TfLiteModelRaw` 等裸句柄、模型路径、量化格式、引擎版本。换 ONNX / MediaPipe 后端只需组合根换适配器，`pose::detect` 不变。

## 10. 测试策略

| 层次 | 内容 |
|---|---|
| 黑盒（12） | `from_bytes → set_input → invoke → output_raw/output_desc → close` 全链路；重复 close；越界 `TensorIndex`；缓冲长度不符；fp16/量化快照；错误映射；状态机经只读访问器 `state()` 观测 |
| 白盒（9） | status code → `TfLiteError` 映射；`NullHandle`；`ensure_open` 守卫；dtype 编码表；版本断言；**由黑盒迁入的 `_mb_tfl_resize_input` / `_mb_tfl_allocate_tensors` 直调**（shim 私有化后黑盒不可再调用） |
| R2 目标 | 224×224 分类模型与 Python `tflite-runtime` 逐元素误差 < 1e-4（真实库对接后） |
| 平台 | 桌面 x86-64 先验证；上板测 armv7/arm64 与帧率预算 |
| 门禁 | `moon clean` → `moon check --deny-warn` → `moon build` → `moon test` → `moon fmt --check`（R2 冻结前 P0 实跑，全部 exit 0） |

## 11. 验收标准

1. 分类模型跑通且数值对齐（R2 真实库）；2. 重复 close / 空句柄不崩溃（✅ stub 下已验证）；
3. 所有错误经 `TfLiteError` 传播（✅）；4. `--deny-warn` 转绿（✅ 冻结前 P0 实跑 0 error / 0 warning）。

## 12. 未解决问题 / 待验证假设

- Q10：C API 是否覆盖目标模型全部算子（当前只用 CPU，不用 delegate）。
- Q4：模型商用条款；`.so` 随包分发许可。
- E2：`#borrow` 默认语义迁移；E3：Android native 产物链路。

## 13. 当前状态与 TODO

`tflite_ffi.mbt` 含 4 个 `#external` 句柄、**17 个包私有 `extern "C"` shim 声明**（2 个绑定带
`_` 前缀，见 API.md）、值类型与错误模型；`interpreter.mbt` 实现 6 个公开方法 + 3 个只读访问器，
全部为真实实现（**无 `declare`、无 `TODO(实现轮)`、无 `0068`**），`stub/mb_tfl_stub.c` 提供
桌面确定性 C 实现（`native-stub`）。剩余 TODO 全部属于 R2：真实 `libtensorflowlite_c` 对接、
数值对齐 <1e-4、上板验证。

## References

`../docs/adr/ADR-0004`、`ADR-0007`、`ADR-0008` · `https://tensorflow.org/guide/versions` · `https://docs.moonbitlang.com/en/latest/language/ffi.html`
