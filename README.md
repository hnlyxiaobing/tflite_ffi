# hnlyxiaobing/tflite_ffi

**TensorFlow Lite / LiteRT C API 封装 —— 模型加载、张量读写、invoke 与输出读取的纯推理运行时绑定。**

> 状态（**R4 增量实现轮**，2026-11-09）：**实现完成**——4 个 `#external` 句柄、**17 个包私有 `extern "C"` shim**、值类型与错误模型，MoonBit 侧 **8 个公开方法 + 3 个只读访问器**（R4 新增 `resize_input` / `allocate_tensors`）均为真实实现，由 `stub/mb_tfl_stub.c`（`native-stub`，**CI 默认后端**）提供桌面确定性 C 实现。**无 `declare` 存根、无 `0068`**；五道门禁（`moon clean` / `moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check`）实跑全绿，**48 个测试全过**。
> `preferred_target = "native"`（native 目标选型理由见 `DECISIONS.md` §1）。真实 `libtensorflowlite_c` 对接与数值对齐留待**真实库对接阶段**（stub/real 双路径机制见 `DECISIONS.md` §2），本库不引入任何外部库、不破坏 stub 双路径。

## 定位与为什么存在

2026-11-06 检索 mooncakes.io（生态摸底）：没有 Android/native 的 TFLite 绑定；`mizchi/webnn@0.1.0` 含 LiteRT 解析执行但**仅 js 目标**，`moon-ort@0.1.1`(MIT) 是 ONNX 路线。故本库定位为 **FFI-JNI 封装**（LiteRT / TFLite `c_api.h` 的 MoonBit 绑定；选型背景判定详见 `DECISIONS.md` §1）。

**选型依据（`DECISIONS.md` §1）**：`tensorflow/lite/c/c_api.h` 自述 "useful for shared libraries where having a **stable ABI boundary** is important"，受 TFLite 版本号覆盖；而 `c_api_opaque.h` / Extension APIs 独立版本、保留不兼容变更权利，`c_api_experimental.h` 与 C++ API 不受保证。因此本库**只声明 `c_api.h` 覆盖的能力**，不碰 Extension/opaque/delegate/experimental 符号。

**两处早期口径纠正**：① `TfLiteInterpreter` **未弃用**（真实弃用是 `TfLiteRegistrationExternal`→`TfLiteOperator`）；② 本库对 NDK 交叉编译的依赖由硬降为软——桌面 x86-64 用预编译 `.so` 即可验证，只有上板才需要 `moon_abi`。

## 能力范围 / 非目标

- **做**：模型字节 → model/options/interpreter 句柄；输入张量写入；`invoke`；输出张量读出；输出张量描述（形状/dtype/字节数/量化/名称）；动态形状（`resize_input` → `allocate_tensors`）。C shim 层 `mb_tfl_resize_input` / `mb_tfl_allocate_tensors` 自 R4 起由公开方法调用（绑定名去掉历史 `_` 前缀）。
- **不做**：图像预处理/后处理、模型下载、模型 zoo、量化决策、GPU/delegate、Extension/opaque API、`foreign_library` 导出。
- 后端可替换：`pose` 持有 `PoseBackend` trait，本库**不依赖 pose**，由组合根适配（`DECISIONS.md` §6）。
  **冻结前 P0（决策 2）**：本库原 `pub(open) trait InferenceRuntime` 已删除（唯一消费者是测试替身），后端抽象统一由 `pose::PoseBackend` 承担。

## 公开接口（速览）

- 方法：`Interpreter::{from_bytes, close, set_input, output_raw, invoke, output_desc}`（签名冻结，全部真实实现）。
- 只读访问器（冻结前 P0 新增，决策 5 的配套）：`Interpreter::{state, input_count, output_count}`。
- `Interpreter` 为**抽象类型**（字段全私有：MoonBit 无字段级可见性修饰符，`pub(all)` 会公开 `mut state`，`pub` 实测仍可包外读字段，故整体收紧）；外部 shim 与句柄清单见 `API.md`。
- 错误：`TfLiteError` 为 `pub(all) suberror`（13 个构造，含 `NullHandle`），冻结前已追认（见 `API.md`「冻结前追认记录」）。

