# hnlyxiaobing/tflite_ffi

> Round-1 · 架构与声明可评审（2026-11-06）。本包只有 4 个 `#external` 句柄、15 个 `extern "C"` shim 声明、值类型与 `declare` 包装 API，**无推理逻辑、无 shim 实现**。`moon check`：0 error，6 × `[0068]`（预期）。

LiteRT / TFLite `c_api.h` 稳定 C ABI 的 FFI 封装（ADR-0008）。`preferred_target = "native"`（ADR-0007）。

> `moon build` / `moon test` 本轮**预期链接期失败**：`mb_tfl_*` shim 尚未实现。

完整文档见同目录 `README.md`、`DESIGN.md`、`API.md`；总体架构与决策见 `../docs/architecture.md`、`../docs/adr/`。

**当前状态：等待评审，不进入实现。**
