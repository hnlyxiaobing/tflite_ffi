# Q10 算子覆盖矩阵（tflite_ffi · R4，2026-11-09）

> 对应 `../../docs/open-questions.md` Q10：「`TfLiteInterpreter` 相关 C API 是否覆盖所需
> 算子 / delegate」——本轮假设「只用 CPU、不用 delegate」，最小实验是用目标
> `.tflite` 模型在桌面跑一次 `invoke`，确认无缺失算子。
>
> **证据等级**：`[已复验-本地]` = 本机测试/本机官方源码克隆实读；`[仅据文档]` =
> 官方文档或公开模型说明；`[仍需实测]` = 尚无证据，**不得**当作已通过。
>
> **结论口径（本轮不越界）**：
> - stub 侧可验证部分已做成测试（下方 §2，全部 `moon test` 实跑通过）；
> - real 侧目标模型算子集合与内核可用性**全部仍是 `[仍需实测]`**——本轮未取得
>   真实库，也未入库/解析任何真实第三方模型；矩阵中的 `pending_real` 即此状态。
> - 「C API 覆盖」≠「算子已覆盖」：C API 只提供 interpreter/tensor/invoke 通路，
>   具体算子由所链接的 TFLite 运行时的**内核注册表**决定；缺失算子通常在
>   `AllocateTensors` 或 `Invoke` 返回非 0（本库折叠为 `AllocateTensorsFailed` /
>   `InvokeFailed`），必须用真实模型实跑才能判定。

## 1. 覆盖矩阵

算子编号取自 TFLite schema `BuiltinOperator` 枚举，已对照本机官方源码克隆
（`tensorflow v2.14.0`，`../.local/src/tensorflow/tensorflow/lite/schema/schema.fbs`，
**未入库**，红线：外部源码/二进制只落 `../.local/`）逐项核对 `[已复验-本地]`。

| # | 算子 | BuiltinOperator | 来源分层 | stub 侧（可验证/已登记） | real 侧（待测） |
|---|---|---|---|---|---|
| 1 | `MUL` | 18 | **micro_golden**（自产 TFL3 黄金模型实际发射） | `scalar_scale_simulation`：STF1 用模型级标量 `scale` 模拟逐元素乘，**不是真实 MUL 内核** | `pending_real` `[仍需实测]` |
| 2 | `CONV_2D` | 3 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 3 | `DEPTHWISE_CONV_2D` | 4 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 4 | `ADD` | 0 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 5 | `SUB` | 41 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 6 | `RELU6` | 21 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 7 | `PAD` | 34 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 8 | `MEAN` | 40 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 9 | `RESIZE_BILINEAR` | 23 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 10 | `TRANSPOSE_CONV` | 67 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 11 | `CONCATENATION` | 2 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 12 | `SOFTMAX` | 25 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 13 | `MAX_POOL_2D` | 17 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 14 | `RESHAPE` | 22 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 15 | `DEQUANTIZE` | 6 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 16 | `QUANTIZE` | 114 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |
| 17 | `LOGISTIC` | 14 | movenet_candidate | `not_expressible` | `pending_real` `[仍需实测]` |

> **`movenet_candidate` 的边界**：候选清单来自目标模型（MoveNet SinglePose
> Lightning）的公开结构描述/常见 MobileNetV2+FPN 组合 `[仅据文档]`，**尚未**用真实
> 模型 flatbuffer 解析确认；它不是「必需算子已确认清单」。因此 real 侧每一行都是
> `pending_real`，不得写成已覆盖。若后续解析出的真实算子集合与本表不一致，以真实
> 模型解析结果为准并更新本表（加法/删行均需说明证据）。

## 2. stub 侧已验证测试（本轮实跑）

文件 `../q10_coverage_test.mbt`（黑盒，6 个用例）：

