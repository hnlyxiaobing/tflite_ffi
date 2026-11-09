# tflite_ffi · 公开 API（API.md）

> 与 `pkg.generated.mbti` 快照一致（快照由 `moon check` / `moon build` 自动同步；**未手工编辑快照**，快照审阅由维护流程统一执行）。
> 状态（API 冻结前 P0 整改轮，2026-11-07）：**全部函数为真实实现**（无 `declare` 存根、无 `0068`）；`extern "C"` shim 由 `stub/mb_tfl_stub.c`（`native-stub`，CI 默认后端）提供，`moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check` 全绿。
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
> 以源码与快照为准：冻结前快照恰有 17 个 `mb_tfl_*` 导出。

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
| `mb_tfl_resize_input(interp, index, dims : FixedArray[Int], dims_len) -> StatusCode` | `#borrow(dims)` | 动态尺寸 |
| `mb_tfl_allocate_tensors(interp) -> StatusCode` | — | 分配张量 |
| `mb_tfl_tensor_copy_from(tensor, src : Bytes, size) -> StatusCode` | `#borrow(src)` | 写入输入 |
| `mb_tfl_tensor_copy_to(tensor, dst : FixedArray[Byte], size) -> StatusCode` | `#borrow(dst)` | 读出输出 |
| `mb_tfl_invoke(interp) -> StatusCode` | — | 同步推理 |

> **`_` 前缀已取消（R4，2026-11-09）**：`mb_tfl_resize_input` /
> `mb_tfl_allocate_tensors` 已由 MoonBit 层公开 API
> `Interpreter::{resize_input, allocate_tensors}` 调用，绑定名恢复正名
> （C 符号字符串与签名始终零改动）。历史白盒测试的直调点同步改名。
>
> 另有 4 个**私有内部 ABI** 符号（`tflite_ffi_private_{model,options,interp}_alive`、
> `tflite_ffi_private_tensor_meta`，声明于 `interpreter.mbt`），本就不属于公开面，未做改动。

> **无回调**：推理是同步调用，故不使用 `FuncRef` / `#owned`，规避跨线程问题。

## 值类型 / 错误

`Interpreter`（**抽象类型**：字段全私有，包外不可读字段、不可构造字面量）· `InterpreterState` · `InterpreterOptions` · `TensorDesc` · `TensorDtype`（含 `Int64` 分支）· `Quantization` · `TfLiteError`（`pub(all) suberror`，**13** 个构造）· `TensorIndex` · `StatusCode`。

> 原 `InferenceRuntime`(trait) 已于冻结前 P0 **删除**（决策 2），见下节。

## 冻结前追认记录（API 冻结前 · 加法性追认）

以下三项经核对**源码现状已符合**，仅在本文件中追认（冻结后即为契约）：

| 项 | 现状（源码） | 追认说明 |
|---|---|---|
| `TfLiteError` 为 `pub(all) suberror` | `tflite_ffi.mbt`：`#derive(Debug)` + `pub(all) suberror TfLiteError` | 包外可构造/匹配全部错误构造；13 个构造全部公开 |
| `TfLiteError::NullHandle` 构造器公开 | `pub(all)` 使其随错误类型整体公开（快照含 `NullHandle(String)`） | 测试与包外适配器可匹配 `NullHandle(_)` |
| `TensorDtype::Int64` 分支 | `pub(all) enum TensorDtype` 含 `Int64`；`dtype_of_code(5) => Int64` | 白盒 `wb dtype_of_code maps all supported codes` 覆盖 |

## MoonBit 侧公开 API（全部为真实实现；既有签名冻结，R4 加法性新增 2 条）

| 签名 | 参数与所有权 | 返回 / 错误 | 资源与线程约束 |
|---|---|---|---|
| `Interpreter::from_bytes(model_bytes : Bytes, options : InterpreterOptions) -> Interpreter raise TfLiteError` | `model_bytes` 只读；失败按创建逆序释放 | 包装值 `owns_model=true` / `TfLiteError` | 同一 Interpreter 禁止并发 invoke |
| `Interpreter::close(self) -> Unit raise TfLiteError` | 消耗释放责任 | `Unit` / `AlreadyClosed` | 必须与 invoke 串行；**不会二次释放，重复调用返回明确错误** |
| `Interpreter::resize_input(self, index : TensorIndex, dims : Array[Int32]) -> Unit raise TfLiteError` | `dims` 只读；rank 1..8、每维 ≥1 | `Unit` / `AlreadyClosed`、`InvalidTensorIndex`、`ResizeFailed(code, detail)` | 与 invoke 串行；**resize 后必须再 allocate** |
| `Interpreter::allocate_tensors(self) -> Unit raise TfLiteError` | `self` 只读 | `Unit` / `AlreadyClosed`、`AllocateTensorsFailed(code)` | 与 invoke 串行；未 resize 时幂等重分配 |
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
（`pub(open)`）承担，组合根适配模式不变（`DECISIONS.md` §6）。`Interpreter` 的公开方法零变化。

