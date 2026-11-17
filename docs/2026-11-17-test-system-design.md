# tflite_ffi 测试系统设计（第一性原理）

> 建立：2026-11-17 ｜ 状态：设计生效，随开发文档逐包落地 ｜ 适用仓库：本仓库（独立自包含）
> 配套文档：[2026-11-17-dual-path-inference-runtime-dev-plan.md](2026-11-17-dual-path-inference-runtime-dev-plan.md)（`T-W*-*` 验收 ID 一一对应；B# 证据行见该文档 §0）

## 1. 第一性原理：本库的正确性是什么

本库的数学形态：

```text
(model_bytes, options) → Interpreter(state) → (input_bytes → invoke → output_bytes) | TfLiteError(13 类)
                       + 后端解析事实 (mode/resolved/load_status/reason)
```

正确性不可约简为以下断言，每条必须有测试层承载：

| # | 断言 | 含义 | 反例（测试必须抓住） |
|---|---|---|---|
| A1 | 张量寻址忠实 | `set_input` 长度 ↔ `byte_size`、`output_raw` 逐字节来自张量缓冲、`output_desc` 与模型元数据一致；f32/量化值按冻结容差 | 长度错配未拒绝；STF1 恒等输出被误报为 real 乘法结果 |
| A2 | 完整性 fail-closed | 版本断言失败/创建失败/未 allocate/非法 rank/超预算字节数/空句柄必报声明错误；不静默截断、不 panic | C 元数据 rank=-1 导致负长数组；real 强制失败被当作 stub 可用 |
| A3 | 边界纯净 | 只输出原始字节与描述值；不产出预处理/后处理/下游语义；stub 事实不得冒充实推理 | 把 `.local` 本地构建结果写成仓库内已跑通 |
| A4 | 输入安全 | 任意模型字节/尺寸/元数据不越界、内存有界、句柄不泄漏；`.local` 二进制零入库 | 恶意 byte_size 触发 GB 级分配 |
| A5 | 契约稳定 | 13 变体、17 shim ABI、`#borrow` 标注、CLI 记录行与 0/1/2、双快照冻结；变更只加法 | 索引漏外部类型；CLI 失败码变成 0 |
| A6 | 双路径等价（按本模块裁剪） | 无 wasm 要求；等价口径为「同一操作序列在 stub 与 real 上错误分类与状态迁移一致」，数值期望按路径分别登记 | 把 real 的 TFLiteStatus=1 与 stub 的 NOT_ALLOCATED=2 混报 |
| A7 | FFI 所有权与生命周期 | `model/options/interp` 创建释放配对；options 最短生命周期；close 逆序且仅一次；`errdefer` 失败逆序回收 | 创建中途失败遗留句柄；重复 close 二次释放 |
| A8 | 诊断可观测性 | `backend_info()` 键序固定、F0–F3 分类可机读；`backend_name()` 二元映射局限被明确记录 | `resolved=none` 被误读为 stub 可用 |

设计推论：A1/A2 → 性质测试 + 结构化 golden + 截断/变异；A7/A8 → 状态序列断言 + 诊断文本矩阵；A4 → 边界值与元数据上界；A5 → 五门禁、CLI 冒烟与快照 diff。

## 2. 测试分层

```text
L0 单元与程序化 fixture（现有 49 条中的主体：状态机/shim 错误/CLI/后端钩子）
L1 性质与变异（变形律 / 模型字节截断与位翻转 / 元数据边界 / 状态码枚举）
L2 受控黄金差分（自产 STF1/TFL3 生成器 + SHA-256 + 冻结容差；W2 补登记文件门禁）
L3 外部 oracle 差分（真实 TFLite 运行时，仅 W5 裁决后本地可选，显式 SKIPPED）
L4 CLI 场景 E2E（七选项 + 记录行 + 0/1/2；W2 脚本化黄金）
L5 元契约门禁（快照 / 13 变体簿记 / 17 shim ABI / 引用实存性 / SKIPPED 纪律 / 变异自检）
R  真实库本地 runner（仓库外路径 + 哈希登记 + 显式 SKIPPED；golden real 2 条占位）
```

断言×层承载表：

