# DECISIONS.md — tflite_ffi 设计决策记录

> 本文件整合本库的长期设计决策（背景 → 决策 → 理由 → 后果），内容源自开发期的
> 契约与决策记录（属作者本地开发管理记录，不随本仓库发布）；此处为**自足版本**，
> 仓库内其它文档引用决策时一律指向本文件，不再指向任何仓库外文件。
> 各节日期为决策定案日期。许可事实与证据见 `LICENSE-AUDIT-Q4.md`；
> 数值黄金与容差口径见 `tests/fixtures/golden/ASSETS.md` / `tests/fixtures/micro/ASSETS.md`。

---

## 1. 只绑定 `c_api.h` 稳定 ABI（2026-11-06）

**背景**。本库是 LiteRT / TensorFlow Lite 的 MoonBit FFI 封装。上游存在多层 C
接口：`tensorflow/lite/c/c_api.h`（核心 C API）、`c_api_opaque.h` / `common.h` /
`builtin_op_data.h` / `builtin_ops.h`（**Extension APIs**）、`c_api_experimental.h`
与 C++ API。2026-11-06 对 mooncakes.io 的检索显示当时没有 Android/native 的
TFLite 绑定（`mizchi/webnn@0.1.0` 含 LiteRT 解析执行但仅 js 目标，
`moon-ort@0.1.1`(MIT) 是 ONNX 路线），因此决定自建 FFI-JNI 封装。

**决策**。本库**只声明 `c_api.h` 覆盖的能力**（model / options / interpreter /
tensor / invoke 及张量描述），**不声明 Extension / opaque / delegate / experimental
符号**。`preferred_target = "native"`（wasm 目标下 `extern "C"` 报 E4156，无法
表达外部 ABI）。

**理由**。

- `c_api.h` 自述 "useful for shared libraries where having a **stable ABI boundary**
  is important"，且受 TFLite 版本号覆盖——是唯一有官方稳定 ABI 承诺的面。
- Extension APIs 自 2.15 起用独立 `TFLITE_EXTENSION_APIS_VERSION`，官方保留
  不兼容变更权利；`c_api_experimental.h` 与 C++ API 不受任何保证——绑定它们
  等于把 ABI 风险引入本库。
- 证伪两处流传说法（2026-11-06 核对上游头文件）：① `TfLiteInterpreter` **未弃用**，
  是稳定核心 C API，真实弃用是 `TfLiteRegistrationExternal` → `TfLiteOperator`；
  ② 导出宏正确名称是 `TFL_CAPI_EXPORT`。
- 备选方案与否决理由：直接绑 MediaPipe `tasks/c`（有 C ABI 但上游自称 internal、
  曾有 "Breaking API change to internal C API"、头文件含 C++ 语法、无稳定承诺）；
  `mizchi/webnn` 的 LiteRT 路线（仅 js 目标）；`moon-ort` 作首选（不支持
  Windows/GPU，与目标 Android 平台不匹配，仅登记为可替换备选）。

**后果**。

- 正面：外部 ABI 依赖收敛到唯一有官方稳定承诺的面；换后端（ONNX / MediaPipe）
  只需组合根换适配器（见 §6）。
- 负面：第一轮只有 MoveNet 系 17 关键点；`.so` 随包分发 armv7/arm64 两份
  （约 3–5 MB）；C API 对目标模型算子的覆盖、量化模型（f16/int8）输出精度
  仍待真实库实测（见 `DESIGN.md` §12）。
- 平台约束：Windows native 需 MSVC `cl.exe`/`clang-cl.exe`（MinGW 不支持）；
  LLVM 后端不支持 FFI；native 后端无法把 `foreign_library` 导出为可链接 `.so`，
  Android 集成须走「C stub + 宿主 NDK/CMake」。

---

## 2. stub/real 双路径运行时机制（2026-11-08）

**背景**。真实 `libtensorflowlite_c` 的许可/分发口径未闭环（见 §3），且桌面/CI
环境经常没有真实库；但真实库对接与数值对齐又必须可落地、可验证。若把真实库
静态链接进本库，既破坏「21 个既有测试零改动」的确定性基线，又让缺库环境无法
构建。因此需要在同一 shim ABI 下同时具备**确定性 stub 实现**与**真实库动态
加载路径**，且互不污染。

**决策（机制契约）**。