## stub/real 双路径与后端查询 API（加法性，2026-11-08）

> 双路径机制冻结（`DECISIONS.md` §2）：加法性公开 API **恰两条**，快照 diff 期望恰为
> `// Values` 下 `backend_info` / `backend_name` 两行加法；其余冻结面零变化。
> `interpreter.mbt` / `tflite_ffi.mbt` 零改动；17 个 shim 的 C 符号由
> `native/mb_tfl_dispatch.c` 导出（stub/real 运行时路由，见 DESIGN.md §14）。

### 新增公开函数（2 条）

| 签名 | 语义 |
|---|---|
| `pub fn backend_name() -> String` | `"stub"` \| `"real"` 稳定字面量；首次调用触发一次性解析；不抛错。`"real"` 当且仅当真实库加载成功并粘性路由到 real；其余（stub 活跃、auto 回退、real 强制失败）为 `"stub"` |
| `pub fn backend_info() -> String` | key=value 行文本（LF/UTF-8，不抛错）：`mode`（stub\|real\|auto）、`resolved`（stub\|real\|none）、`lib_path`（UTF-8 路径，空=标准搜索）、`load_status`（ok\|F0\|F1\|F2\|F3；F0=未尝试真实加载）、`reason`（F 失败以 F 类标开头；非法 env 值含 `env_invalid`）、`tfl_version`、`schema_version` |

### env 契约（`DECISIONS.md` §2）

| 变量 | 语义 |
|---|---|
| `MB_TFLITE_BACKEND` | `stub`（默认，确定性）\| `real`（强制真实；F1–F3 失败不回退，`from_bytes` 显式抛 `LibraryNotLoaded(reason)`）\| `auto`（优先 real，失败自动回退 stub，原因入 `backend_info()`）。非法值=视为未设置并记 `env_invalid` |
| `MB_TFLITE_LIB_PATH` | 真实库绝对路径（UTF-8 → `LoadLibraryW`，支持中文路径）；未设置=标准搜索 |

失败分类：F1=路径探测失败（不存在/非常规文件）；F2=映像无效（非 PE/必需导出
符号缺失/`TfLiteSchemaVersion` 不兼容）；F3=加载失败（依赖缺失等
`LoadLibrary` 返回 NULL）。

### 包私有白盒钩子（不进快照，`DECISIONS.md` §2）

| MoonBit 绑定 | C 符号 | 语义 |
|---|---|---|
| `_tfl_backend_reset(mode, path : Bytes, path_len) -> Int32`（`#borrow(path)`） | `tflite_ffi_private_backend_reset` | mode：-1=按 env，0=stub，1=real，2=auto；返回 0=ok，1=活跃句柄拒绝，2=real 强制失败 |
| `_tfl_backend_force_fail(code) -> Int32` | `tflite_ffi_private_backend_force_fail` | 0=清除，1\|2\|3=注入 F1\|F2\|F3（下次解析生效）；返回 0=ok，1=非法码 |
| `_tfl_backend_live_handles() -> Int32` | `tflite_ffi_private_backend_live_handles` | 活跃句柄计数（create/delete 对） |
| `backend_name_code() -> Int32` | `tflite_ffi_private_backend_name_code` | 0=stub 活跃，1=real 活跃，2=real 强制失败 |
| `backend_info_bytes(dst, cap) -> Int32`（`#borrow(dst)`） | `tflite_ffi_private_backend_info_bytes` | 写 info 文本，返回字节数 |

### shim 表修订（内部，无冻结面变化）