| 断言 | 主承载层 | 辅助层 |
|---|---|---|
| A1 张量寻址忠实 | L0 + L2 | L1（变形律） |
| A2 完整性 fail-closed | L0 + L5 | L1（截断/变异）、L4 |
| A3 边界纯净 | L0 | L5（文案/路径扫描） |
| A4 输入安全 | L1 | L0（元数据边界）、L3 |
| A5 契约稳定 | L5 | L4（记录行逐字节） |
| A6 双路径等价 | L2（分类 golden） | L3（裁决后） |
| A7 所有权/生命周期 | L0 + L1 | L3 |
| A8 诊断可观测 | L0 + L2 | L5 |

## 3. fixture 体系

| 类 | 形态 | 入库 | 许可 | 现状 |
|---|---|---|---|---|
| F-A 程序化构造 | 内嵌 TFL3/STF1 字节生成器、f32 位工具、状态注入 | 是 | 随仓库 | 已实现且被 `golden tflite*` 真实消费（B13） |
| F-B 受控文件 fixture | `tests/fixtures/golden/ASSETS.md`、`micro/ASSETS.md`、`micro_mul_f32.numeric.norm.txt` | 是 | 哈希登记 | 文件实存，但 `.txt` 零代码消费者（B14）；W1/W2 门禁化或降级为纯登记资产 |
| F-C 生成器资产 | `tools/gen-micro-model.ps1`（确定性模型字节） | 是 | 自产 | 已实现；与内嵌生成器逐字节一致性靠 SHA-256 间接保证 |
| F-D 真实库/真实模型 | 仓库外本地路径 | 否（红线） | 需法务确认 | `golden real` 2 条 `#skip`；`.local/` 不受版本控制（B7/B23） |

红线：F-D 永不入库；`micro_mul_f32.numeric.norm.txt` 若继续作为登记资产，必须与内嵌 golden 做双通道一致性断言，否则不得描述为「测试断言目标」；仓库外申报材料不进入本仓库测试路径或文档引用。
builder 能力清单：STF1 头（magic/version/输入数/输出数/scale）、张量元数据（name/dtype/rank/dims/qscale/qzero）、TFL3 表与 vtable 结构、状态码（`0/1/2` 与 TfLiteStatus 非 0）、后端模式（stub/real/auto + F1/F2/F3 故障注入 + 活跃句柄拒绝重解析）、resize 维度（rank 0/1/8/9、负维、极大维）、byte_size（0/合法/超 256 MiB/负）。

## 4. L1 性质与变异

- 变形律 P1 幂等：同模型字节两次 `from_bytes → set_input → invoke → output_raw` 输出逐字节相等；`allocate_tensors` 未 resize 时幂等。
- 变形律 P2 生命周期律：任一 `from_bytes` 失败分支后活跃句柄计数归零；`close` 后任一方法恒 `AlreadyClosed`；重复 `close` 不二次释放。
- 变形律 P3 双路径分类律：同一操作序列在 stub 与 real 上 `TfLiteError` 变体名一致（状态码数值允许差异，如 stub 2 / real 1）；数值期望按路径分别登记，不混报。
- 变形律 P4 诊断律：`backend_info()` 键序恒为 `mode/resolved/lib_path/load_status/reason/tfl_version/schema_version`；`resolved=none ⇒ backend_name()=="stub"`（W4 前已知映射，须在 golden 中显式记录而非隐藏）。
- 变形律 P5 容差律：`|got-want| ≤ 1e-6 + 1e-5×|want|` 为冻结公式；NaN 按 bit 相等、±0 等价、Inf bit 相等；不得因失败临时放宽。
- 变形律 P6 **防火墙律**：任一 W# 合入后旧 API 在既有 49 语料上输出逐字节不变、旧用例零改动全绿；17 shim 符号与 `#borrow` 标注不变。
- 位翻转：模型字节、STF1 scale、TFL3 常量向量单 bit 翻转 → 要么报声明错误变体，要么输出与翻转前不同；**格式依赖口径**：STF1/TFL3 无覆盖全部字节的 checksum，不得断言所有翻转必错。
- 边界值矩阵：rank 0/1/8/9、dims 含 0/负/极大、byte_size 0/合法/超 256 MiB/负、name 长度 0/63/64/65、thread_count 0/1/极大、tensor index -1/0/count-1/count、状态码 0/1/2/未知、F0–F3 与非法 env 值。
- 截断扫描：TFL3/STF1 golden 全前缀 + 表/vtable 结构边界；只允许 `ModelCreateFailed`/`NullHandle`/`UnsupportedDtype`/`BufferSizeMismatch`，无 panic/挂起。
- 变异语料：固定种子随机替换/插入/删除，每轮 ≥1000 变异体；后端模式与故障注入组合全枚举。