- **切换层**：17 个 `mb_tfl_*` C 符号由 `native/mb_tfl_dispatch.c` 统一导出，
  进程级**一次性解析 + 粘性路由**（Windows `SRWLOCK` / POSIX `pthread_mutex` +
  resolved 标志，语义等价 `InitOnceExecuteOnce`/`pthread_once`，且支持白盒
  显式重解析）：
  - real = 运行时 `LoadLibraryW`/`GetProcAddress`（POSIX：`dlopen`/`dlsym`）
    动态加载 `tensorflowlite_c.dll` / `libtensorflowlite_c.so`；
  - stub = 编译进二进制的确定性实现（`stub/mb_tfl_stub.c`，内部符号改名
    `mb_tfl_stub_impl_*`，确定性语义零改动）。
  - **粘性路由**：句柄同后端创建/释放；白盒 `_tfl_backend_reset` 仅当
    `live_handles()==0` 才允许重解析，否则返回 1（防跨后端句柄混用）。
  - real 路径 `model_create` **包句柄信封**：dispatcher malloc 复制模型字节
    （`TfLiteModelCreate` 不拷贝且要求 model_data 与解释器同寿，MoonBit
    `#borrow` 语义不破），信封随 `model_delete` 释放。
- **默认与切换（D1）**：**库层默认 `stub`**（确定性、既有测试零改动、跨机黄金
  可复现、真实后端 opt-in）；`auto` 模式完整实现并测试；CLI（`cmd/main`）
  `--backend` 默认 `auto`（用户面开箱可用，`--info` 显示实际生效后端）。
  切换能力**不进公开 API（D5）**：走 env + CLI；白盒走 `_tfl_backend_reset`。
- **env 契约**：
  - `MB_TFLITE_BACKEND=stub`（默认）| `real`（强制真实：F1–F3 失败**不回退**，
    `from_bytes` 显式 raise `LibraryNotLoaded(reason)`，供断言真实生效）|
    `auto`（优先 real，F1–F3 自动回退 stub、不崩溃、原因入 `backend_info()`）。
    非法值 = 视为未设置并记 `env_invalid`。
  - `MB_TFLITE_LIB_PATH=<绝对路径>`（UTF-8 → `LoadLibraryW`，支持中文路径；
    未设置 = 标准搜索）。
- **失败分类**：F1=路径探测失败（不存在/非常规文件）；F2=映像无效（非 PE /
  必需导出符号缺失 / `TfLiteSchemaVersion` 不兼容，兼容区间 [1,16]）；F3=加载
  失败（依赖缺失等 `LoadLibrary` 返回 NULL）。`load_status` 域：
  `ok`（真实加载成功）| `F0`（未尝试真实加载，stub 模式/默认）| `F1|F2|F3`。
- **`mb_tfl_capi_version` 哨兵映射**（机制修订，2026-11-08 裁决）：正常态
  （stub 活跃 / real 加载成功 / auto 回退）恒返回 shim ABI 版本
  **`0x00010001`**（既有版本断言零改动；真实库版本校验在解析期走
  `TfLiteSchemaVersion`，不符 = F2）；**「real 强制且加载失败」态**返回负失败
  分类哨兵，借 `interpreter.mbt` 既有版本断言路径使 `from_bytes` 显式抛
  `LibraryNotLoaded`（该 raise 点是冻结文件零改动前提下唯一可达的抬起点）：

  | 哨兵（返回值） | 失败分类 | `from_bytes` 错误 |
  |---|---|---|
  | `-1` | F1 路径探测失败 | `LibraryNotLoaded("mb_tfl_capi_version mismatch: got -1, expected 65537")` |
  | `-2` | F2 映像无效 | `LibraryNotLoaded(... got -2 ...)` |
  | `-3` | F3 加载失败 | `LibraryNotLoaded(... got -3 ...)` |

  分类原因的权威来源是 `backend_info()` 的 `load_status`/`reason`；场景测试
  按**双断言**纪律执行：`LibraryNotLoaded` 抛出 **且** `backend_info()` 含
  F 分类原因。
