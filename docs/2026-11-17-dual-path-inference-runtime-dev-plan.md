# tflite_ffi 双路径推理运行时开发文档

> 建立：2026-11-17 ｜ 状态：待开发 ｜ 适用仓库：本仓库（独立自包含）
> 配套文档：[2026-11-17-test-system-design.md](2026-11-17-test-system-design.md)（验收测试 ID `T-W*-*` 出自该文档）
> 本文所有「现状」结论均为 2026-11-17 对本仓库**受版本控制文件**的实测核对，非转述历史文档；本机仓库外的本地构建产物与真实库不纳入事实口径。
> 五门禁 2026-11-17 实跑（开发前基线）：`moon check --deny-warn` 退出 0；`moon build` 退出 0（native CLI 产出）；`moon test` **49/49 通过**（另有 2 条 `#skip` 的 `golden real` 用例不计入通过）；`moon fmt --check` 退出 0；`moon info` 后 `git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti` 退出 0（双快照零漂移）。
>
> 说明：本轮 P1 线索包含仓库外申报材料；其提交数、真实库本地闭环与「后续」口径一律按 P4 实测/目录实存重核，本文只以「仓库外申报口径」泛称记录差异，不假定该材料在本仓库可访问、不回写。
>
> **裁决落地记录（2026-11-17，用户采纳推荐 A）**：W5-A 已新增 `tools/real-golden.sh` + 空哈希登记（缺库/缺工具显式 SKIPPED/78，哈希未登记硬失败，默认联跑 `golden real*`）；现有 `native/mb_tfl_real.c` 已含 POSIX `dlopen/dlsym` 与 Windows `LoadLibraryW` 双路径，本轮未改 ABI。W6-A 已新增 `docs/LICENSE-INDEX.md` 并修正 CI Gate5 失效文案；真实库/模型仍零入库。本机无登记真实库，`golden real` 2 条维持 SKIPPED，不声称通过。

## 0. 现状基线（实测核对，开发前必读）

能力点清单（P1 基准，仓库自足文档 + 公开 API 面核对后确立）：

- F1 `Interpreter` 生命周期：`from_bytes` / `close` / 只读访问器（`state`/`input_count`/`output_count`）
- F2 张量 API：`set_input` / `invoke` / `output_raw` / `output_desc`；dtype 与量化描述
- F3 动态形状：`resize_input` / `allocate_tensors`（R4 加法性公开 API）
- F4 stub/real/auto 双路径：17 个包私有 C shim、进程级一次性解析与粘性路由、环境变量契约
- F5 失败分类与诊断：`backend_name()` / `backend_info()`、F0–F3 加载状态、auto 回退与 real 强制不回退
- F6 `TfLiteError` 13 构造与 C 状态码映射；零 panic 契约
- F7 CLI `tflite-cli`：7 个选项、记录行输出、退出码 0/1/2
- F8 零入库证据链：自产 STF1/TFL3 微型模型生成器、SHA-256 登记、冻结数值容差
- F9 许可/平台边界：真实 `.so`/模型不入库、`.local/` 本地构建产物不入版本控制；POSIX/Android/Q4 残余

非目标清单：delegate/GPU/Extension API、MediaPipe Tasks C API、ONNX、模型下载与预处理、第二推理引擎 trait（本包不暴露 trait）；真实库与模型二进制入库；把 stub 数值当作 real 数值报告。

### B# 基线事实表