## 5. L3 oracle 矩阵 + R runner

| oracle | 差分对象 | 规范化口径 |
|---|---|---|
| 真实 TFLite 运行时（W5 裁决后） | stub 与 real 的错误分类、状态迁移、`backend_info` 关键字段；数值 golden 只在 real 路径用 TFL3 期望 | 变体名一致、状态序列一致；数值按冻结容差；库哈希/内核版本登记 |
| Python 外部运行时（B18「后续」） | 同一 TFL3 模型逐元素输出 | 绝对误差 <1e-4；依赖缺失→显式 SKIPPED，不进通过计数 |

纪律：oracle 缺失 → 显式 SKIPPED + 原因（退出码 78 口径），不得写成通过；`golden real` 首行强制 `backend_name()=="real"`，否则 fail 而非静默跳过。R runner：样本路径 + 登记哈希 → 哈希不符拒绝执行 → 规范化差分 → 报告「本地已差分 + 哈希 + 日期」；`.local/` 产物永不入库。

## 6. 覆盖矩阵与错误簿记

### 6.1 能力×场景×安全 覆盖矩阵

现状列来自 2026-11-17 P4 实测（B# 见开发文档 §0）；✓=已有用例，◐=点状/间接覆盖，✗=待建。

| ID | 能力/场景 | L0 | L1 | L2 | L3 | L4 | 现状(P4) | 缺口→W# |
|---|---|---|---|---|---|---|---|---|
| F1 | Interpreter 生命周期/访问器 | ✓ | ◐ | ✗ | ✗ | ✓ | errdefer + close 单点 + 四态（B10） | 序列 golden→W2 |
| F2 | 张量 API/dtype/量化 | ✓ | ◐ | ◐ | ✗ | ✓ | 长度校验 + 容差 golden（B12/B13） | 双通道登记→W1/W2 |
| F3 | resize/allocate | ✓ | ◐ | ✗ | ✗ | ✓ | 8 条用例 + 双路径状态码差异（B11） | 差异 golden→W2 |
| F4 | 17 shim + stub/real/auto | ✓ | ✗ | ◐ | ✗ | ✓ | 粘性路由 + F1/F2/F3（B8/B9） | 诊断矩阵→W2；ABI 门禁→W5 |
| F5 | 后端诊断 | ✓ | ✗ | ◐ | ✗ | ◐ | 二元名 + 文本 info（B9/B19） | 三态 resolved→W4 |
| F6 | 错误模型 13 变体 | ✓ | ✗ | ◐ | ✗ | ✓ | 显式簿记 13/13（B3） | 门禁化→W2 |
| F7 | CLI 0/1/2 + 记录行 | ✓ | ✗ | ✗ | ✗ | ✓ | 7 选项 + 13 条退出码断言（B15） | 记录行黄金→W2 |
| F8 | 零入库 golden 链 | ✓ | ◐ | ◐ | ✗ | ✗ | 内嵌生成器 + SHA-256 + 容差（B13）；登记文件无消费者（B14） | 双通道门禁→W1/W2 |
| F9 | 真实库/许可/平台 | ✗ | ✗ | ✗ | ◐ | ✗ | 未在本仓库复验（B18/B23） | 裁决→W5/W6 |
| S1 | 预期场景端到端（模型→推理→输出） | ✓ | | ◐ | | ✓ | stub 链全绿；real 链 2 条 SKIPPED（B22） | real golden→W5 |
| S2 | 安全拒绝（版本不符/非法 dtype/超尺寸/重复 close） | ✓ | ◐ | | | ✓ | 显式变体断言 | 元数据上界→W3 |
| C1 | 输入安全（无 panic/内存有界/句柄不泄漏） | ◐ | ✗ | | | | 有长度校验，无元数据上界（B20） | rank/byte_size→W3 |
| C2 | 防火墙（新包不改旧语义） | ◐ | ✗ | ✗ | | ◐ | 尚无固化 golden | T-W2-5/T-W3-3/T-W4-2 |
| C3 | 许可红线（F-D 零入库） | ✓ | | | | | `.local` 不跟踪（B7/B23） | R runner 哈希→W5；终裁→W6 |
| C4 | 契约稳定（快照/索引/引用实存性/SKIPPED） | ◐ | | | | | 双快照无漂移；索引与注释漂移（B2/B16/B22） | 清理→W1；门禁→W2 |