- **加法性公开 API**：双路径落地时恰两条（D 仲裁「公开面最小化」）：
  `backend_name() -> String`（`"stub"`|`"real"` 稳定字面量，不抛错）与
  `backend_info() -> String`（key=value 行文本：`mode`/`resolved`/`lib_path`/
  `load_status`/`reason`/`tfl_version`/`schema_version`，不抛错）。其余冻结面
  零变化；5 个包私有白盒钩子（`_tfl_backend_reset` / `_tfl_backend_force_fail` /
  `_tfl_backend_live_handles` / `backend_name_code` / `backend_info_bytes`）
  不进 `moon info` 快照。**R4（2026-11-09）再追加两条动态形状 API**——
  `Interpreter::{resize_input, allocate_tensors}`，见 §7。
- **三场景可测（无真实库也全绿）**：①路径不存在 ②损坏映像（测试期在临时目录
  生成垃圾字节/缺导出最小 PE，**不入库**）③加载失败走白盒故障注入
  `force_fail(1|2|3)`。auto 下断言进程存活、`backend_name()=="stub"`、STF1
  可用、`backend_info()` 含分类原因；real 下双断言显式报错。
- **真实库获取链（D2，fail-closed）**：① 本地探测（`MB_TFLITE_LIB_PATH` →
  `.local/tflite/<platform>/` 缓存 → Android SDK → Gradle 缓存）→ ② 官方
  预编译（仅当存在**可验证官方渠道**；无则跳过，**禁止第三方构建/镜像**）→
  ③ 官方源码最小构建（tensorflow 官方 tag 钉版、CMake `tensorflowlite_c` 目标、
  MSVC，限时约 40 分钟，超时/失败→④）→ ④ **fail-closed 缺口登记**（`GAPS.md`
  登记原因与证据 + 接线完备 + 获取脚本保留，stub 为唯一运行路径；「未获取」
  必须显式呈现，**不得记成通过**）。获取脚本 `tools/get-tflite.ps1` 退出码：
  0=就绪 / 2=参数错 / 3=fail-closed 未获取 / 4=哈希或导出符号校验失败。
- **微型模型零入库（D3）**：`micro_mul_f32.{tflite,stf1}` 由
  `tools/gen-micro-model.ps1` 程序化生成到 gitignore 目录（`.local/models/`）
  或临时目录；测试内嵌生成器重建字节并断言 SHA-256 == `ASSETS.md` 登记值。
- **CLI 退出码（D6）**：0=成功 / 1=运行失败（模型解析/推理/real 强制不可用）/
  2=用法错误；后端/回退信息走 `--info` 文本，不用退出码区分。
- **shim ↔ `c_api.h` 映射（real 路径）**：model_create→`TfLiteModelCreate`（包
  信封）、options→`TfLiteInterpreterOptionsCreate/SetNumThreads/Delete`
  （n<1 不设 → interpreter 创建失败，与 stub 同语义）、interpreter→
  `TfLiteInterpreterCreate/Delete`（全内置算子，CPU）、count/tensor→
  Get*TensorCount/Get*Tensor（借用）、resize→`TfLiteInterpreterResizeInputTensor`、
  allocate→`TfLiteInterpreterAllocateTensors`、copy_from/to→
  `TfLiteTensorCopyFromBuffer/CopyToBuffer`、invoke→`TfLiteInterpreterInvoke`。
  私有 ABI `tensor_meta` 映射 `TfLiteTensorName/Dims/Type/ByteSize/
  QuantizationParams`（dtype 码 0=F32 1=F16 2=I32 3=U8 4=I8 5=I64，不支持=255
  → `UnsupportedDtype`；name>63 截断、rank>8 返非 0）。

**理由**。默认 stub 保证确定性与跨机黄金可复现，真实后端 opt-in 化解许可
不确定性（§3）；动态加载 + 内置回退让同一二进制在有/无真实库环境都能构建、
测试、运行；一次性解析 + 粘性路由杜绝跨后端句柄混用；`real` 强制失败不回退
是为了让「真实生效」可被断言（回退会掩盖真实库问题）；哨兵映射是在
「`interpreter.mbt`/`tflite_ffi.mbt` 零改动」约束下让 `from_bytes` 显式报错
可达的唯一实现语义。