17 个 `mb_tfl_*` shim 签名零改动；`stub/mb_tfl_stub.c` 的实现符号改名为
`mb_tfl_stub_impl_*`（确定性语义零改动，「仅内部符号改名」约定），由
`native/mb_tfl_dispatch.c` 路由 stub/real。`mb_tfl_capi_version` 正常态恒返回
shim ABI `0x00010001`（既有断言零改动）；「real 强制且加载失败」态返回负失败
分类哨兵 -1/-2/-3（对应 F1/F2/F3），借既有版本断言让 `from_bytes` 显式抛
`LibraryNotLoaded`——机制修订（2026-11-08 裁决）项，映射详见 DESIGN.md §14
与 `DECISIONS.md` §2。

## R4 加法性公开 API：动态形状（2026-11-09）

> 动机与决策见 `DECISIONS.md` §7。既有 6 个方法 + 3 个只读访问器签名**零变化**；
> 快照 diff 期望恰为 `Interpreter::allocate_tensors` / `Interpreter::resize_input`
> 两行加法。错误类型零变化（复用冻结前已预留的 `ResizeFailed` /
> `AllocateTensorsFailed`）。

### 新增方法（2 条）

| 签名 | 语义 |
|---|---|
| `pub fn Interpreter::resize_input(self, index : TensorIndex, dims : Array[Int32]) -> Unit raise TfLiteError` | 更新第 `index` 个输入的形状（rank 1..8、每维 ≥1）；resize 后全部缓冲失效，必须再 `allocate_tensors`。错误：`AlreadyClosed`、`InvalidTensorIndex`、`ResizeFailed(code, detail)` |
| `pub fn Interpreter::allocate_tensors(self) -> Unit raise TfLiteError` | 分配/重新分配全部张量；未 resize 时等价于按当前形状重分配（幂等）。错误：`AlreadyClosed`、`AllocateTensorsFailed(code)` |

### 双路径语义差异（登记，见 `DESIGN.md` §14.4）

| 语义点 | stub（STF1） | real（TFL3） |
|---|---|---|
| resize 后未 allocate：`set_input` / `invoke` / `output_raw` | 状态码 2 → `CopyFromBufferFailed(2)` / `InvokeFailed(2)` / `CopyToBufferFailed(2)` | TfLiteStatus 非 0 折叠为 1 → 对应 `(1)` |
| rank 变化 | 允许（输出 `-1` 维在 allocate 时镜像 input 0） | 要求与模型签名一致，不匹配 → `ResizeFailed(1, ...)` |
| 负维/零维/rank>8 | MoonBit 层先行校验 → `ResizeFailed(1, detail)`（双路径一致，不 panic） | 同左 |

### API-CHANGELOG 条目文本（根仓库 `API-CHANGELOG.md` 由主控维护，本模块只提供文本）

> 类别 `加法性追认`｜`tflite_ffi`：新增 `Interpreter::resize_input` 与
> `Interpreter::allocate_tensors`（动态形状；既有公开签名零变化；错误模型零变化；
> `pkg.generated.mbti` 快照新增两行，随源码同一提交）。

## 非目标

预处理/后处理、模型下载、模型 zoo、量化决策、GPU/delegate、Extension/opaque API、`foreign_library` 导出。

## 门禁与状态（P0 整改轮实跑）

在 `tflite_ffi/` 依次实跑，全部 exit 0：

| 命令 | 结果 |
|---|---|
| `moon clean` | ✅ exit 0 |
| `moon check --deny-warn` | ✅ exit 0（0 error / 0 warning，无 `0068`、无 `unused_value`） |
| `moon build` | ✅ exit 0（链接 `stub/mb_tfl_stub.c`，无外部库） |
| `moon test` | ✅ exit 0，R4 实跑 **48 tests 全过**（黑盒 + 白盒；含 resize/allocate 8 个错误路径用例与 Q10 6 个算子矩阵用例） |
| `moon fmt --check` | ✅ exit 0 |

真实 `libtensorflowlite_c` 对接与数值对齐（<1e-4）留待**真实库对接阶段**；本库保持项目内 C stub 双路径（`DECISIONS.md` §2），stub 为 CI 默认后端。双路径落地时 34 个测试全过 + 2 个 `golden real` 类 SKIPPED（无真实库，不计通过）；R4（2026-11-09）追加 resize/allocate 8 个与 Q10 6 个用例后为 **48 个全过 + 2 个 `golden real` SKIPPED**。真实库获取结果与证据等级以 `GAPS.md` 为准（未取得时不得写成通过）。