C 行含防火墙（C2）与许可红线（C3）两行。

### 6.2 错误变体触发簿记（13/13 强制）

| 变体 | 触发 fixture（现状，2026-11-17） | 新增触发（待建） |
|---|---|---|
| `LibraryNotLoaded` | ✓ 版本断言不符（后端白盒注入） | 真实库加载失败对照（W5） |
| `ModelCreateFailed` | ✓ 非法模型字节/status -1 | 位翻转语料（W2） |
| `InterpreterCreateFailed` | ✓ `thread_count<1` 与创建失败 | 真实 options 拒绝（W5） |
| `AllocateTensorsFailed` | ✓ resize/allocate 白盒错误路径 | real 分配失败（W5） |
| `InvalidTensorIndex` | ✓ index -1 / ≥count（输入与输出两路） | 无 |
| `ResizeFailed` | ✓ rank 0/9、dims ≤0、后端拒绝 | 真实 rank 冲突（W5） |
| `CopyFromBufferFailed` | ✓ 未 allocate 状态码 2、注入失败 | 真实 EFAULT 类（W5） |
| `CopyToBufferFailed` | ✓ 未 allocate 状态码 2、注入失败 | 真实读取失败（W5） |
| `InvokeFailed` | ✓ 未 allocate / 注入 invoke 失败 | 真实算子缺失（W5/Q10） |
| `BufferSizeMismatch` | ✓ `set_input` 长度不符 | 元数据 byte_size 越界（W3） |
| `UnsupportedDtype` | ✓ 未知 dtype 码、Float16 未 `allow_fp16` | 真实量化 dtype（W5） |
| `AlreadyClosed` | ✓ close 后调用全部方法、重复 close | 无 |
| `NullHandle` | ✓ 空句柄元数据查询白盒 | 异常 rank 元数据（W3） |

显式簿记 **13/13**（2026-11-17 实测）；W3/W5 只增加触发语料，不新增变体。

### 6.3 恒等式断言（语义契约，全路径成立）

- 资源恒等式：`close` 是唯一 interpreter/model 释放点；`from_bytes` 任一失败分支后活跃句柄计数归零；options 在创建 interpreter 后即释放。
- 状态恒等式：`Closed ⇒ 任一方法（除 state/input_count/output_count）返回 AlreadyClosed`；`invoke` 期间状态为 `Invoking`，结束或失败后复位 `Ready`。
- 尺寸恒等式：`set_input` 接受长度恒等于 `desc.byte_size`；`output_raw` 返回长度恒等于输出 `desc.byte_size`。
- 诊断恒等式：`backend_info()` 键序与取值域冻结；`resolved=none` 在 W4 前恒映射 `backend_name()=="stub"`（作为已知局限写入 golden）；W4 后新函数三态可判定。
- 数值恒等式：stub STF1 scale=1.0 时输出恒等于输入；TFL3 乘法期望由独立 mini flatbuffer 解析器重算；容差公式逐字冻结。
- **防火墙恒等式：任一 W# 合入后旧 API 在既有 49 语料上输出逐字节不变、旧用例零改动全绿**（W1 纯文档包以旧用例零改动全绿为准）。

### 6.4 #skip 清单（显式单列，永不计入通过）

| 用例 | 位置 | 原因 |
|---|---|---|
| `golden real micro_mul_f32 v1` | `real_golden_test.mbt` L830–853 | 需真实后端 + 仓库外真实库；默认 stub 环境显式 SKIPPED，首行断言 `backend_name()=="real"` |
| `golden real micro_mul_f32 v2` | `real_golden_test.mbt` L856–879 | 同上；历史「2/2 通过」属仓库外事实，本轮未复验 |

