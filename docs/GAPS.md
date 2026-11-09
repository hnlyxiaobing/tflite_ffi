# GAPS.md — tflite_ffi 缺口台账（2026-11-08 建立；2026-11-09 R4 复跑更新）

> fail-closed 登记口径（真实库获取链 D2 ④，见 `DECISIONS.md` §2/§3）：每条缺口 =
> 一项未闭环事实 + 影响面 + 放行条件。
> 真实库获取状态见 `../tools/get-tflite.ps1`（D2 链：①本地探测 ②官方预编译
> ③官方源码最小构建 ④fail-closed）与 `../.local/tflite/<platform>/PROVENANCE.md`。
>
> **2026-11-09 复跑结论（R4）**：D2 链 ③ 成功——官方源码 v2.14.0 在 win-x64 构建出
> `tensorflowlite_c.dll`，`get-tflite.ps1` **exit 0**，真实后端 `golden real` **2/2 通过**
> （`moon test --include-skipped -f "golden real*"`）。真实 `.dll` **未入库**，仅
> `../.local/tflite/win-x64/` 本地链接 + `PROVENANCE.md` + `SHA256SUMS.txt`。历史
> 2026-11-08 fail-closed 记录原样保留。

## 真实库获取（win-x64 `tensorflowlite_c.dll`）

- [x] 2026-11-08 get-tflite(win-x64/v2.14.0)：**D2 链 ④ fail-closed（exit 3）**——
  stub 为唯一运行路径；dispatch 回退接线完备（17 shim 双路径 + 三场景测试全绿
  34/34），脚本保留可复跑。（**历史记录**；2026-11-09 已复跑成功，见下。）
- [x] 2026-11-09 get-tflite(win-x64/v2.14.0)：**D2 链 ③ 源码构建成功（exit 0）**——
  产物 `../.local/tflite/win-x64/tensorflowlite_c.dll`（2,244,096 B，SHA-256
  `6bec4ce6ee3db69a0c15112fbb8d4449955d46fa8d181b865a58ec1400eccbac`，24 个必需导出），
  `PROVENANCE.md` + `SHA256SUMS.txt` 已产出；运行期 `TfLiteVersion=2.14.0`、
  `TfLiteSchemaVersion=3`。真实 `.dll` 未入库。

## 获取尝试记录（D2 链逐步证据）

### 2026-11-08（历史，fail-closed）

| 步骤 | 结果 | 证据 |
|---|---|---|
| ① 本地探测（MB_TFLITE_LIB_PATH → `../.local/tflite/win-x64/` → `D:\Android\Sdk` → `%USERPROFILE%\.gradle\caches`） | 未命中（`.gradle\caches` 不存在；Android SDK 递归搜索无 `tensorflowlite_c.dll`） | `../tools/get-tflite.ps1` probe 日志（开发期脚本运行记录） |
| ② 官方可验证渠道 | 跳过（win-x64 无官方预编译 `tensorflowlite_c` 发布渠道；冻结规则「无则跳过，禁止第三方构建/镜像」，见 `DECISIONS.md` §2） | get-tflite step2 日志 |
| ③ 官方源码最小构建（tensorflow v2.14.0 tag、CMake 目标 `tensorflowlite_c`、MSVC x64、限时约 40 分钟） | **失败**：CMake 3.31.6（官方 Kitware 发行包）已就位并被脚本采用；`git clone --depth 1 --branch v2.14.0` 于 ~25 分钟后 RPC 中断（`curl 56 Recv failure: Connection was reset / early EOF`），并行吞吐实测 codeload 仅 ~3.7 KB/s（5 MB 区间请求 297 秒仅 1.09 MB 后超时）——限时内不可能完成获取+构建 | 脚本后台运行日志（开发期记录） |
| ④ fail-closed | **生效**：GAPS.md 登记（本文件 + 脚本自动追加行）+ 接线完备（stub 唯一运行路径）+ 脚本保留 | get-tflite exit=3 |

### 2026-11-09（R4 复跑，成功）

| 步骤 | 结果 | 证据 |
|---|---|---|
| ① 本地探测 | 未命中（目标目录尚无库） | `../.local/get-tflite-2026-11-09.log` / `-run2.log`（本地日志，未入库） |
| ② 官方预编译 | 跳过（win-x64 无官方预编译 `tensorflowlite_c`，规则不变） | 同上 |
| ③ 首次源码构建 | **失败（脚本缺陷）**：脚本以 `tensorflow/lite` 为 CMake 入口、`-A x64`；CMake 3.31.6 不识别 VS 2026（18.x）生成器 → 退化为 `NMake Makefiles`，且未导入 MSVC 环境 → `CMAKE_C_COMPILER not set`。该失败已自动登记（见文末），未写成通过 | `../.local/get-tflite-2026-11-09.log` |
| ③ 修正后源码构建 | **成功**：`git clone --depth 1 --branch v2.14.0` 完成（30,134 files）；入口改 `tensorflow/lite/c`（target `tensorflowlite_c`）+ `vcvars64`/NMake + `TFLITE_ENABLE_XNNPACK=OFF`；另修复导出：`tensorflow-lite` 静态库把 `TFL_STATIC_LIBRARY_BUILD` 传播给 C API，导致 DLL 初版 **47 KB 且 0 导出**；生成 `.def` 强制导出 24 个稳定 C API 符号后为 **2,244,096 B / 24 导出**。configure/build 均 exit 0 | 构建日志（本地）；产物 `PROVENANCE.md` |
| ④ | **未触发**：`Install-Lib` 校验 SHA-256 + 24 导出符号通过，脚本 exit 0 | `get-tflite.ps1` run2 exit 0；`SHA256SUMS.txt` |