**后果**。正面：缺库（最可能结局）下系统以 stub 全绿 + 缺口台账显式留痕，
不出现「假通过」或半对接状态；负面：STF1/TFL3 双格式维护成本（见 §4），
`auto` 下用户可能长期运行在 stub 而不自知——缓解：`--info` / `backend_info()`
可观察。被替代方案：库层默认 real 失败才回退（否决：许可未闭环不得默认启用
真实后端，且跨机黄金不可复现）；公开 `select_backend`（否决：公开面最小化）；
缺库时把 golden real 用例删除或标 pass（否决：SKIPPED 不得写成通过，见 §5）。

---

## 3. 许可红线（2026-11-08）

**背景**。框架 Apache-2.0 ≠ 模型可商用、≠ 预编译 `.so` 可随包分发；模型商用
条款（TF Hub/Kaggle 托管条款、MoveNet/BlazePose 使用范围声明的法律约束力）
当时未闭环（Q4，事实层审计见 `LICENSE-AUDIT-Q4.md`）。需要在不确定下给出
可执行边界。

**决策**。

- **红线**：真实 `libtensorflowlite_c` 任何形态（`.so`/`.dll`/`.dylib`）、真实
  第三方模型（MoveNet 等）**禁入库**（含 fixtures/黄金目录）；自产微型模型
  **零入库**（程序化生成，CC0/Apache-2.0 自标注，见
  `tests/fixtures/micro/ASSETS.md`）；测试期损坏样本只写临时目录。
- **唯一允许形态 = 本地链接 + SHA-256 记录 + fail-closed**：经
  `MB_TFLITE_LIB_PATH` 或 `.local/tflite/<platform>/` 本地链接；获取工具产出
  `PROVENANCE.md`（URL/版本/许可/获取日期/构建方式）与 `SHA256SUMS.txt`；
  仓库只存**文本**（登记）与脚本。获取失败即 fail-closed 缺口登记（§2 D2 链
  ④），stub 为唯一运行路径。
- **分发义务（最终 App 随包 `.so` + `.tflite` 时必须履行）**：附 Apache-2.0
  **许可副本**（§4(a)）+ 保留版权/归属声明（§4(c)）+ **再生产 LICENSE 附录的
  Caffe BSD 声明**（二进制再分发义务，运行时分发最易遗漏）；若改上游源码须
  显著标注修改（§4(b)）；上游无根级 NOTICE（404）→ §4(d) 无触发对象；
  产品命名避免商标性使用 "TensorFlow / LiteRT"（§6 名称不随许可授权）。
  若将来引入 MediaPipe 组件，另须随附其 Lucent utf 整体声明。
- **分发判断**：Q4 闭环前**不得随产物分发任何真实 `.so`/模型**；法务残余
  （使用范围声明的法律约束力、随包分发终裁）须在最终 App 分发前闭环。

**理由**。Apache-2.0 不禁止商用与再分发，所以禁入库不是「许可不允许」，而是
**义务触发点控制 + 来源可追溯 + 不明许可零持有**的工程纪律：入库即构成
"distribute"，随附声明义务立即触发且面扩大；本地链接属无条件 "use" 授予，
不触发分发义务；只登记哈希与来源可审计且可逆；「本地链接 + SHA-256」形态与
既有判例（目标游戏 APK 证据链「仅哈希 + 黄金登记、二进制不入库」）同构。
自产微型模型不引入任何第三方条款，双格式生成器本身即合规凭证。

**后果**。真实 `.so`/模型始终只本地链接不分发（直到法务闭环）；仓库层面
Apache-2.0 §4 义务无触发对象；将来分发时可凭 SHA-256/PROVENANCE 确定义务
对应的确切产物并一次闭环。被替代方案：直接入库预编译 `.so`（否决：义务触发
点失控 + 第三方构建来源不可追溯）；放宽红线（否决：冻结口径不破坏）。

---

## 4. 模型格式双轨：STF1（stub）与 TFL3（real）不可混用（2026-11-08）

**背景**。stub 后端需要确定性、可解析的极小模型格式；real 后端只认真实
TFLite flatbuffer。两者的语义能力不对称。

