# hnlyxiaobing/tflite_ffi

只绑 `c_api.h` 稳定 ABI，把模型字节变成输出张量；无真实库时用内置 stub 保持可验证。

本包是独立发布单元。完整说明（能力边界、公开 API、依赖、验证、风险与未决）见本仓库 `README.md`；公开签名以 `pkg.generated.mbti` 为准。

许可：Apache-2.0。
