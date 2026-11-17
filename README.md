# tflite_ffi · TFLite C API 推理运行时

> 独立发布单元 ｜ L3 感知绑定 ｜ `preferred_target = native` ｜ Apache-2.0
> 状态：`moon test` **49/49** 通过（2026-11-11 本机实测，另有 2 个 `#skip` 用例不计入）；本文件是本仓库**唯一**说明文档。
> 公开 API 以 `pkg.generated.mbti` 为准（由 `moon info` 生成，禁手工编辑）；加法性变更须登记簿记 + 快照审阅 + 快照门禁。

## 1. 定位与边界

只绑 `c_api.h` 稳定 ABI，把模型字节变成输出张量；无真实库时用内置 stub 保持可验证。

**能力**

- `Interpreter` 生命周期与张量 API：`from_bytes` / `set_input` / `invoke` / `output_raw` / `output_desc` / `resize_input` / `allocate_tensors` / `close`
- 17 个包私有 `mb_tfl_*` C shim，一次性符号解析 + 进程级粘性路由
- stub / real / auto 双路径；`backend_name()` / `backend_info()` 是仅有的两条加法性公开 API
- F1（路径探测失败）/ F2（映像无效）/ F3（加载失败）可观察分类；`auto` 回退 stub、`real` 显式报错
- CLI：`--model / --backend / --lib / --threads / --info / --input / --out-raw`，退出码 0/1/2

**非目标**

- 不使用 delegate / GPU，不绑 MediaPipe Tasks C API 或 ONNX
- 不把真实 `.so`/`.dll`/模型或第三方模型带入仓库

## 2. 关键设计决策（本仓库自足记录）

- D1 库层默认 `stub`、CLI 默认 `auto`；D2 真实库获取顺序 本地探测 → 官方预编译 → 官方源码最小构建（限 40 分钟）→ fail-closed 缺口登记；D3 微型模型零入库；D5 不公开 `select_backend`（走 `MB_TFLITE_BACKEND` / `MB_TFLITE_LIB_PATH`）；D6 退出码 0/1/2。
- STF1（stub 模型）与 TFL3（real flatbuffer 模型）**不可混用**；数值容差 `|got−want| ≤ 1e-6 + 1e-5×|want|`，stub/real 期望值显式拆分不得混报。
- win-x64 `tensorflowlite_c.dll` v2.14.0 已本地源码构建（2,244,096 B / 24 导出 / SHA-256 `6bec4ce6…eccbac`），`golden real*` 2/2；linux/android 仍按 fail-closed 缺口登记。
- Q10：两个真实目标模型在 real 路径均 `INVOKE|ok`，`c_api.h` 稳定 ABI 未暴露缺失算子；Q4 许可事实层已收敛、法务残余仍开放。
- 2026-11-17 裁决 A 落地：`tools/real-golden.sh` 以仓库外库路径 + SHA-256 登记驱动真实 golden，缺库/缺工具显式 SKIPPED（退出码 78）、哈希未登记硬失败；许可口径与分发红线见 [`docs/LICENSE-INDEX.md`](docs/LICENSE-INDEX.md)。

### 2.1 STF1 内部格式（stub 运行时契约）

- 文件头 `magic="STF1"`、`version=1`；dtype 码 `0=F32 … 5=I64`；输出 `dim=-1` 表示镜像 input 0 的形状。
- `invoke` 语义为 `out[k] = scale * src[k]`（`scale=1.0` 恒等）；状态码 `0=ok / 1=通用错误 / 2=NOT_ALLOCATED`。
- 17 个 shim 在 stub 侧改名为 `mb_tfl_stub_impl_*`；数值期望与容差登记在本仓库 `tests/fixtures/golden/ASSETS.md` 与 `tests/fixtures/micro/ASSETS.md`（两文件是测试断言目标，须与代码同步）。

## 3. 公开 API 索引（自动抽取 `pkg.generated.mbti` 的 `pub` 声明行；完整字段见快照）

```text
pub fn backend_info() -> String
pub fn backend_name() -> String
pub(all) suberror TfLiteError {
pub fn Interpreter::allocate_tensors(Self) -> Unit raise TfLiteError
pub fn Interpreter::close(Self) -> Unit raise TfLiteError
pub fn Interpreter::from_bytes(Bytes, InterpreterOptions) -> Self raise TfLiteError
pub fn Interpreter::input_count(Self) -> Int32
pub fn Interpreter::invoke(Self) -> Unit raise TfLiteError
pub fn Interpreter::output_count(Self) -> Int32
pub fn Interpreter::output_desc(Self, Int32) -> TensorDesc raise TfLiteError
pub fn Interpreter::output_raw(Self, Int32) -> Bytes raise TfLiteError
pub fn Interpreter::resize_input(Self, Int32, Array[Int32]) -> Unit raise TfLiteError
pub fn Interpreter::set_input(Self, Int32, Bytes) -> Unit raise TfLiteError
pub fn Interpreter::state(Self) -> InterpreterState
pub(all) struct InterpreterOptions {
pub(all) enum InterpreterState {
pub(all) struct Quantization {
pub(all) struct TensorDesc {
pub(all) enum TensorDtype {
```

## 4. 依赖、平台与许可

零第三方依赖（3 个 native-stub C 源文件）；`preferred_target = native`；Apache-2.0。

## 5. 命令行与验证

- `moon run cmd/main --target native -- --model <path> [--backend stub|real|auto] [--lib <path>] [--threads N] [--info]`；输出 `MODEL| INPUTS| OUTPUTS| OUTDESC| INVOKE| OUTDATA| DONE|`。
- 复验：`moon clean` → `moon check --deny-warn` → `moon build` → `moon test` → `moon fmt --check` → `moon info` 后检查 `pkg.generated.mbti` 无意外 diff。
- 本仓库为独立 Git 仓库，文档与 CI 均自包含，不依赖工作区其他目录。

## 6. 风险与未决

- POSIX 分支仅做过 WSL C 层手工 40/40 冒烟；Linux CI 与 Android 真机未实测。
- Q4 法务残余（范围声明约束力、随包分发终裁）须在最终 App 分发前闭环。
- 量化精度数值对齐与两阶段图端到端仍未实测。