**决策**。stub 路径只认自研 **STF1** 格式（`micro_mul_f32.stf1`，镜像语义，
格式规范见 `stub/README.md`）；real 路径只认 **TFLite flatbuffer（TFL3）**
（`micro_mul_f32.tflite`）。两格式字节不相交，**互喂 = 解析期显式失败**，
不得静默转换或容错接受。语义差异登记（`DESIGN.md` §14.4）：invoke 前输出
清零仅 stub 保证；状态码 2=NOT_ALLOCATED 仅 stub（real 仅 0/1）；STF1 动态维
（输出 dim `-1` 镜像 input 0）与模型级标量 rescale 仅 stub；`allow_fp16` 在
real 仅作 Float16 门禁（不改写内核行为）；量化参数两侧均仅描述不反量化。
STF1 仅支持标量 scale 逐元素缩放，**无法表达 MUL 权重逐元素语义**——
`micro_mul_f32.stf1` 取 scale=1.0 恒等（格式固有边界，见
`tests/fixtures/micro/ASSETS.md`）。

**理由**。STF1 是 stub 确定性语义的最小载体，刻意不模仿 flatbuffer；明确
「不可混用」把格式差异暴露在解析期而非推理期，杜绝静默错误；测试镜像（同一
算子语义的 STF1 与 TFL3 成对生成）共用测试向量 V1/V2 与冻结容差，参考输出 =
独立解析计算（`real_golden_test.mbt` 内嵌 mini flatbuffer 解析器抽常量校验）。

**后果**。双格式维护成本（生成器 + 镜像语义 + 双份测试向量）；跨后端同模型
数值一致性（stub vs real 容差对比）**不适用**——口径为各后端对各自独立参考值
在冻结容差内一致（数据登记见 `tests/fixtures/golden/ASSETS.md` §2/§3.1）。

---

## 5. 测试 fail-closed：SKIPPED = exit 78，不计通过（2026-11-08）

**背景**。无真实库环境（CI/本机）跑真实后端数值黄金时，「跑不了」极易被写成
「跑过了」。口径纪律要求把不可执行显式呈现为不可执行。

**决策**。

- 无库环境：`real_golden_test.mbt`（用例名前缀 `golden real`，`#skip` 黑盒）
  **自动 SKIPPED、显式标注、不计通过、不计失败**（`#skip` 用例不计入
  `Total tests`，MoonBit 原生机制）；分报脚本/链路以 **exit 78** 报告 SKIPPED，
  **SKIPPED(78) / `#skip` 不得写成通过**。
- 有库环境：`moon test --include-skipped -f "golden real*"` 执行，真实运行
  **首行断言 `backend_name()=="real"`**，不满足即 fail，**绝不静默跳过**；
  场景测试按双断言（`LibraryNotLoaded` 抛出 + `backend_info()` 含 F 分类原因）。
- 任何环境全绿：`moon test -f "backend scenario*"`（三场景测试不依赖真实库）。
- 过滤串纪律：`moon test -f` 是全名 glob（仅 `*`/`?` 通配、无隐式前后缀），
  不带 `*` 的过滤串会选中 0 用例空转假绿——一切文档/脚本过滤串以 `*` 结尾
  （`"golden real*"` / `"golden tflite*"` / `"backend scenario*"`）。

**理由**。「缺库」是预期状态而非缺陷（§2 fail-closed）；把它伪装成通过会
摧毁回归基线的可信度。exit 78 独立于 0（通过）/1（失败），使自动化链路无法
误吸收。被替代方案：缺库时删除用例或标 pass（否决）。

**后果**。任何环境的测试报告都如实反映「真跑/没跑」；`moon test` 常规跑
（golden tflite 类 + 全部非 skip 用例）即回归基准，golden real 类留待真实库
就位后联跑（`GAPS.md` 登记放行条件）。

---

## 6. 后端可替换：门面持有 `PoseBackend`，本库不依赖门面（2026-11-06）

**背景**。上层体感应用的 `pose` 门面模块需要可替换推理后端（TFLite / ONNX /
MediaPipe），且不能形成 `pose ⇄ tflite_ffi` 的循环依赖，也不能泄漏后端实现
细节（TFLite 句柄、模型路径、量化格式、引擎版本）。

**决策**。

- `pose` **拥有** `pub trait PoseBackend`（`open`/`infer`/`close`/`kind`）与
  所有中性值类型；`pose::detect` 通过 trait object 调用后端，不 import 任何
  后端模块。
- **本库不知道门面存在**：`tflite_ffi` 只暴露 `Interpreter` / `TensorDesc` /
  `Bytes` 等，**不 import `pose`**（零跨模块 import），也不持有后端抽象 trait
  （冻结前 P0 已删除本库原 `InferenceRuntime` trait，其唯一消费者是测试替身；
  后端抽象统一由 `pose::PoseBackend` 承担）。