计数口径：默认 51 条声明（实际执行 49 + `#skip` 2）− 2 条 `#skip` = **49 执行**（2026-11-17 `moon test` 实测 49/49）；`moon test --include-skipped -f "golden real*"` 需真实库，缺失时显式 SKIPPED（退出码 78 口径），不进通过计数；历史 2/2 不计入当前结论。

### 6.5 验收 ID 双向追溯表

| `T-W*-*` | W#（开发文档） | 矩阵缺口行 | 断言/层 |
|---|---|---|---|
| T-W1-1 引用实存性扫描零失效 | W1 | C4 | A5/L5 |
| T-W1-2 README 索引 ↔ mbti 逐条一致 | W1 | C4 | A5/L5 |
| T-W1-3 五门禁绿 + 双快照 diff 空 | W1 | C4 | A5/L5 |
| T-W1-4 CHANGELOG 建立并登记 | W1 | C4 | A5/L5 |
| T-W1-5 登记文件双通道门禁或降级标注 | W1 | F8、C4 | A5/L5 |
| T-W2-1 golden 入库且被测试真实读取 | W2 | F1–F4、F6、S1 | A1/L2 |
| T-W2-2 状态机/双路径差异性质全绿 | W2 | F1、F3、F4、A6 | A7/L1 |
| T-W2-3 13/13 错误簿记门禁化 | W2 | F6 | A2/L5 |
| T-W2-4 CLI 记录行与退出码逐字节回归 | W2 | F7 | A5/L4 |
| T-W2-5 旧 49 用例零改动全绿（防火墙） | W2 | C2 | A5/L5 |
| T-W2-6 `golden real` SKIPPED 纪律断言 | W2 | S1、C4 | A2/L5 |
| T-W3-1 越界 rank → `NullHandle`，无 panic | W3 | C1、F2 | A4/L0 |
| T-W3-2 超大/负 byte_size → `BufferSizeMismatch` | W3 | C1、F2 | A4/L0 |
| T-W3-3 合法模型逐字节不变、旧 49 用例零改动 | W3 | C2 | A5/L5 |
| T-W3-4 截断/变异模型字节扫描无崩溃 | W3 | C1 | A4/L1 |
| T-W4-1 stub/real/none 三态字面量断言 | W4 | F5、A8 | A8/L0 |
| T-W4-2 旧 `backend_name()` 输出不变 | W4 | C2 | A5/L5 |
| T-W4-3 快照 diff 纯加法、变体仍 13 个 | W4 | C4、F6 | A5/L5 |
| T-W5-1（裁决 A）每里程碑五门禁绿 + stub 旧用例零改动 | W5（`tools/real-golden.sh` 已落地；真实库未登记，未写通过） | F9、C2 | A5/L5 |
| T-W5-2（裁决 A）真实与 stub 错误分类/状态序列一致 | W5（POSIX dlopen 已在既有源码；本机未实测） | F4、A6 | A6/L3 |
| T-W5-3（裁决 A）设备/数值报告含哈希登记与 SKIPPED | W5（runner 哈希门禁实测 ✓；真机报告未配置，SKIPPED） | F9、C3 | A4/R |
| T-W5-4（裁决 B）README 与测试文档维持未实现声明 | W5（B 未采纳，存档） | F9 | A3/L5 |
| T-W6-1（裁决 A）分发清单零第三方二进制 | W6（A 已落地 ✓，`docs/LICENSE-INDEX.md`） | C3 | A3/L5 |
| T-W6-2（裁决 A）许可索引自包含、无工作区路径 | W6（A 已落地 ✓） | C4 | A5/L5 |
| T-W6-3（裁决 B）残余状态文档化且红线不破 | W6（B 未采纳，存档） | C3 | A3/L5 |

W5/W6-A 已裁决并落地 runner/许可索引；真实库差分与设备报告仍保持「未实测/SKIPPED」，不预写通过。

## 7. L4 CLI 场景 E2E

