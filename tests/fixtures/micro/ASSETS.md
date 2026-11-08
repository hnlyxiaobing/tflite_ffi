# tests/fixtures/micro/ — 自产微型模型资产登记（ASSETS.md）

> WP-1（2026-11-08，契约 §4/D3）。**零入库**：`.tflite` / `.stf1` 二进制不进仓库
> （生成到 `tflite_ffi/.local/models/` 或 `@fs.tmpdir()`，`.local/` 已被 .gitignore
> 覆盖）。本目录只登记**生成方式 / SHA-256 / 许可**；测试内嵌生成器重建字节并
> 断言 SHA-256 == 本表登记值（`real_golden_test.mbt` 用例
> `golden tflite micro model registry sha256`，非 skip、每次 `moon test` 都跑）。

## 资产清单

| 文件 | 字节数 | SHA-256 |
|---|---|---|
| `micro_mul_f32.tflite` | 496 | `ba0f234cfc6b8593835c0882b8172945641262f5ca57b8a95e502a652163fb3c` |
| `micro_mul_f32.stf1` | 81 | `82351c2de386dc8b3d628994b7a371bfe290bb0d77796d464fefa97016c3d1ab` |

## micro_mul_f32 语义（契约 §4）

- 输入 `"in"` f32 `[1,4]`；常量 `"w"` f32 `[4] = [0.5, 1.0, 2.0, -1.0]`；
  单 MUL(builtin=18) → 输出 `"out"` f32 `[1,4]`。
- `micro_mul_f32.tflite`：真实 TFLite flatbuffer（file identifier `TFL3`，
  Model.version=3，MulOptions=BuiltinOptions 21），real 后端用。
- `micro_mul_f32.stf1`：STF1 **镜像**（stub 后端用）：同名同 I/O 形状，
  scale=1.0 恒等——STF1 仅支持标量 scale 逐元素缩放，无法表达 MUL 权重的
  逐元素语义；语义差异见 DESIGN.md §14「双路径语义差异登记」。

## 测试向量（golden hex 登记，与 WP-4 `tests/fixtures/golden/micro_mul_f32.numeric.norm.txt` 一致）

| 向量 | 输入（f32 hex） | MUL 期望（f32 hex） | 说明 |
|---|---|---|---|
| V1 | `3F800000,40000000,40400000,40800000` | `3F000000,40000000,40C00000,C0800000` | [1,2,3,4]→[0.5,2,6,-4]，f32 精确 |
| V2 | `3DCCCCCD,BE99999A,40F8A3D7,447A0000` | `3D4CCCCD,BE99999A,4178A3D7,C47A0000` | [0.1,-0.3,7.77,1e3] 逐元素 f64 乘积→f32 舍入 |

STF1 镜像（scale=1.0 恒等）期望：V1/V2 输出 = 各自输入 hex。

数值容差（契约 §4 冻结，逐元素 f32）：`|got − want| ≤ 1e-6 + 1e-5 × |want|`
（f64 比较；NaN=NaN bit 相等；±0 等价；Inf bit 相等）。容差超限=失败，不得放宽。

## 生成方式

- 生成器：`tools/gen-micro-model.ps1`（自研 flatbuffer 手工发射，无三方依赖；
  与 `real_golden_test.mbt` 内嵌生成器按同一布局规范逐字节一致，SHA-256 互证）。
- 布局规范（两实现共同）：反向构造；`alloc(size, align)` 补零至
  `(已写 + size) % align == 0`；字符串先预补零使 `[u32 len][bytes][NUL]` 连续
  且 len 4 对齐；表字段按 id 升序写入；vtable 在表体之后（soffset > 0）；
  结尾 pad 至 `已写 % 16 == 8` 后写 `"TFL3"` 标识与根 uoffset，总长 % 16 == 0
  （Buffer.data force_align=16）。
- 生成命令：`powershell -File tools/gen-micro-model.ps1`（默认输出
  `tflite_ffi/.local/models/`）。
- 参考输出=独立解析计算：`real_golden_test.mbt` 内嵌 mini flatbuffer 解析器
  抽取常量 w 并校验 TFL3 结构，`want = f32(f64(in) × f64(w))`，与上表 hex 互证。

## 许可

自产内容，无第三方素材；Apache-2.0（与 `tflite_ffi/LICENSE` 同口径）。