## 依赖

- **本轮零外部依赖**：只有项目内 `stub/mb_tfl_stub.c`（`moon.pkg` 的 `native-stub`），不链接/下载任何外部库。
- 真实库对接阶段起：`libtensorflowlite_c.so`（Android armv7/arm64 + 桌面 x86-64）经运行时动态加载接入（`DECISIONS.md` §2），`link.native` 配置（由 `moon_abi` 生成）。Android 分发可从 Maven `org.tensorflow:tensorflow-lite` AAR 取 `jni/<abi>/libtensorflowlite_jni.so` 与 `headers/tensorflow/lite/c/`。

## 平台与许可风险

- 平台：`preferred_target = "native"`；Linux x86-64 桌面可先验证；Android 上板需 NDK + C stub（native 后端**无法直接导出可链接 `.so`**）。
- 许可：LiteRT C API 头文件 Apache-2.0；**框架 Apache-2.0 ≠ 模型可商用、≠ 预编译 `.so` 可随包分发**。模型（MoveNet Apache-2.0、BlazePose/MediaPipe Apache-2.0）与 TF Hub 托管条款已单独审计（Q4：模型商用条款，事实层见 `LICENSE-AUDIT-Q4.md`，红线与解禁语义见其 §0.1、`DECISIONS.md` §3）。
- 风险：`.so` 随包分发 armv7/arm64 两份（约 3–5 MB）；TFLite 版本与 C API 兼容性；量化模型（f16/int8）输出精度；C API 是否覆盖所需算子未验证（算子覆盖开放项）。

## 测试与验收

- **stub 后端（P0 整改轮基线）**：21 个测试（12 黑盒 + 9 白盒）覆盖全链路、错误映射、状态机、dtype/版本断言与 shim 语义。
- **双路径落地后**：34 个测试全过（含后端场景测试与 golden tflite 类数值黄金）+ 2 个 `golden real` 类 `#skip` 用例在无真实库时 SKIPPED 不计通过（fail-closed，见 `tests/fixtures/golden/ASSETS.md` §4）。
- **R4（2026-11-09，当前）**：**48 个测试全过** = 双路径 34 + `resize_allocate_test.mbt` 8 + `q10_coverage_test.mbt` 6；另 2 个 `golden real` 仍按真实库就位情况 SKIPPED/联跑。真实库获取结果见 `GAPS.md`，Q10 矩阵见 `Q10-OPERATOR-COVERAGE.md`。
- **真实库对接目标**：桌面 `.so` 跑 224×224 分类模型，与 Python `tflite-runtime` 逐元素误差 < 1e-4；重复 `close` / 空句柄 / 缓冲长度不足 / status code 非 0 的错误路径；`moon test --enable-coverage`。
- **验收标准**：分类模型跑通且数值对齐；`Interpreter::close` **不会二次释放，重复调用返回明确错误**；所有 C status code 转成 `TfLiteError` 而非 panic（✅ stub 下已达成）。
- **门禁**：五项门禁 P0 整改轮实跑全部 exit 0（明细见 `API.md` 末节）。

## 当前状态 / 产物

| 项 | 状态 |
|---|---|
| `tflite_ffi.mbt`：`#external` 句柄 ×4、**包私有** `extern "C"` shim ×17、值类型/错误模型 | ✅ |
| `interpreter.mbt`：8 个公开方法 + 3 个只读访问器（真实实现，无 `declare`；R4 新增 resize/allocate） | ✅ |
| `stub/mb_tfl_stub.c`：17 个 `mb_tfl_*` 确定性 C 实现 + 4 个私有内部 ABI 符号 | ✅ |
| `pkg.generated.mbti` API 快照 | ✅ 由 `moon check`/`moon build` 自动同步（未手工编辑快照，审阅由维护流程统一执行） |
| stub/real 双路径切换层（`native/mb_tfl_dispatch.c` 等） | ✅（`DECISIONS.md` §2） |
| 真实 `libtensorflowlite_c` 链接 / 数值对齐 / 上板 | ⏳ 真实库对接阶段（缺口登记见 `GAPS.md`） |
| 五道门禁（clean / check --deny-warn / build / test / fmt --check） | ✅ 全绿（P0 整改轮 21/21；双路径后 34/34；R4 48/48 + 2 golden real SKIPPED） |