- **组合根**写薄适配器（`struct TfliteAdapter { interp : Interpreter }` +
  `impl PoseBackend for TfliteAdapter`，把 `infer(Bytes) -> Bytes` 映射到
  `set_input/invoke/output_raw`）；换 ONNX / MediaPipe 后端只需换适配器，
  `pose::detect` 不变。

**理由**。彻底消除 `pose → tflite_ffi → pose` 的插件环（双向依赖不可编译）；
`pose` 可用 Mock 后端做纯 MoonBit 单测（无需 `.so`、无需设备）；后端句柄/模型
路径/量化格式/引擎版本全部留在本库，不进上层类型。被替代方案：`pose` 直接
import 本库（否决：循环 + 绑定死）；把 trait 抽成独立第 12 模块（否决：为 4
个方法新建模块，成本高）；配置字符串分发（否决：泄漏实现细节）。

**后果**。组合根多一个适配器文件；trait object 一次间接跳转（对 5–15 fps
体感预算可忽略）。`PoseBackend::infer(Bytes) -> Bytes` 是无类型字节契约，
形状错误靠 `TensorDesc`/`ModelSpec` 元数据在适配器层校验。

---

## 7. R4：动态形状 API 公开（2026-11-09）

**背景**。真实 TFLite 模型常含动态输入（batch / 输入尺寸可变），`c_api.h` 的标准
流程是 `TfLiteInterpreterResizeInputTensor` → `TfLiteInterpreterAllocateTensors`
→ `TfLiteTensorCopyFromBuffer` → `Invoke`。R3 双路径落地时这两个 shim 已在 C 层
实现并路由（stub/real 双路径），但 MoonBit 层没有调用点，绑定名带 `_` 前缀、
只有白盒测试直调——下游无法使用动态形状（只能按模型固定形状），C 层接线等于
死代码。

**决策**。加法性公开两个方法（既有冻结面零变化）：

- `Interpreter::resize_input(self, index : TensorIndex, dims : Array[Int32])
  -> Unit raise TfLiteError`：rank 1..8、每维 ≥1；resize 后全部缓冲失效，必须
  再 `allocate_tensors`；错误 `AlreadyClosed` / `InvalidTensorIndex` /
  `ResizeFailed(code, detail)`。
- `Interpreter::allocate_tensors(self) -> Unit raise TfLiteError`：分配/重新分配；
  未 resize 时等价于按当前形状重新分配（幂等）；错误 `AlreadyClosed` /
  `AllocateTensorsFailed(code)`。

错误类型零变化（`ResizeFailed(Int32, String)` / `AllocateTensorsFailed(Int32)`
在冻结前已预留）；17 个 shim 的 C 符号与签名零变化，仅 MoonBit 绑定去掉历史
`_` 前缀（`mb_tfl_resize_input` / `mb_tfl_allocate_tensors`）。快照 diff 期望
恰为 `Interpreter::resize_input` / `Interpreter::allocate_tensors` 两行加法。

**理由**。动态形状是真实模型（MoveNet 等）的常见需求；不公开则 C 层接线无法被
下游使用。语义校验（rank/负维/零维）放在 MoonBit 层，保证 stub/real 双路径的
畸形输入都走 `TfLiteError` 而非 panic。

**后果**。公开面 +2，需 `moon info` 快照随源码提交 + 根仓库 `API-CHANGELOG.md`
加法性追认条目（该文件由主控维护，本模块只提供条目文本）。双路径语义差异
（stub 允许 rank 变化、状态码 2 仅 stub；real 要求 rank 与模型签名一致、状态码
折叠为 0/1）登记于 `DESIGN.md` §14.4；测试见 `resize_allocate_test.mbt`（8 个
黑盒用例）与白盒 shim 直调用例。

## 附：决策编号对照

开发期契约曾以 D1–D6 编号仲裁分歧，本库文档沿用该编号时含义如下（均已在
上文展开）：D1=默认后端（§2）；D2=真实库获取链与 fail-closed（§2/§3）；
D3=微型模型零入库（§2/§3）；D4=stub 多文件链接形态（实测为准，`moon.pkg`
`native-stub` 列表）；D5=不公开 `select_backend`（§2）；D6=CLI 退出码（§2）。