| # | 事实（已实现/缺口/漂移，含细节） | 证据位置（文件+函数/行段） |
|---|---|---|
| B1 | 已实现：公开面 = 2 个顶层 fn（`backend_name`/`backend_info`）、`TfLiteError` 13 变体 + `to_repr`、5 个 `pub(all)` 值类型、1 个抽象 `Interpreter`（字段包私有）、4 个 `#external` 类型、2 个类型别名、11 个 `Interpreter` 方法 | `pkg.generated.mbti` L9–95 |
| B2 | 漂移（API 索引）：README §3 索引漏 4 个 `#external` 类型、2 个类型别名与 `to_repr`；自称「自动抽取 pub 声明行」但口径不完整 | README.md L37–59 ↔ `pkg.generated.mbti` L80–95 |
| B3 | 已实测：错误变体逐个数清为 **13**；显式簿记 **13/13**（每变体至少一条直接变体名断言），无死变体 | `tflite_ffi.mbt` L101–115；`pkg.generated.mbti` L15–29；各 `*_test.mbt`/`*_wbtest.mbt` 变体名 Grep |
| B4 | 已实测：测试 **49/49**，文件分布 `backend_wbtest` 8 + `q10_coverage_test` 6 + `real_golden_test` 5（其中 2 条 `#skip`）+ `resize_allocate_test` 8 + `tflite_ffi_test` 12 + `tflite_ffi_wbtest` 10；默认执行 = 49，`golden real` 2 条显式 SKIPPED 不计通过 | `moon test` 实跑；`grep -c '^test "'` 逐文件重数；`#skip` 位于 L830/L856 |
| B5 | 已实测：五门禁全绿，双快照 `moon info` 前后无 diff；CLI 冒烟随测试执行 | 2026-11-17 五门禁实跑记录 |
| B6 | 漂移（计数）：`git rev-list --count HEAD` = **18**，仓库外申报口径写 17；差异仅登记不回写 | 2026-11-17 `git rev-list --count HEAD` |
| B7 | 已实现：34 个受版本控制文件；零第三方依赖（3 个 native C 源文件自研）；`.local/` 含本地构建源码/产物但未被 git 跟踪（`git ls-files .local` 为空）；零模型/真实库入库 | `git ls-files`；`moon.mod`；目录实测 |
| B8 | 已实现：17 个包私有 `mb_tfl_*` shim 声明齐全，含 `#borrow` 标注（model_bytes/dims/src/dst）；符号不进 `moon info` 快照；另有 5 个包白盒私有钩子 | `tflite_ffi.mbt` L145–249；`backend.mbt` L18–47；`native/mb_tfl_dispatch.c` |
| B9 | 已实现：stub/real/auto 三模式、进程级一次性解析与粘性路由；env `MB_TFLITE_BACKEND`/`MB_TFLITE_LIB_PATH`；F1 路径探测 / F2 映像无效 / F3 加载失败；auto 回退 stub、real 强制失败显式报错 | `backend.mbt` L1–82；`backend_wbtest.mbt` 8 例 |
| B10 | 已实现：`from_bytes` 版本断言 + 三句柄获取 + `errdefer` 逆序释放 + 首次 `AllocateTensors`（real 必需）；options 创建后立即释放；`close` 逆序释放且重复调用 `AlreadyClosed`；状态机 Ready/Invoking/Closed + `errdefer` 复位 | `interpreter.mbt` L196–267、L274–283、L400–411 |
| B11 | 已实现（F3）：`resize_input` 校验 index 与 rank 1..8、每维 ≥1；`allocate_tensors` 幂等；stub 未 allocate 返回状态码 2（`CopyFromBufferFailed(2)`/`InvokeFailed(2)`），real 折叠为 1——双路径差异已在源码注释登记而非静默抹平 | `interpreter.mbt` L299–350；`resize_allocate_test.mbt` 8 例；`tflite_ffi.mbt` L208–213 |
| B12 | 已实现（F2）：`set_input` 按 `desc.byte_size` 校验长度；`output_raw` 按元数据分配缓冲并复制；`output_desc` 返回形状/dtype/字节数/量化/名称快照（UTF-8 非法字节以 U+FFFD 替换）；包内不暴露任何 trait 接口 | `interpreter.mbt` L62–117、L122–157、L354–424 |
| B13 | 已实现（F8）：测试内嵌 TFL3/STF1 确定性生成器；自实现 SHA-256 校验重建字节与登记值一致；数值容差冻结 `|got-want| ≤ 1e-6 + 1e-5×|want|`（NaN bit 相等、±0 等价、Inf bit 相等）；`golden real` 2 条以 `#skip` 入库且首行断言 `backend_name()=="real"` | `real_golden_test.mbt` L1–18、L21–142、L655–696、L764–879 |
| B14 | 漂移（fixture 实存 ≠ 被消费）：`tests/fixtures/golden/ASSETS.md`、`micro/ASSETS.md`、`micro_mul_f32.numeric.norm.txt` 均实存且内容互相引用，但全仓测试代码**零处读取**该文件（仅在注释中被提及）；黄金值实际来自测试内嵌常量，双通道一致性未被门禁化 | 目录实测 + 全仓 Grep `numeric.norm.txt` 仅命中注释/登记文档；`real_golden_test.mbt` L699、L762 |
| B15 | 已实现（F7）：CLI 选项 `--model/--backend/--lib/--threads/--info/--input/--out-raw`；记录行 `MODEL|/INPUTS|/OUTPUTS|/OUTDESC|/INVOKE|/OUTDATA|/DONE|`；退出码 0/1/2；env 写入先于任何库调用 | `cmd/main/main.mbt` L321 起；README.md L65–68 |
| B16 | 漂移（自包含/引用实存性）：源码/测试/CI 注释与文案共约 20 处引用本仓库内不存在的文档路径（API/决策/设计/许可审计/版本锁/Q10 矩阵/stub README），其中 CI Gate5 失败消息仍指向旧 API 文档；源码注释 2 处引用兄弟模块的类型名 | `.mbt` 全仓 Grep；`tests/fixtures/micro/ASSETS.md` L3 亦引用仓库外路径；`.github/workflows/ci.yml` L124 |
| B17 | 口径待调整：README L4 称「唯一说明文档」；本轮 docs 交付后须改为「唯一入口文档」并加索引 | README.md L4 |
| B18 | 缺口（「后续」逐项核对）：与外部 Python 运行时的 <1e-4 数值对齐、Linux CI / Android 真机实跑、Q10 真实侧算子验证、linux/android 真实库获取、Q4 法务终裁均未在仓库内留下可复验闭环；仓库外申报口径称 win-x64 真实库本地闭环 `golden real` 2/2，但真实库与构建产物不在版本控制内，本轮**未复验**，仅作线索 | README.md L71–75；目录实测；仓库外申报口径（仅作线索） |
| B19 | 诊断 fail-open 风险：`backend_name()` 把 real 强制失败（`resolved=none`）映射为字面量 `"stub"`，调用方仅凭该函数可能误判后端可用；真相只在 `backend_info()` 的 `resolved`/`load_status`，且该函数返回文本需自行解析 | `backend.mbt` L49–63；`backend_wbtest.mbt` 相关断言 |
| B20 | 健壮性缺口（元数据无界）：`tensor_desc_of` 直接用 C shim 返回的 `dims[0]` 作为 `Array::makei` 的 rank、`misc[1]` 作为 `FixedArray::make` 的 byte_size，无 1..8 / 上限校验；畸形或恶意模型可能触发大分配或越界；`dtype_of_code` 对未知 dtype 已 `UnsupportedDtype` | `interpreter.mbt` L122–157、L46–55 |
| B21 | 观察（非缺陷）：stub 侧 `NOT_ALLOCATED=2` 与 real 侧 TFLiteStatus 非 0 折叠为 1，属已登记的双路径语义差异；`real_golden` 用例首行强制 `backend_name()=="real"`，未满足条件即 fail，不静默跳过 | `real_golden_test.mbt` L828–836；`tflite_ffi.mbt` L208–213 |
| B22 | 计数纪律：`#skip` 2 条（L830/L856）与 README 口径一致；默认 `Total tests:49` 不含它们，`--include-skipped` 联跑需要真实库且本轮未执行（本机默认 stub），不得把 2/2 历史口径写成当前通过 | `real_golden_test.mbt`；README.md L4；`moon test` 实跑 |
| B23 | 许可边界实测：受版本控制文件零第三方二进制；仓库外申报口径所述真实库哈希与版本未在本仓库复验，不得作为仓库内事实引用 | `git ls-files`；`moon.mod`；仓库外申报口径（仅作线索） |

