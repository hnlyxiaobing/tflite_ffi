# tflite 数值黄金登记（tflite_ffi/tests/fixtures/golden/ASSETS.md）

> 建立：2026-11-08。登记文件：`micro_mul_f32.numeric.norm.txt`。
> **数据口径（冻结）自足登记于本文件**：§1 登记内容、§2 容差、§3 stub/real 分报
> 规则、§4 SKIPPED 语义、§5 红线。**回归入口 = `moon test`**（golden tflite/real 类
> 用例即本登记的执行体；开发期曾由外层 golden 校验脚本按同一口径分链校验，
> 其口径已全部并入本文件）。证据等级标注：`[已复核]` = 本机命令/文件实测 ｜
> `[仅据文档]` ｜ `[仍需实测]`。

## 1. 登记内容（micro_mul_f32，冻结数据口径）

- 模型语义：输入 `"in"` f32 [1,4]；常量 `"w"` f32 [4] = [0.5, 1.0, 2.0, -1.0]；
  单 MUL(builtin) → 输出 `"out"` f32 [1,4]。
- 测试向量（`VEC|<backend>|<id>` 行，期望值以 f32 IEEE-754 位型 hex 登记；2026-11-08
  裁决**双后端期望显式化拆分**，落实"真实库数值与 stub 数值不得混报"到登记层）：

  | 后端 | 向量 | in | want（f32 文本） | wanthex |
  |---|---|---|---|---|
  | real（TFL3，MUL w） | V1 | 1, 2, 3, 4 | 0.5, 2, 6, -4（f32 精确） | `3F000000,40000000,40C00000,C0800000` |
  | real（TFL3，MUL w） | V2 | 0.1, -0.3, 7.77, 1e3 | 0.05, -0.3, 15.54, -1000 | `3D4CCCCD,BE99999A,4178A3D7,C47A0000` |
  | stub（STF1，恒等） | V1 | 1, 2, 3, 4 | 1, 2, 3, 4（恒等拷贝） | `3F800000,40000000,40400000,40800000` |
  | stub（STF1，恒等） | V2 | 0.1, -0.3, 7.77, 1e3 | 0.1, -0.3, 7.77, 1000（恒等拷贝） | `3DCCCCCD,BE99999A,40F8A3D7,447A0000` |

- 后端语义（与库内测试实现逐位一致 `[已复核]`）：**real = f32(f64×f64) MUL 权重期望**（want_i =
  f32(in_i×w_i)）；**stub = STF1 恒等拷贝期望**（want_i = f32(in_i)，镜像 scale=1.0）。
- want 的参考计算（冻结）：逐元素 f64 乘积 `in_i × w_i` → f32 舍入 → 位型 hex（real）；
  输入位型原样（stub）。回归时**按后端语义分算独立重算**并与登记比对（位型精确，
  2026-11-08 实测一致 `[已复核]`；`real_golden_test.mbt` 内嵌参考计算即该重算的
  执行体）。

## 2. 容差（冻结，文档化）

**逐元素 f32：`|got − want| ≤ 1e-6 + 1e-5 × |want|`**（f64 比较；NaN=NaN bit 相等；
±0 等价；Inf bit 相等）。容差超限 = 失败，**不得放宽**。登记行为
`TOL|abs=1e-6|rel=1e-5|cmp=f64|nan=bit-equal|pm0=equal|inf=bit-equal`，
校验口径 = 逐字比对该行（漂移即 FAIL）。
**适用面（裁决 2026-11-08）**：仅约束**数值断言侧**（各后端运行输出对各自独立参考值，
real 侧断言代码已就绪 `golden real*`，待真实库就位实跑）；登记自洽重算为位型精确比较，
不套容差。**跨后端同模型数值一致性（stub vs real 容差对比）因 STF1 语义上限不适用**
（STF1 仅支持标量 scale 逐元素缩放，无法表达 MUL 权重）——口径 = 各后端对各自独立参考值
在冻结容差内一致。

## 3. stub / real 双路径报告规则（强制，不得混报）

| 侧 | 执行 | 报告 |
|---|---|---|
| stub | `moon test -f "golden tflite*"`（`MB_TFLITE_BACKEND=stub`） | `tflite/stub ...` 独立成行、独立计数 |
| real | `moon test --include-skipped -f "golden real*"`（`MB_TFLITE_BACKEND=real` + `MB_TFLITE_LIB_PATH=<探测命中>`） | `tflite/real ...` 独立成行、独立计数 |

- **不得混报**：两侧测试计数不合并、不相互抵扣；任一侧失败即 FAIL(1)。
- real 侧用例文件 `real_golden_test.mbt`；用例前缀 `golden real` 冻结；真实运行
  首行断言 `backend_name()=="real"`，不满足即 fail，**绝不静默跳过**。
- stub 侧数值黄金用例前缀 `golden tflite`（实测命名 `golden tflite
  micro model registry sha256` / `golden tflite stub mul_v1` / `golden tflite stub mul_v2`
  ——已对齐 `[已复核]`）。