## 由真实库实跑发现的实现缺陷（已修复）

- **real 路径首次未 `AllocateTensors`**：`TfLiteInterpreterCreate` **不会**自动分配张量；
  MoonBit `from_bytes` 之前直接 `set_input`，real 路径在 `TfLiteTensorCopyFromBuffer`
  写 `tensor->data.raw == NULL` 时崩溃（Windows `0xC0000005`，golden real/CLI 均复现）。
  修复：`from_bytes` 在创建解释器后显式调用 `mb_tfl_allocate_tensors`，失败抛
  `AllocateTensorsFailed`（stub 侧重复 allocate 幂等，49 个既有/新增用例零回归）。
  修复后：golden real 2/2、CLI `--backend real` 全链路均通过。

## 缺口清单

- [x] **真实后端数值黄金未实跑** —— **2026-11-09 闭环**：真实库就位（PROVENANCE +
  SHA256SUMS）后 `moon test --include-skipped -f "golden real*"` 实跑
  `Total tests: 2, passed: 2, failed: 0`；首行 `backend_name()=="real"` 断言生效，
  数值按冻结容差 `|got−want| ≤ 1e-6 + 1e-5×|want|` 通过（f64 比较）。
- [ ] **真实库运行期数值对齐（<1e-4 对 Python tflite-runtime）**：本机
  `python 3.14.2` **无** `tensorflow` / `tflite_runtime`（import 实测失败），未做
  Python 跨实现对齐 → `[仍需实测]`。注意：golden real 的参考值是仓库内独立
  flatbuffer 解析 + 登记 hex，不等于 Python tflite-runtime 对齐。
- [x] **POSIX 分支（dlopen/dlsym）C 层手工实跑** —— 2026-11-09 在 WSL2 Ubuntu
  x86_64（gcc 15.2）手工编译 `../native/mb_tfl_real.c` + `mb_tfl_dispatch.c` +
  `../stub/mb_tfl_stub.c`，40/40 冒烟检查通过（F1/F2/F3、real 强制哨兵、auto 回退、
  mock 库成功加载、resize/allocate/invoke、tensor_meta、reset 守卫）；详见
  `POSIX-REVIEW.md`。**边界**：不是 `moon test`、不是真实 `.so`、不是 Android。
- [ ] **Linux CI / Android POSIX 实跑**：Linux runner 上 `moon test` 全量（49 用例，
  `native-stub` 多文件 gcc 链接）与 Android armv7/arm64 `dlopen` 仍未实测 →
  `[仍需实测]`。放行条件：Linux x86-64 `moon test` 全绿 + 目标设备三场景复跑。
- [ ] **Q10 real 侧算子覆盖**：目标模型（MoveNet 等）真实算子集合与真实库内核
  可用性未实测；stub 侧可验证部分已做成 6 个用例。见 `Q10-OPERATOR-COVERAGE.md`
  （real 侧全部 `pending_real`）。
- [ ] **STF1 镜像语义差异**：`micro_mul_f32.stf1` 取 scale=1.0 恒等（STF1 格式
  仅标量 scale，无法表达 MUL 权重逐元素语义）；登记于 DESIGN.md §14.4，
  不构成缺口（格式固有边界），列此备查。
- [ ] **Q4 许可残余**：真实库/模型随包分发条款与范围声明约束力仍待法务
  （`LICENSE-AUDIT-Q4.md`）；当前只本地链接、不分发。

## 运行路径结论

- **stub 路径（默认）**：全绿 **49/49**（2026-11-09 实跑）；三场景（路径不存在/
  损坏映像/加载失败注入）全绿。
- **real 路径（win-x64）**：真实库已取得并本地链接；`golden real` 2/2、CLI
  `--backend real --model micro_mul_f32.tflite` 全链路通过；`from_bytes` 隐式首次
  allocate 修复后无崩溃。
- **POSIX 路径**：C 层 WSL 手工 40/40；Linux CI 与 Android 仍待实测。
- 真实库二进制未入库；仓库内仅文本记录（本文件 + `PROVENANCE.md` 本地副本）。

## 脚本自动登记行（../tools/get-tflite.ps1 Register-Gap，历史原样保留）

- [ ] 2026-11-08 get-tflite(win-x64/v2.14.0)：D2 链（①本地探测 ②官方预编译 ③源码构建）均未取得可用 tensorflowlite_c.dll（fail-closed：stub 为唯一运行路径；接线完备，脚本保留）
- [x] 2026-11-09 get-tflite(win-x64/v2.14.0)：D2 链（①本地探测 ②官方预编译 ③源码构建）首次复跑因脚本 CMake 入口/生成器缺陷未取得（该行由修正前脚本自动登记，保留为失败证据）；同日修正脚本后源码构建成功，见上表，**最终状态为成功**。