F# → B# 覆盖：F1→B1/B10；F2→B12；F3→B11；F4→B8/B9；F5→B9/B19；F6→B3；F7→B15；F8→B13/B14/B22；F9→B7/B18/B23。

**对历史口径的修正**（以 2026-11-17 实测为准）：

1. 提交数：仓库外申报口径 17 → 实测 **18**（B6；不回写仓库外材料）。
2. 测试 **49/49**、2 条 `#skip`、错误变体 **13**、17 shim、双快照无漂移均实测成立（B3/B4/B5/B8）。
3. README API 索引不完整：漏外部类型、别名与 `to_repr`（B2）。
4. 登记文件 `micro_mul_f32.numeric.norm.txt` 实存但零测试消费：此前「两文件是测试断言目标」的表述不成立（B14），须设清理/门禁工作包。
5. 真实库本地闭环 `golden real 2/2` 属仓库外事实，本轮未复验（B18/B23）；不得据此声称当前仓库已跑通 real。
6. 新登记两处缺口：诊断 fail-open（B19）与 C 元数据无界（B20）。
7. 源码/CI 仍引用大量不存在的历史文档路径与兄弟模块符号（B16）。

## 1. 硬约束（每个工作包都必须满足）

1. API 冻结：`pkg.generated.mbti`（含 `cmd/main` 快照）为冻结基线，只允许纯加法；禁止给 5 个 `pub(all)` 值类型加字段；禁止新增错误变体（`TfLiteError` 13 变体冻结，破坏性需求走 ADR+用户裁决+CHANGELOG+主版本四件例外）；解析/元数据失败复用 `NullHandle`/`UnsupportedDtype`/`BufferSizeMismatch` 等既有变体；语义变更走新函数新类型防火墙（W4/W5）。
2. 加法三件套：快照随源码同提交且 diff 纯加法 + `docs/CHANGELOG.md` 登记 + CI 快照门禁绿。
3. 依赖不动：零第三方依赖；工具链按 CI 锁定；17 个 shim 的符号/签名/`#borrow` 约定与 `-1000` 类 C 状态码语义冻结；真实库只能通过同 ABI 动态加载注入，不得改公开签名。
4. 许可红线：真实 `.so`/`.dll`、模型与 `.local/` 构建产物永不入库；真实差分只允许「仓库外本地路径 + SHA-256 登记 + 显式 SKIPPED」；Q4 法务残余未裁决前不随包分发第三方声明之外的二进制或模型。
5. 五门禁全绿才可合入；`#skip`/SKIPPED/退出码 78 不得写成通过；`golden real` 默认 SKIPPED，历史 2/2 不算当前通过。fail-closed 修复（W3：异常元数据现在拒绝）属行为增强而非契约破坏（变体集合与签名不变），须 CHANGELOG 显式登记 + 回归确认仅受影响样本变化。
6. 边界不变量：不做 delegate/GPU/Extension API、不绑其它推理引擎、不预处理、不下载模型、不暴露 trait；stub 与 real 数值期望显式拆分，容差冻结不放宽。
7. 文档自包含：本文、配套文档、代码注释、CLI 帮助文本、C/CI/脚本不得引用工作区路径或兄弟模块符号（B16 为现存违例，W1 清理）；仓库外申报口径只用泛称，不写路径、不回写。