- 本仓库内回归 = 上表两条 `moon test` 命令（golden 期望值与容差即本文件登记值）；
  开发期外层 golden 校验脚本按同一规则分链校验并以 exit 78 报告 SKIPPED（§4），
  其口径已并入本文件，仓库内不依赖任何外部脚本。

## 3.1 双后端语义对表差异登记（2026-11-08 裁决已执行）

库内实测语义（来源 `tests/fixtures/micro/ASSETS.md`、`real_golden_test.mbt`）：

| 侧 | 模型 | 语义 | V1/V2 期望输出 |
|---|---|---|---|
| stub | `micro_mul_f32.stf1`（STF1 镜像） | **scale=1.0 恒等**（STF1 仅支持标量 scale 逐元素缩放，无法表达 MUL 权重） | **输出 hex == 输入 hex**（V1 `3F800000,40000000,40400000,40800000`；V2 `3DCCCCCD,BE99999A,40F8A3D7,447A0000`） |
| real | `micro_mul_f32.tflite`（TFL3） | MUL 权重 w=[0.5,1,2,-1] | **MUL 期望**（V1 `3F000000,40000000,40C00000,C0800000`；V2 `3D4CCCCD,BE99999A,4178A3D7,C47A0000`） |

- **差异登记（原口径缺口）**：原 `VEC|…` 未区分双后端期望（隐含两侧同用 MUL 期望），
  stub/STF1 镜像 = 恒等语义，不适用 MUL wanthex。
- **裁决已执行（2026-11-08，批准数据行拆分）**：登记已拆为
  `VEC|real|V1/V2`（MUL 权重期望，原 wanthex 逐位保留）与 `VEC|stub|V1/V2`
  （STF1 恒等期望）；registry 自洽重算按后端语义分算（real=f32(f64×f64) MUL、
  stub=恒等拷贝）。落笔前对表库内登记值**逐位一致** `[已复核]`
  （stub 行 == `golden_v*_in()`；real 行 == `golden_v*_mul()`）。
- **跨后端同模型数值一致性（stub vs real 容差对比）因 STF1 语义上限不适用**；
  口径 = 各后端对各自独立参考值在冻结容差内一致（real 侧断言 `golden real*` 已就绪，
  待真实库就位实跑 `[仍需实测]`）。容差公式仅约束数值断言侧。
- 相关文件（`micro/ASSETS.md`、`real_golden_test.mbt` 等）**未改动**（其登记已正确）。

## 4. SKIPPED 语义（exit 78 ≠ 通过）

> **2026-11-09 实跑补充（R4）**：win-x64 真实库已取得（`.local/tflite/win-x64/`，
> SHA-256 与 PROVENANCE 见 `GAPS.md`），`moon test --include-skipped -f "golden real*"`
> 实跑 **2/2 通过**（首行 `backend_name()=="real"` 断言生效，冻结容差内数值对齐）。
> 本文其它处「待真实库就位实跑」的措辞指 2026-11-08 登记时状态；**无库环境的
> SKIPPED 语义不变**（仍不计通过）。

- **无真实库**（MB_TFLITE_LIB_PATH / tflite_ffi/.local/tflite / D:\Android\Sdk /
  %USERPROFILE%\.gradle\caches 逐条探测均未命中）→ `SKIPPED: tflite/real golden real 未执行：
  真实库不可用（探测逐条列因）` → **exit 78，不得计通过**。
- 校验链被禁用测试执行（仅工具校验）时 → stub/real 各自 SKIPPED 显式列因（同为 78）。
- 2026-11-08 本机实测 `[已复核]`：四条探测路径均无 `tensorflowlite_c.dll` →
  registry 自洽校验 PASS + 2×SKIPPED（golden real 未执行）→ **exit 78（不计通过）**。
  本仓库内等价回归：`moon test` 常规跑 = registry + stub 数值黄金全过、golden real
  类 SKIPPED 不计通过；取得真实库后
  `moon test --include-skipped -f "golden real*"` 复测 `[仍需实测]`。

## 5. 红线（重申，见 `DECISIONS.md` §3）

- 真实 `libtensorflowlite_c`（.so/.dll/.dylib）、真实第三方模型**禁入库**（含本目录）；
  唯一允许 = 本地链接（MB_TFLITE_LIB_PATH / `.local/`）+ SHA-256 记录。
- 自产微型模型**零入库**：`micro_mul_f32.{tflite,stf1}` 由
  `tflite_ffi/tools/gen-micro-model.ps1` 程序化生成到 gitignore 目录；模型字节 SHA-256 登记于
  `tests/fixtures/micro/ASSETS.md`。本目录只含数值登记（文本）。
- 确定性：登记无时间戳、无绝对路径；hex 大写 8 位固定格式；`-Update` 不改写登记
  （手写冻结数据；链内仅做自洽校验）。