| 用例 | 证明什么 |
|---|---|
| `q10 scan micro tfl3 operator codes` | 独立 flatbuffer 解析器从自产 `micro_mul_f32.tflite`（TFL3）枚举出算子表恰为 `[MUL=18]`；矩阵 `MUL` 行编号/来源/real 状态一致 |
| `q10 matrix real-side rows stay explicitly pending` | 矩阵 ≥17 行；**每一行 real 状态必须为 `pending_real`**（防止把待测写成通过）；micro 模型实际算子必须都在矩阵内（防矩阵漂移） |
| `q10 stub rejects tfl3 model instead of silently covering ops` | stub 只认 STF1：喂 TFL3（含算子表）→ `ModelCreateFailed(-1)`，证明 stub 不会把「能创建解释器」误当成「算子已覆盖」 |
| `q10 stub dtype descriptor matrix covers all six dtypes` | STF1 描述层覆盖 F32/F16/I32/U8/I8/I64 六种 dtype（矩阵张量类型基础） |
| `q10 stub unknown dtype fails closed` | dtype 码 6 → `ModelCreateFailed(-1)`（畸形输入不 panic） |
| `q10 stf1 cannot carry an operator table` | STF1 无 OperatorCode 字段：尾部追加 `MUL=18` 4 字节被拒（尾随字节 fail-closed） |

**stub 侧模型的语义边界（已登记，不构成缺陷）**：STF1 是描述 + 标量缩放格式，
没有算子表；stub 的 `invoke` 恒为「输出 j 取输入 j % input_count，前 min(src,dst)
元素 `out[k] = scale * src[k]`」。因此 stub 能验证的是**张量描述/所有权/错误路径**，
不能验证真实算子内核。STF1 与 TFL3 **不可混用**（ADR-0011 §3）。

## 3. real 侧待办（全部 `[仍需实测]`）

> **真实库现状（2026-11-09）**：win-x64 `tensorflowlite_c.dll`（官方源码 v2.14.0）
> 已本地取得，**micro MUL 黄金已实跑 2/2**（`golden real*`，真实后端，见
> `GAPS.md`）。但目标模型（MoveNet/BlazePose）的算子集合与内核可用性**仍未实测**，
> 本表 real 列保持 `pending_real`，不得因「库已就位」而写成已覆盖。

1. **目标模型算子枚举**：在本地（不入库）用 Python `tf.lite.Interpreter` /
   flatbuffer 解析真实 MoveNet/BlazePose `.tflite`，导出 `operator_codes` 去重集合，
   与本表逐项比对。当前环境 `python 3.14.2` **无** `tensorflow` / `tflite_runtime`
   （本机实测 import 失败），此步未做。
2. **内核可用性**：用同一真实库构建（`tensorflowlite_c`，记录构建选项，如
   `TFLITE_ENABLE_XNNPACK`）跑 `AllocateTensors` + `Invoke`；缺失算子应得到非 0
   状态并映射为 `AllocateTensorsFailed` / `InvokeFailed`，记录具体算子名与状态码。
3. **数值对齐**：真实库输出 vs 独立参考实现容差
   `|got − want| ≤ 1e-6 + 1e-5 × |want|`（f64 比较，见 `../tests/fixtures/golden/ASSETS.md` §2）；跨实现
   目标另登记 <1e-4 vs Python `tflite-runtime`。
4. **delegate**：本轮非目标（ADR-0008 Decision 1 只绑稳定 C API、只用 CPU）；
   若未来启用 delegate，Q10 需重开并单独建矩阵。
5. **schema 版本**：解析期 `TfLiteSchemaVersion ∈ [1,16]` 断言已实现；真实库版本
   组合仍需实跑确认（见 GAPS.md 真实库缺口）。

## 4. 闭环判据（Q10 可关闭的条件）

- 真实库就位（`PROVENANCE.md` + `SHA256SUMS.txt`，本地 `../.local/tflite/win-x64/`）；
- 目标模型在本地解析出真实算子集合，且矩阵更新为 `confirmed`（附证据）；
- 真实库 `AllocateTensors` + `Invoke` 成功，缺失算子集合为空；
- 数值对齐测试通过（容差冻结口径，不得放宽）；
- 以上命令、退出码、模型 SHA-256 记入 `GAPS.md`/本文件，且不把 SKIPPED 写成通过。

## 5. 关联

- `../../docs/open-questions.md` Q10（唯一跟踪点，本轮不改根仓库文档，结论由主控汇总）
- `../../docs/adr/ADR-0008-inference-backend-selection.md`（只绑稳定 C API、CPU-only）
- `../../docs/adr/ADR-0011-tflite-real-integration-and-licensing.md`（STF1/TFL3 不可混用、
  真实库/模型禁入库、fail-closed）
- `../tests/fixtures/golden/ASSETS.md`（数值容差与自产模型哈希）
- `GAPS.md`（真实库缺口台账）