## 冻结前 P0 变更摘要（API 冻结前准备）

1. **删除 `InferenceRuntime` trait**（决策 2）及其外部实现测试；`Interpreter` 公开方法零变化。
2. **`Interpreter` 字段整体收紧为包私有**（决策 5）+ 3 个只读访问器；黑盒测试改经访问器读 `state`/`input_count`/`output_count`。
3. **追认**（决策 4，加法性，已在 `API.md` 标注）：`TfLiteError` `pub(all) suberror`、`NullHandle` 构造器、`TensorDtype::Int64`——源码现状已符合。
4. **17 个 `mb_tfl_*` shim 由 `pub` 收敛为包私有**（决策 6），不再进 `moon info` 快照；直接调用它们的 4 个黑盒测试迁入白盒。
5. **API.md shim 数量 15 → 17**（决策 9，按源码/快照修正）。
6. **close 语义三处文档统一**（决策 8）：「不会二次释放，重复调用返回明确错误」。

### 测试数变化明细（P0 整改前基线 23 → 整改后 21）

| 变化 | 数量 | 用例 |
|---|---|---|
| 删除（决策 2） | −1 | `blackbox InferenceRuntime trait is implementable outside the package`（连同 `RuntimeAdapter` 结构与 2 个 `impl` 一起删除） |
| 删除（shim 私有化后的重复覆盖） | −1 | `blackbox capi version is stable`——与白盒 `wb expected_capi_version matches shim` 断言完全等价（`expected_capi_version == mb_tfl_capi_version() == 0x00010001`），且黑盒已无法调用私有 shim |
| 黑盒 → 白盒迁移（0 净变化） | ±4 | `resize_input and allocate_tensors flow` / `ops before allocate after resize fail` / `allocate_tensors fails on rank conflict` / `resize_input rejects invalid dims`（shim 私有化后黑盒不可直调；迁移时按白盒惯例复制 STF1 夹具辅助） |
| 最终 | **21** | 12 黑盒 + 9 白盒（`moon test`：`Total tests: 21, passed: 21, failed: 0`） |

### R4 测试增量（21 → 48；基线 34 → 48）

| 变化 | 数量 | 用例文件 |
|---|---|---|
| 双路径落地（R3 基线） | +13 | 后端场景（10）、golden tflite 类（3）等；`Total tests: 34` |
| R4 resize/allocate 公开面 | +8 | `resize_allocate_test.mbt`：resize→allocate 全链路、未 allocate 的 2（NOT_ALLOCATED）、分配前后尺寸不匹配、负/零/空/rank>8、越界 index、close 后、rank 冲突、幂等 allocate |
| R4 Q10 算子矩阵 | +6 | `q10_coverage_test.mbt`：TFL3 算子枚举、矩阵 pending 状态、stub 拒 TFL3、6 dtype、未知 dtype、STF1 无算子表 |
| 当前 | **48** | `moon test`：`Total tests: 48, passed: 48, failed: 0`；另 2 个 `golden real` `#skip` |

## 文档索引

`DECISIONS.md`（设计决策记录）· `DESIGN.md` · `API.md` · `README.mbt.md` · `GAPS.md`（缺口台账）· `Q10-OPERATOR-COVERAGE.md`（Q10 算子覆盖矩阵）· `POSIX-REVIEW.md`（POSIX dlopen 走查与 WSL 实跑）· `LICENSE-AUDIT-Q4.md`（许可审计）· `stub/README.md`（STF1 格式）· `tests/fixtures/golden/ASSETS.md` / `tests/fixtures/micro/ASSETS.md`（数值黄金与模型资产登记）