## 2. 业界对标摘要（P2 结论，证据三级标注）

**渠道与限定**：2026-11-17 经公开 web 渠道（crates.io/docs.rs/GitHub 仓库页、公开生态文章）调研；mooncakes 站内搜索此前实测 422/SPA 无法穷举，本轮不冒充已穷举。「未见同类」限定为：**MoonBit 语言 + 「稳定 C ABI + stub/real 双路径 + 可离线 golden 验证 + 13 类错误语义」组合语义 + 2026-11-17 时点 + 上述公开渠道**。

| 能力（F#） | 本模块（B# 实测） | tflite-c-rs（Rust） | moonfire-tflite（Rust） | Python `tflite-runtime` | C++ 直接用 `c_api.h` | 同生态 ONNX 绑定（仓库外申报口径提及，未引入） |
|---|---|---|---|---|---|---|
| F1 生命周期/RAII | ✓ 抽象 `Interpreter` + 单点 close + errdefer（B10） | ✓ RAII `Drop` 按序释放 | ✓ 手写 wrapper | ◐ Python 对象管理 | ✗ 手工管理 | ◐ 由上游绑定决定 [需联网核实] |
| F2 张量字节 API | ✓ `set_input/output_raw/output_desc` + 13 类错误（B12/B3） | ✓ typed tensor + 自动反量化 | ✓ 基础读写 | ✓ NumPy 数组 | ✓ 原始指针 | ◐ 不同引擎 API [需联网核实] |
| F3 动态形状 | ✓ `resize_input/allocate_tensors` + 双路径差异登记（B11） | ◐ 支持 resize（细节 [需联网核实]） | ◐ 基础支持 | ◐ `resize_tensor_input` | ✓ 原生 | n/a |
| F4 运行时动态加载 | ✓ 17 shim + 进程级粘性路由 + F1/F2/F3（B9） | ✓ `libloading` 运行时加载，无构建期链接 | ✗ 构建期链接/需本地库 | ✓ 包内自带库 | ✗ 链接期决定 | ◐ [需联网核实] |
| F5 可观测后端状态 | ✓ `backend_name`/`backend_info` 文本诊断（B9/B19） | ✗ 无双路径概念 | ✗ | ✗ | ✗ | ✗ |
| F6 错误分类 | ✓ 13 变体 + C 状态码统一映射（B3） | ◐ Rust `Result`/crate Error | ◐ 手写错误 | ◐ Python 异常 | ✗ 裸 status | ◐ [需联网核实] |
| F7 CLI | ✓ 7 选项 + 0/1/2 + 记录行（B15） | ◐ 示例程序 | ✗ | ✗ | ◐ 自行编写 | ◐ [需联网核实] |
| F8 离线可验证 golden | ✓ stub 后端 + 自产模型 + 冻结容差 +显式 SKIPPED（B13/B22） | ✗ 需真实库 | ✗ 需真实库 | ✗ 需真实库 | ✗ 需真实库 | ✗ |
| F9 许可/库入库红线 | ✓ 真实库/模型零入库（B7/B23） | ✓ 库由用户提供 | ◐ 需本地构建 | ◐ 包自带二进制 | ✗ 自行决定 | ◐ [需联网核实] |
| Delegate / GPU | ✗ 非目标 | ✓ `ExternalDelegate`（GPU/NPU/VX） | ◐ EdgeTPU | ◐ 部分 delegate | ✓ 全量 c_api | ◐ 多执行提供者 [需联网核实] |

