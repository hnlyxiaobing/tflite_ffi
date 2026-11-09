# tflite_ffi · 设计契约（DESIGN.md）

> API 冻结前 P0 整改轮 / 2026-11-07 ｜ 状态：**实现完成**（桌面确定性 C stub 双路径，
> stub 为 CI 默认后端）；`moon clean` / `moon check --deny-warn` / `moon build` /
> `moon test`（21 tests）/ `moon fmt --check` 五项门禁全绿。
> 真实 `libtensorflowlite_c` 对接与数值对齐留待真实库对接阶段；**冻结前公开面只做三类变化**：
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
      │  真实库对接阶段起可切换
      ▼
tensorflowlite_c.so / c_api.h
```

本库**不 import `pose`**；`pose` 也不 import 本库（组合根适配模式，见 `DECISIONS.md` §6）。零跨模块 import。

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
> 已删除——唯一消费者是测试替身；后端抽象由 `pose::PoseBackend` 承担（组合根适配不变，见 `DECISIONS.md` §6）。

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
  真实 `libtensorflowlite_c.so` 与 `link.native.cc/cc-flags/cc-link-flags`（由 `moon_abi` 生成）留待真实库对接阶段（接入方式见 `DECISIONS.md` §2）。

## 8. 外部类型 / 句柄 / 回调 / 所有权规则

| 类别 | 声明 | 规则 |
|---|---|---|
| 外部类型 | `#external pub type TfLiteModelRaw` 等 4 个 | C 后端 `void*`；不参与 MoonBit 引用计数；**永不跨模块传递** |
| 外部函数 | `extern "C" fn mb_tfl_* ... = "mb_tfl_*"` 共 **17 个**（**包私有**，冻结前 P0 由 `pub` 收敛；其中 `resize_input` / `allocate_tensors` 的绑定带 `_` 前缀，C 符号不变，见 API.md） | 符号由 `stub/mb_tfl_stub.c` 提供；一对一转发 `c_api.h`；统一 status code；不进 `moon info` 快照 |
| `#borrow` | `mb_tfl_model_create(model_bytes)`、`mb_tfl_resize_input(dims)`、`mb_tfl_tensor_copy_from(src)`、`mb_tfl_tensor_copy_to(dst)` | C 侧只读/复制或填充，不 `decref`；MoonBit 保留所有权 |
| 回调 | **本库无回调** | 推理是同步调用，避免引入 FuncRef 与线程问题 |
| 缓冲 | `FixedArray[Byte]` / `Bytes` + `size` | 必须校验 capacity；不足返回 `BufferSizeMismatch` |

> `#borrow` / `#owned` 是**写在函数声明之前的独立属性行**，不是参数注解；官方明确默认语义正从 `#owned` 迁移到 `#borrow`，因此本库全部显式标注（本库 FFI 标注约定，源于开发期决策记录）。

## 9. 可替换性与实现细节不泄漏

上层只看到 `Interpreter` / `TensorDesc` / `Bytes`；看不到 `TfLiteModelRaw` 等裸句柄、模型路径、量化格式、引擎版本。换 ONNX / MediaPipe 后端只需组合根换适配器，`pose::detect` 不变。

## 10. 测试策略

| 层次 | 内容 |
|---|---|
| 黑盒（12） | `from_bytes → set_input → invoke → output_raw/output_desc → close` 全链路；重复 close；越界 `TensorIndex`；缓冲长度不符；fp16/量化快照；错误映射；状态机经只读访问器 `state()` 观测 |
| 白盒（9） | status code → `TfLiteError` 映射；`NullHandle`；`ensure_open` 守卫；dtype 编码表；版本断言；**由黑盒迁入的 `_mb_tfl_resize_input` / `_mb_tfl_allocate_tensors` 直调**（shim 私有化后黑盒不可再调用） |
| 真实库对接目标 | 224×224 分类模型与 Python `tflite-runtime` 逐元素误差 < 1e-4（真实库对接后） |
| 平台 | 桌面 x86-64 先验证；上板测 armv7/arm64 与帧率预算 |
| 门禁 | `moon clean` → `moon check --deny-warn` → `moon build` → `moon test` → `moon fmt --check`（P0 整改轮实跑，全部 exit 0） |

## 11. 验收标准

1. 分类模型跑通且数值对齐（真实库）；2. 重复 close / 空句柄不崩溃（✅ stub 下已验证）；
3. 所有错误经 `TfLiteError` 传播（✅）；4. `--deny-warn` 转绿（✅ 冻结前 P0 实跑 0 error / 0 warning）。

## 12. 未解决问题 / 待验证假设

- Q10（算子覆盖）：C API 是否覆盖目标模型全部算子（当前只用 CPU，不用 delegate）。
- Q4（模型商用条款）：见 `LICENSE-AUDIT-Q4.md`；`.so` 随包分发许可。
- `#borrow`/`#owned` 默认语义迁移（上游进行中）；Android native 产物链路未实测。

## 13. 当前状态与 TODO

`tflite_ffi.mbt` 含 4 个 `#external` 句柄、**17 个包私有 `extern "C"` shim 声明**（2 个绑定带
`_` 前缀，见 API.md）、值类型与错误模型；`interpreter.mbt` 实现 6 个公开方法 + 3 个只读访问器，
全部为真实实现（**无 `declare`、无 `TODO(实现轮)`、无 `0068`**），`stub/mb_tfl_stub.c` 提供
桌面确定性 C 实现（`native-stub`）。剩余 TODO 全部属于真实库对接阶段：真实
`libtensorflowlite_c` 对接、数值对齐 <1e-4、上板验证。

## 14. stub/real 双路径切换层（2026-11-08）

