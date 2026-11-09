# GAPS.md — tflite_ffi 缺口台账（2026-11-08）

> fail-closed 登记口径（真实库获取链 D2 ④，见 `DECISIONS.md` §2/§3）：每条缺口 =
> 一项未闭环事实 + 影响面 + 放行条件。
> 真实库获取状态见 `tools/get-tflite.ps1`（D2 链：①本地探测 ②官方预编译
> ③官方源码最小构建 ④fail-closed）与 `.local/tflite/<platform>/PROVENANCE.md`。

## 真实库获取（win-x64 `tensorflowlite_c.dll`）

- [ ] 2026-11-08 get-tflite(win-x64/v2.14.0)：**D2 链 ④ fail-closed（exit 3）**——
  stub 为唯一运行路径；dispatch 回退接线完备（17 shim 双路径 + 三场景测试全绿
  34/34），脚本保留可复跑。放行条件见下方缺口清单首条。

## 获取尝试记录（D2 链逐步证据，2026-11-08 实跑）

| 步骤 | 结果 | 证据 |
|---|---|---|
| ① 本地探测（MB_TFLITE_LIB_PATH → `.local/tflite/win-x64/` → `D:\Android\Sdk` → `%USERPROFILE%\.gradle\caches`） | 未命中（`.gradle\caches` 不存在；Android SDK 递归搜索无 `tensorflowlite_c.dll`） | `tools/get-tflite.ps1` probe 日志（开发期脚本运行记录） |
| ② 官方可验证渠道 | 跳过（win-x64 无官方预编译 `tensorflowlite_c` 发布渠道；冻结规则「无则跳过，禁止第三方构建/镜像」，见 `DECISIONS.md` §2） | get-tflite step2 日志 |
| ③ 官方源码最小构建（tensorflow v2.14.0 tag、CMake 目标 `tensorflowlite_c`、MSVC x64、限时约 40 分钟） | **失败**：CMake 3.31.6（官方 Kitware 发行包）已就位并被脚本采用；`git clone --depth 1 --branch v2.14.0` 于 ~25 分钟后 RPC 中断（`curl 56 Recv failure: Connection was reset / early EOF`），并行吞吐实测 codeload 仅 ~3.7 KB/s（5 MB 区间请求 297 秒仅 1.09 MB 后超时）——限时内不可能完成获取+构建 | 脚本后台运行日志（开发期记录） |
| ④ fail-closed | **生效**：GAPS.md 登记（本文件 + 脚本自动追加行）+ 接线完备（stub 唯一运行路径）+ 脚本保留 | get-tflite exit=3 |

## 缺口清单

- [ ] **真实后端数值黄金未实跑**：`real_golden_test.mbt`（`golden real*`，#skip）在
  本机无真实库时按设计响亮失败（`golden real 用例要求真实后端生效（绝不静默跳过）`）
  或 SKIPPED 不计通过；golden real 联跑（`moon test --include-skipped -f "golden real*"`）
  在取得真实库后闭环。放行条件：真实 `tensorflowlite_c.dll` 就位（PROVENANCE +
  SHA256SUMS）且 golden real 2/2 过。
- [ ] **真实库运行期数值对齐（<1e-4 对 Python tflite-runtime）**：真实库对接遗留项，
  与本缺口联动闭环。
- [ ] **POSIX 分支（dlopen/dlsym）未实跑**：`native/mb_tfl_real.c` POSIX 路径
  已实现但仅据文档；放行条件：Linux x86-64 上 `moon test` + 三场景复跑。
- [ ] **STF1 镜像语义差异**：`micro_mul_f32.stf1` 取 scale=1.0 恒等（STF1 格式
  仅标量 scale，无法表达 MUL 权重逐元素语义）；登记于 DESIGN.md §14.4，
  不构成缺口（格式固有边界），列此备查。

## 运行路径结论

无论真实库获取成败，`mb_tfl_*` 17 shim 的 stub/real 双路径接线**完备**：
stub 路径（默认）全绿（34/34），real 路径解析/信封/映射就绪，三场景
（路径不存在/损坏映像/加载失败注入）在无真实库环境下全绿。

## 脚本自动登记行（tools/get-tflite.ps1 Register-Gap，原样保留）

- [ ] 2026-11-08 get-tflite(win-x64/v2.14.0)：D2 链（①本地探测 ②官方预编译 ③源码构建）均未取得可用 tensorflowlite_c.dll（fail-closed：stub 为唯一运行路径；接线完备，脚本保留）