| 场景 | 命令序列 | 断言要点（退出码 + 记录行 + 落盘） |
|---|---|---|
| `--help` / 缺参 | `--help`；无参数；未知选项 | 0 / 2 / 2；帮助文本冻结 |
| stub 全链 | `--model <自产 STF1> --backend stub --input <hex>` | 0；记录行 `MODEL|/INPUTS|/OUTPUTS|/OUTDESC|/INVOKE|/OUTDATA|/DONE|` 顺序与字段冻结；`--out-raw` 落盘字节哈希登记 |
| `--info` | `--info --backend stub` | 0；输出含 `mode/resolved/load_status` 且与 `backend_info()` 一致 |
| auto 回退 | `--backend auto --lib <不存在路径>` | 0（回退 stub）；`resolved=stub` 且 reason 含 F1 类标 |
| real 强制失败 | `--backend real --lib <不存在路径>` | 1；`resolved=none`、`load_status=F1/F2/F3`；不回退、不崩溃 |
| 推理失败 | 非法模型字节、尺寸不符输入 | 1；错误行含变体分类；`--out-raw` 不落盘 |
| 失败后恢复 | 失败命令后再跑 stub 全链 | 0；进程内无句柄泄漏 |

记录行/JSON 契约冻结口径：`MODEL|`/`INPUTS|`/`OUTPUTS|`/`OUTDESC|`/`INVOKE|`/`OUTDATA|`/`DONE|` 逐字冻结；退出码 0=成功 / 1=`TfLiteError` / 2=用法错误；脚本层 78 为 SKIPPED 独立口径。

## 8. L5 元契约门禁

1. 快照门禁：`moon info` + `git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti`（纯加法）。
2. ABI 门禁：17 个 `mb_tfl_*` 符号/签名/`#borrow` 标注与 C 状态码语义逐条核对，变更即红。
3. 错误簿记门禁：§6.2 的 13 变体 ↔ 测试代码双向核对，缺一即红。
4. 变异自检：注入 3 类缺陷（跳过 AllocateTensors / 把 F1 误映射为 F2 / 容差公式放宽一个数量级），套件必须变红后还原复绿。
5. 计数纪律：`#skip` 不计通过；过滤串以 `*` 结尾防空转假绿；`golden real` 历史 2/2 单列报告。
6. 引用实存性扫描：`.mbt/.md/.yml/.c/.h/.ps1` 注释与文案引用的仓库内路径全部实存；README 索引与快照逐条一致；`.local/` 仍不受版本控制；无工作区路径与兄弟模块符号。

## 9. CI 集成与执行入口

五门禁不变（CI 已固化）；L0/L1/L2 挂 `moon test`；L3/L4/R/真实库对照为脚本层可选 job，缺失显式 SKIPPED。
复验命令（本仓库根目录自包含）：

```bash
moon check --deny-warn
moon build
moon test
moon fmt --check
moon info; git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti
moon test --include-skipped -f "golden real*"    # 需仓库外真实库，否则显式 SKIPPED
```

Windows 下 moon 把进度写 stderr，以退出码与 `Total tests: N, passed: N` 判定；语句分隔用 `;` 而非 `&&`。

## 10. 维护规则与验收清单

1. 新增 pub API ⇒ 同提交附 L0 样例 + L1 性质 + 矩阵/簿记更新；无测试不合入。
2. 新增 shim/状态码分支/解析路径 ⇒ 进截断扫描与诊断矩阵 fixture 集。
3. golden/登记哈希变更 ⇒ 黄金记录同提交更新，并附「仅受影响样本变化」对照；容差公式永不静默放宽。
4. 每包合入 ⇒ 开发文档 DoD 勾选 + 矩阵现状刷新 + CHANGELOG 测试增量。
5. 「通过」须可复验：命令 + 日期 + 计数；SKIPPED 永远单列；stub/real 期望永不混报。

落地验收：L0 ✓（49 条实跑）、L1 ◐（点状，W2/W3 补齐）、L2 ◐（内嵌 golden 已消费，登记文件双通道与真实 golden 待 W1/W2/W5）、L3 ◐（W5-A runner 已落地；无登记真实库→SKIPPED，未声称通过）、L4 ✓（CLI 白盒覆盖，脚本黄金待 W2）、L5 ◐（快照与计数已验，ABI/簿记门禁与变异自检待 W2）、R ✗（2 条 `#skip` 占位；W5-A 本地可选）；W5/W6 已裁决 A，不再列为待裁决项。