- 证据等级：`tflite-c-rs` 的运行时 `dlopen`、RAII、无 build.rs、external delegate 支持与线程约束 [仅据本轮 crates.io/docs.rs 包页核验]（版本/star/下载数为易变事实 [需联网核实]）；`moonfire-tflite` 的 C API + EdgeTPU 包装与 Apache-2.0 [仅据本轮 GitHub 仓库页核验]；Python `tflite-runtime` 与 C++ `c_api.h` 基础语义 [已知常识]（平台支持矩阵 [需联网核实]）；同生态 ONNX 绑定仅见仓库外申报口径提及，未核验 [需联网核实]。本模块全部列来自 2026-11-17 源码实测 [仅据本项目文档]。
- 最接近 1–3 名与重叠度：**tflite-c-rs**（重叠最高：运行时加载 + RAII + 稳定 C API；缺 stub 双路径与诊断/CLI）；**moonfire-tflite**（C API 简洁包装 + Apache-2.0，偏真实库构建）；**Python `tflite-runtime`**（生态最常用，但不可离线 stub 验证）。
- 差异化判断：本模块是「**可离线开发的 FFI 绑定**」：真实库缺席时仍以 stub 跑完整生命周期与数值黄金，真实库在场时以同 ABI 切换；`backend_info()` 让加载失败可分类而非进程崩溃。组合语义（MoonBit + native + 双路径 + 诊断文本 + 零入库）在调研渠道内未见同类。
- 缺失能力清单：已声明非目标 = delegate/GPU/其它引擎/预处理/模型下载；真缺口 = 登记文件未被消费（B14）、诊断 fail-open（B19）、C 元数据无界（B20）、平台/法务残余（B18）。

## 3. 边界裁决（P3 结论）

**本质职责（一句话）**：把 TFLite 稳定 C ABI 的「模型字节 → 张量字节」生命周期封装成**可离线验证、失败可分类的中性 MoonBit 值契约**——只回答「能不能推理、输出是什么、后端为何失败」，永不回答「怎么训练、怎么前处理、用哪个 delegate」。

**边界判据**：是否限于 `c_api.h` 稳定 ABI 子集 + 字节进出 + 句柄生命周期 + 失败分类；副作用是否只在进程内加载/释放库与张量。满足者界内；需要 delegate/扩展 API/其它引擎/模型分发者界外。

| 灰区 | 判据结论 | 裁决 | 落点（W#） |
|---|---|---|---|
| G1 stub 后端是否「真推理」 | 界内但仅是离线契约验证源 | 冻结归属声明「stub 数值 ≠ 真实模型数值」；双路径期望拆分；golden 门禁分别运行 | W2、W5 |
| G2 `backend_name()` 把 real 强制失败映射为 `"stub"` | 界内诊断语义、存在误判风险 | 旧函数签名/返回集合冻结；以新函数暴露 `resolved`（含 `none`）防火墙；旧 golden 不回写 | W4 |
| G3 动态形状 stub(2) / real(1) 状态差异 | 界内双路径事实，不能抹平 | 冻结差异登记；golden 分别断言；新增实现只在各自路径内 | W2 |
| G4 真实库动态加载与设备验证 | 界内实现、界外样本/二进制 | 17 shim ABI 冻结；本地路径 + SHA-256 + 显式 SKIPPED；须裁决大工程 | W5（裁决 A 已落地） |
| G5 模型许可/使用范围（Q4） | 界外于代码，但阻塞分发 | 代码层零模型入库；法务三选项交用户裁决，未裁决前不升级口径 | W6（裁决 A 已落地） |
| G6 CLI 与记录行 | 界内薄壳 | 冻结 0/1/2 与记录行格式；新增选项走加法 | W2 |
| G7 源码/CI 引用历史文档与兄弟模块 | 界内（自包含违约，非能力） | 纯文档修复；仓库外申报口径只保留泛称 | W1 |