> 双路径机制（`DECISIONS.md` §2）的实现登记。C 层：`native/mb_tfl_dispatch.c`（17 个
> `mb_tfl_*` shim + 私有 ABI + 白盒钩子的唯一导出点）· `native/mb_tfl_real.c`
> （真实 `tensorflowlite_c` 动态加载器）· `native/mb_tfl_backend.h`（内部头）；
> `stub/mb_tfl_stub.c` 仅内部符号改名（`mb_tfl_stub_impl_*`，确定性语义零改动）。
> MoonBit 层：`backend.mbt`（公开 `backend_name`/`backend_info` + 5 个包私有钩子）。

### 14.1 一次性解析 + 粘性路由

- 进程级**一次性解析**（线程安全：Windows `SRWLOCK` / POSIX `pthread_mutex`
  + resolved 标志；语义等价 `InitOnceExecuteOnce`/`pthread_once`，且支持白盒
  `_tfl_backend_reset` 显式重解析——`InitOnce` 族无重置 API，锁+标志是等价
  实现）。首次 `backend_name()`/`backend_info()`/任一 shim 调用触发解析。
- **粘性路由**：句柄同后端创建/释放；`_tfl_backend_reset` 仅当
  `live_handles()==0` 才允许重解析，否则返回 1（防止跨后端句柄混用）。
- real 路径 `model_create` **包句柄信封**：dispatcher malloc 复制模型字节
  （`TfLiteModelCreate` 不拷贝且要求 model_data 活得与解释器同久，
  MoonBit `#borrow` 语义不破），信封随 `model_delete` 释放；options 信封记录
  `threads_set`（`n<1` 不设 → interpreter 创建失败，与 stub 同语义）。

### 14.2 失败分类与 env 契约

F1=路径探测失败（不存在/非常规文件）；F2=映像无效（非 PE/必需导出符号缺失/
`TfLiteSchemaVersion` 不兼容，兼容区间 [1,16]）；F3=加载失败（依赖缺失等
`LoadLibrary` 返回 NULL）。`load_status` 域：`ok`（真实加载成功）| `F0`
（未尝试真实加载，stub 模式/默认）| `F1|F2|F3`。env：`MB_TFLITE_BACKEND=
stub|real|auto`（默认 stub；非法值=视为未设置并记 `env_invalid`）、
`MB_TFLITE_LIB_PATH`（UTF-8 → `LoadLibraryW`，支持中文路径；未设置=标准搜索）。
real 强制失败**不回退**（resolved=none，shim 全部显式失败）；auto 失败自动
回退 stub 且原因入 `backend_info()`。

### 14.3 `mb_tfl_capi_version` 哨兵映射（机制修订，2026-11-08 裁决）

正常态（stub 活跃 / real 加载成功 / auto 回退）恒返回 shim ABI 版本
**`0x00010001`**（`expected_capi_version` 既有断言零改动；真实库版本校验在
解析期走 `TfLiteSchemaVersion`，不符=F2）。**「real 强制且加载失败」态**返回
负失败分类哨兵，借 `interpreter.mbt` 既有版本断言路径使 `from_bytes` 显式抛
`LibraryNotLoaded(reason)`（该 raise 点是冻结文件零改动前提下唯一可达的
`LibraryNotLoaded` 抬起点）：

| 哨兵（`mb_tfl_capi_version` 返回值） | 失败分类 | `from_bytes` 错误 |
|---|---|---|
| `-1` | F1 路径探测失败 | `LibraryNotLoaded("mb_tfl_capi_version mismatch: got -1, expected 65537")` |
| `-2` | F2 映像无效 | `LibraryNotLoaded(... got -2 ...)` |
| `-3` | F3 加载失败 | `LibraryNotLoaded(... got -3 ...)` |

分类原因的权威来源是 `backend_info()` 的 `load_status`/`reason`（场景测试
按双断言纪律执行：`LibraryNotLoaded` 抛出 + `backend_info()` 含 F 分类原因）。

### 14.4 双路径语义差异登记（冻结，见 `DECISIONS.md` §4）

| 语义点 | stub（STF1） | real（TFLite TFL3） |
|---|---|---|
| 模型格式 | **STF1**（自研格式，见 stub/README.md） | **TFLite flatbuffer（TFL3）**，**不可混用** |
| invoke 前输出清零 | **保证**（allocate 时 calloc 零初始化） | 不保证（取决于内核实现） |
| 状态码 2（NOT_ALLOCATED） | 支持（resize 后未 allocate） | **仅 0/1**（real TfLiteStatus 非 0 一律折叠为 1） |
| STF1 动态维（输出 dim `-1` 镜像 input 0） | 支持 | 不适用（TFL3 用 shape_signature） |
| STF1 rescale（模型级标量 scale） | 支持 | 不适用（MUL 等算子自带权重语义） |
| `allow_fp16` | Float16 读写软实现 + 门禁 | **仅作 Float16 门禁**（不改写内核行为） |
| 量化参数 | 仅描述（不反量化） | 仅描述（`TfLiteTensorQuantizationParams`） |

### 14.5 线程 / 平台

- shim 调用线程安全（解析在锁内，解析后粘性只读）；同一 `Interpreter` 不可
  并发 invoke（既有约束，API.md）。
- Windows 路径：UTF-8 → UTF-16 → `LoadLibraryW`（中文路径）；POSIX 分支
  （`dlopen`/`dlsym`）已实现但**仅据文档**（本轮未在 POSIX 实跑）。

## References

`DECISIONS.md`（设计决策记录）· `https://tensorflow.org/guide/versions` · `https://docs.moonbitlang.com/en/latest/language/ffi.html`
