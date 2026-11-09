# hnlyxiaobing/tflite_ffi

> **API 冻结前 P0 整改轮**（2026-11-07）。本包有 4 个 `#external` 句柄、**17 个包私有的 `extern "C"` shim 声明**（`stub/mb_tfl_stub.c` 提供桌面确定性 C 实现，`native-stub`，CI 默认后端；其中 2 个绑定带 `_` 前缀，库层暂无调用点）、值类型/错误模型与 **已实现**的 `Interpreter::{from_bytes, close, set_input, output_raw, invoke, output_desc}` 6 个方法 + `state` / `input_count` / `output_count` 3 个只读访问器。**无 `declare` 存根、无 `0068`**。

LiteRT / TFLite `c_api.h` 稳定 C ABI 的 FFI 封装（选型理由见 `docs/DECISIONS.md` §1）。`preferred_target = "native"`（native 目标约束见 `docs/DESIGN.md` §7）。

> 门禁（冻结前 P0 实跑，全部 exit 0）：`moon clean` → `moon check --deny-warn` → `moon build` → `moon test`（**21 tests** 全过）→ `moon fmt --check`。本轮**不引入任何外部库**；真实 `libtensorflowlite_c` 对接与数值对齐留待真实库对接阶段（双路径机制见 `docs/DECISIONS.md` §2）。

`close`：**不会二次释放，重复调用返回明确错误**（`AlreadyClosed`）。后端抽象由 `pose::PoseBackend` 承担（本库原 `InferenceRuntime` trait 已于冻结前删除）。

完整文档见项目根目录与 `docs/` 目录：`README.md`、`docs/DESIGN.md`、`docs/API.md`、`docs/DECISIONS.md`（设计决策记录）。

**当前状态：公开面冻结前 P0 整改完成，四道公开面变化（删死接口 / 字段与 shim 私有化 / 文档化追认 / 文档对账）已落地。**