## 4. 工作包总览

| 包 | 名称 | 优先级 | 规模(S/M/L/XL) | API 影响 | 对应缺口(B#) |
|---|---|---|---|---|---|
| W1 | 漂移清理与自包含 | P0 | S | 无（文档/注释/CI/脚本） | B2、B6、B14、B16、B17、B23 |
| W2 | 双路径契约 golden 与诊断门禁 | P1 | M | 无（测试/脚本层） | B9–B13、B15、B21、B22 |
| W3 | C 元数据 fail-closed 加固 | P1 | S | 无（复用既有变体） | B20 |
| W4 | `backend_resolved()` 诊断防火墙 | P2 | S | 加法：`pub fn backend_resolved() -> String` | B19 |
| W5 | 真实库跨平台与设备轮（A 已落地 runner，真机未实测） | P2 | XL | 零 pub 变化；仓库自包含脚本层 | B18、B21、G1/G4 |
| W6 | Q4 许可与分发终裁（A 已落地） | P2 | M | 无（文档/脚本层） | B18、B23、G5 |

## 5. 工作包详细设计

### W1 漂移清理与自包含（P0/S）

**目标**：消除 B2/B14/B16/B17 漂移；B6 提交数与 B23 仓库外库口径仅登记。
**非目标**：不改任何 `.mbt`/`.c` 逻辑；不恢复已搬迁的历史文档；不改 shim ABI 与错误变体。
**新增 API**：无。
**实现要点**：
- 全仓约 20 处失效文档路径引用（源码/测试/CI/C 注释/登记文件）统一改为「README.md §1/§2/§3 + 本仓库 docs 索引」；源码 2 处兄弟模块类型名改为自足表述（「后端抽象由组合根在包外承担」）；扫 `.mbt/.md/.yml/.c/.h/.ps1` 全部引用实存性。
- README §3 索引补 4 个 `#external` 类型、2 个别名与 `to_repr`；L4「唯一说明文档」改为「唯一入口文档」并加 docs 索引；L35「两文件是测试断言目标」按 B14 改为「登记文件；当前黄金断言取测试内嵌常量，门禁化见 W2」。
- 新建 `docs/CHANGELOG.md` 登记 W1（新增 pub=无 / diff 空 / 增量 0），注明仓库外申报口径不回写。
**验收**：T-W1-1 引用实存性扫描零失效；T-W1-2 README 索引 ↔ mbti 逐条一致；T-W1-3 五门禁绿 + 双快照 diff 空；T-W1-4 CHANGELOG 建立并登记；T-W1-5 登记文件与内嵌黄金双通道比对门禁建立（或显式标注为纯登记资产）。

### W2 双路径契约 golden 与诊断门禁（P1/M）

**目标**：把 49 条点状断言升级为可回归契约：stub/real 状态机 golden、backend_info 键序与 F0–F3 分类、13 变体簿记、CLI 记录行黄金、`golden real` SKIPPED 纪律（B9–B15/B21/B22）。
**非目标**：不改 pub API；不把真实库引入 CI；不放宽冻结容差。
**新增 API**：无。
**实现要点**：
- `tests/golden/` 自产文本：三模式 × F0/F1/F2/F3 × `resolved=stub|real|none` 的 `backend_info()` 键序快照；`from_bytes → set_input → invoke → output_raw → close` 状态序列与错误分类；resize/allocate 在两路径的状态码差异（stub 2 / real 1）分别成 golden。
- 性质：同一模型字节双次推理输出逐字节相等；`close` 后任一方法恒 `AlreadyClosed`；`backend_name()` 与 `backend_info().resolved` 的一致性矩阵（含 W4 前的 `none→"stub"` 已知映射）。
- CLI：七选项组合、记录行逐字节、0/1/2 退出码黄金；错误场景不落盘。
- 错误簿记门禁化：13/13 变体与测试代码双向核对；`golden real` 保持 `#skip`，默认计数不含；`--include-skipped` 需本机真实库，否则显式 SKIPPED。
**验收**：T-W2-1 golden 入库且被测试真实读取；T-W2-2 状态机/双路径差异性质全绿；T-W2-3 13/13 错误簿记门禁化；T-W2-4 CLI 记录行与退出码逐字节回归；T-W2-5 旧 49 用例零改动全绿（防火墙）；T-W2-6 `golden real` SKIPPED 纪律断言。

### W3 C 元数据 fail-closed 加固（P1/S）

**目标**：关闭 B20——C shim 元数据未按契约边界校验。
**非目标**：不新增错误变体；不改合法模型的任何输出；不改 17 shim ABI；不自动裁剪/修复畸形模型。
**新增 API**：无（mbti diff 为空）。
**实现要点**：`tensor_desc_of` 在调用 `Array::makei(rank,…)` 前校验 `1 ≤ rank ≤ 8`，否则 `NullHandle("tensor[i] rank …")`；对 `byte_size` 校验 `0 ≤ byte_size ≤ 268435456`（256 MiB），否则 `BufferSizeMismatch(expected=cap, actual=byte_size)`；`name_buf` 读取长度同样夹到 0..64；`dtype_of_code` 既有 `UnsupportedDtype` 不动。按 fail-closed 例外登记 CHANGELOG；回归确认仅畸形元数据样本改变行为，原 49 用例零改动全绿。
**验收**：T-W3-1 越界 rank → `NullHandle`，无 panic；T-W3-2 超大/负 byte_size → `BufferSizeMismatch`，无大分配；T-W3-3 合法模型输出逐字节不变、旧 49 用例零改动；T-W3-4 截断/变异模型字节扫描无崩溃。

### W4 `backend_resolved()` 诊断防火墙（P2/S）

**目标**：关闭 B19——调用方无法从公开二元函数区分 real 强制失败与 stub 活跃。
**非目标**：不改 `backend_name()`/`backend_info()` 语义与返回；不改 C 侧解析逻辑；不引入新错误变体。
**新增 API（mbti 草案，纯加法）**：

```text
pub fn backend_resolved() -> String
```

**实现要点**：返回稳定字面量 `"stub" | "real" | "none"`（对应 `backend_info()` 的 `resolved` 键）；内部复用既有白盒钩子 `backend_name_code()` 的 `0/1/2` 三态，不修改 C 侧；文档明确「旧 `backend_name()` 的二元映射冻结不变，新函数是唯一可判定 none 的公开通道」；快照仅 +1 行，CHANGELOG 登记。
**验收**：T-W4-1 stub/real/none 三态字面量断言；T-W4-2 旧 `backend_name()` 在既有语料上输出不变；T-W4-3 快照 diff 纯加法、错误变体仍 13 个。

### W5 真实库跨平台与设备轮（裁决 A 已落地，P2/XL）

**目标**：在 17 shim ABI 内补齐 Linux/Android 真实库加载与设备实测，并做外部运行时数值对齐（B18、G1/G4）。
**非目标**：不改公开面与错误变体；不入库真实库/模型；不在未裁决前把仓库外历史 2/2 写成当前通过。
**须裁决选项**：
- **A（推荐，2026-11-17 采纳；runner 已落地，M5-1/2 真机验证与 M5-3 仍需用户提供设备与授权）**：分里程碑——M5-1 Linux 主机动态加载 + F1/F2/F3 分类与 `backend_info` 矩阵；M5-2 `golden real` 两条在真实库下联跑（本地路径 + SHA-256 登记 + 退出码/容差报告）；M5-3 Android/NDK 与 Q10 real 算子集合、Python 运行时 <1e-4 对齐；每里程碑独立五门禁 + 止损，失败即回 stub 路线并登记缺口。
- **B（零成本降级）**：维持 stub + 当前 49/49、2 条 `#skip`；README/测试文档保持 Linux/Android/数值对齐「未实现」，不启动设备轮。
- **C（不推荐）**：把真实库或第三方二进制纳入仓库/CI 镜像以求快速闭环——触碰许可红线与零依赖约束，除非用户另行裁决四件例外，否则不执行。
**实现要点（A）**：C 侧只实现既有符号；环境变量契约不变；真实差分报告登记库哈希、模型哈希、日期、内核/工具版本与容差；Q10 real 结果未实测前不得升级口径。
**验收**：T-W5-1（裁决 A）每里程碑五门禁绿 + stub 侧旧用例零改动；T-W5-2（裁决 A）真实与 stub 的错误分类/状态序列矩阵一致；T-W5-3（裁决 A）设备/数值报告含哈希登记与 SKIPPED 项；T-W5-4（裁决 B）README 与测试文档维持未实现声明。

### W6 Q4 许可与分发终裁（裁决 A 已落地，P2/M）

**目标**：对模型使用范围声明、随包分发与第三方声明义务给出可执行结论（B18/B23、G5）。
**非目标**：不在代码层替代法务判断；不把任何真实模型/库入库。
**须裁决选项**：
- **A（推荐，2026-11-17 采纳并落地）**：维持零入库红线，分发只包含自研代码 + 本报告索引；由用户/法务确认目标模型使用范围后决定是否附带外部声明；本仓库文档中相关事实一律标 [需联网核实] 且不写死版本/哈希。
- **B（零成本降级）**：继续以「Q4 残余开放」登记，不启动终裁，禁止任何真实模型随包分发。
- **C（不推荐）**：在终裁前放宽红线引入模型/库二进制——违反硬约束，不执行。
**实现要点（A）**：产出仓库内许可索引（仅陈述自研代码许可与外部规范参考，不复制第三方全文）；`tools/get-tflite.ps1` 继续只产出仓库外登记（SHA256SUMS/PROVENANCE），不落二进制。
**验收**：T-W6-1（裁决 A）分发清单零第三方二进制；T-W6-2（裁决 A）许可索引自包含、无工作区路径；T-W6-3（裁决 B）残余状态文档化且红线不破。

## 6. 里程碑与合入顺序

```text
M0（第1日）   W1 漂移清理与自包含（零风险文档/注释/CI）
M1            W3 C 元数据 fail-closed 加固（安全缺口，行为增强例外）
M2            W2 双路径 golden 与诊断门禁（高价值低成本）
M3            W4 backend_resolved 诊断防火墙（纯加法）
M4（已裁决）  W5 runner 已落地（真机未实测）+ W6 许可索引已落地
```

排序判据：先零风险文档、再安全缺口、再高价值低成本、最后大工程与须裁决项；每包独立提交、独立过五门禁；W5/W6 已于 2026-11-17 裁决采纳 A，runner 与许可索引落地，真机/真实库差分仍按 SKIPPED 单列。

## 7. 簿记与变更管理

- `docs/CHANGELOG.md`：每包登记「日期/工作包/新增 pub 声明/快照 diff 结论/测试增量」。
- README §3 索引随 `moon info` 快照同步（含外部类型/别名/`to_repr`），禁手编 mbti。
- 提交数、真实库版本/哈希、golden real 历史 2/2 只以本仓库实测为准；仓库外申报口径与本仓库不一致时不反向回写。
- 17 shim ABI、13 错误变体、容差公式变更均属破坏性需求，须走四件例外流程；本轮所有 W# 零新增错误变体。
- W3 按 fail-closed 例外登记；W5 各里程碑 `[仍需实测]` 项单独登记，未实测不得升级为结论；W6 裁决结果单独记录。

## 8. 完成定义（DoD，逐包勾选）

- [ ] 新增 API 与 mbti 草案一致（偏差回写本文）；零新增错误变体
- [ ] 快照 diff 纯加法（或空），CHANGELOG 已登记
- [ ] `T-W*-*` 验收全绿；`#skip` 显式标注原因、不计通过
- [ ] 五门禁全绿；CLI 记录行/退出码零意外漂移
- [ ] 防火墙回归：新函数/新包合入后旧 API 在既有语料上输出逐字节不变、旧用例零改动全绿（W1 纯文档包以旧用例零改动全绿为准）
- [ ] 畸形模型/元数据无 panic、无越界、无大分配
- [ ] 零新第三方依赖；零许可不明二进制入库；`.local/` 仍不受版本控制
- [ ] README 能力/非目标/索引同步；本文状态行更新「已交付+日期」
- [ ] 自包含扫描：docs + 代码注释 + C 注释 + 帮助文本 + CI/脚本无工作区路径与兄弟模块符号引用

## 9. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| stub 数值/状态被误当作 real 结论 | 高 | W1 归属声明 + W2 双路径 golden 分列；`golden real` 保持显式 SKIPPED |
| 动态加载真实库引入 ABI 漂移 | 高 | 17 shim 冻结 + 快照门禁 + W5 里程碑止损 |
| 恶意模型元数据触发大分配/越界 | 中 | W3 rank/byte_size/name 长度上界 + 截断变异扫描 |
| `backend_name()` 二元映射造成 fail-open 误判 | 中 | W4 新函数暴露 none；旧函数冻结，golden 记录三态 |
| 真实库/模型许可与分发义务未闭环 | 高 | W6 三选项裁决；未裁决前零入库、只做仓库外登记 |
| 登记文件与内嵌黄金双通道漂移 | 中 | W1 门禁化或显式降级为纯登记资产；W2 黄金由测试真实读取 |
| 仓库外申报口径继续被当作事实 | 中 | §0 集中登记修正；产出文档只用泛称，不写路径、不回写 |
