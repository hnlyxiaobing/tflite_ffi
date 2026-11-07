# hnlyxiaobing/tflite_ffi

**TensorFlow Lite / LiteRT C API 封装 —— 模型加载、张量读写、invoke 与输出读取的纯推理运行时绑定。**

> 状态：**Round-1 架构与声明可评审**。已写入 `#external` 句柄、`extern "C"` shim 签名、值类型与 `declare` 包装 API，`moon check` 0 error（6 条预期 `0068` 告警）。**无 shim 实现、无推理逻辑**。
> `preferred_target` 本轮由 `wasm` 改为 `native`（唯一配置改动，理由见 ADR-0007）。

## 定位与为什么存在

路线图「拼图三」复核（2026-11-06）：没有 Android/native 的 TFLite 绑定；`mizchi/webnn@0.1.0` 含 LiteRT 解析执行但**仅 js 目标**，`moon-ort@0.1.1`(MIT) 是 ONNX 路线。判定为 **FFI-JNI 封装**（`docs/capability-matrix.md` #10）。

**选型依据（ADR-0008）**：`tensorflow/lite/c/c_api.h` 自述 "useful for shared libraries where having a **stable ABI boundary** is important"，受 TFLite 版本号覆盖；而 `c_api_opaque.h` / Extension APIs 独立版本、保留不兼容变更权利，`c_api_experimental.h` 与 C++ API 不受保证。因此本库**只声明 `c_api.h` 覆盖的能力**，不碰 Extension/opaque/delegate/experimental 符号。

**纠正报告两处**：① `TfLiteInterpreter` **未弃用**（真实弃用是 `TfLiteRegistrationExternal`→`TfLiteOperator`）；② 本库对 `AND-02`（NDK 交叉编译）的依赖由硬降为软——桌面 x86-64 用预编译 `.so` 即可验证，只有上板才需要 `moon_abi`。

## 能力范围 / 非目标

- **做**：模型字节 → model/options/interpreter 句柄；输入张量写入；动态尺寸调整；`allocate_tensors`；`invoke`；输出张量读出；输出张量描述（形状/dtype/字节数）。
- **不做**：图像预处理/后处理、模型下载、模型 zoo、量化决策、GPU/delegate、Extension/opaque API、`foreign_library` 导出。
- 后端可替换：`pose` 持有 `PoseBackend` trait，本库**不依赖 pose**，由组合根适配（ADR-0004）。

## 公开接口（速览）

`Interpreter::{from_bytes, close, set_input, output_raw, invoke, output_desc}`。外部 shim 与外部句柄清单见 `API.md`。

## 依赖

- **本轮零依赖、零 shim 实现**；独立 `moon.mod`，`moon check` 独立通过。
- 后续轮：`libtensorflowlite_c.so`（Android armv7/arm64 + 桌面 x86-64）、`native-stub` C 文件、`link.native` 配置（由 `moon_abi` 生成）。Android 分发可从 Maven `org.tensorflow:tensorflow-lite` AAR 取 `jni/<abi>/libtensorflowlite_jni.so` 与 `headers/tensorflow/lite/c/`。

## 平台与许可风险

- 平台：`preferred_target = "native"`；Linux x86-64 桌面可先验证；Android 上板需 NDK + C stub（native 后端**无法直接导出可链接 `.so`**）。
- 许可：LiteRT C API 头文件 Apache-2.0；**框架 Apache-2.0 ≠ 模型可商用、≠ 预编译 `.so` 可随包分发**。模型（MoveNet Apache-2.0、BlazePose/MediaPipe Apache-2.0）与 TF Hub 托管条款需单独审计（Q4）。
- 风险：`.so` 随包分发 armv7/arm64 两份（约 3–5 MB）；TFLite 版本与 C API 兼容性；量化模型（f16/int8）输出精度；C API 是否覆盖所需算子未验证（Q10）。

## 测试与验收

- **测试策略**：桌面 `.so` 跑 224×224 分类模型，与 Python `tflite-runtime` 逐元素误差 < 1e-4；重复 `close` / 空句柄 / 缓冲长度不足 / status code 非 0 的错误路径；`moon test --enable-coverage`。
- **验收标准**（实现轮）：分类模型跑通且数值对齐；`Interpreter::close` 幂等；所有 C status code 转成 `TfLiteError` 而非 panic。
- **本轮阻塞（预期）**：`moon build` / `moon test` 会在链接期失败——`mb_tfl_*` shim 符号尚无实现。详见 `../docs/moon-check-report.md` §4。

## 当前状态 / 本轮产物

| 项 | 状态 |
|---|---|
| `tflite_ffi.mbt`：`#external` 句柄 ×4、`extern "C"` shim ×15、`declare` API ×6 | ✅ |
| `pkg.generated.mbti` API 快照 | ✅ |
| C shim / `native-stub` / 链接配置 / 模型文件 | ❌ 后续轮 |
| `moon check` | ✅ 0 error（6 × `0068`，预期） |

## 文档索引

`DESIGN.md` · `API.md` · `../docs/architecture.md` §5 · `../docs/adr/ADR-0004`、`ADR-0007`、`ADR-0008`、`ADR-0009`
