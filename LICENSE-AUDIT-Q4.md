# LICENSE-AUDIT-Q4.md — TFLite/LiteRT 运行时与模型生态商用条款审计（Q4，网络只读）

> 日期：**2026-11-08**（R3·WP-6）｜ 审计方式：**网络只读**——全程仅用 `web_fetch` 读取 LICENSE / 条款 / 托管元数据**文本**；**未下载任何 `.so` / 模型（`.tflite`/`.task`）/ frida 二进制，未把任何下载物落盘进工作区**，本文件为唯一产出 `[已复验]`。
> 证据等级（本轮口径）：网络文本审计结论一律 **`[仅据文档]`**（每条附 URL + 文本摘录 + 访问日期 **2026-11-08**）；本轮本地实测行为 `[已复验]`；法律解读一律 `[推断]`（**非法律意见**，须法务复核）；未核实处 `[仍需实测]` **如实标开放，不硬凑**。
> 范围边界：本审计只固定「许可/条款原文事实 + 合规含义」，**不改变任何门禁与红线**（`.workbuddy/contracts/wp1-contract.md` §5 红线、ADR-0008、`docs/roadmap-v2.md` §3 解禁表均维持原状）。
> 关联：`docs/open-questions.md` Q4、`docs/roadmap-v2.md` §2/§3、`docs/research-and-verification.md` §2.3（R22/R23/R24）。

---

## 0. 审计对象与红线执行声明

| 项 | 内容 | 等级 |
|---|---|---|
| 运行时对象 | TFLite/LiteRT C API 运行时（`libtensorflowlite_c.so` / `tensorflowlite_c.dll`，稳定面 = `tensorflow/lite/c/c_api.h`） | `[仅据文档]`（下文 §1） |
| 模型对象 | MoveNet（SinglePose/MultiPose）、BlazePose / MediaPipe Pose（Landmarker） | `[仅据文档]`（下文 §2） |
| 红线执行 | 仅 `web_fetch` 文本读取；MoveNet Model Card **PDF** 因 content-type（`application/pdf`）被 `web_fetch` 拒绝，**未改用任何下载通道绕过**；`dl.google.com` 的 `.pom` 因 `application/octet-stream` 被拒同样未绕过 | `[已复验]` |
| 产出物 | 仅本文件；工作区无任何新增二进制/模型 | `[已复验]` |

---

## 1. 运行时：Apache-2.0 许可审计

### 1.1 许可归属与文本事实（来源登记）

| 对象 | 来源 URL | 摘录 / 事实 | 访问日期 | 等级 |
|---|---|---|---|---|
| TensorFlow 仓库根 `LICENSE` | `https://raw.githubusercontent.com/tensorflow/tensorflow/master/LICENSE` | "Apache License / Version 2.0, January 2004" 标准全文；**文末追加**："## Some of TensorFlow's code is derived from Caffe, which is subject to the following copyright notice: … Copyright (c) 2014, The Regents of the University of California …"（BSD-3-Clause 式条款） | 2026-11-08 | `[仅据文档]` |
| TensorFlow 仓库根 `NOTICE` | `https://raw.githubusercontent.com/tensorflow/tensorflow/master/NOTICE` | **HTTP 404（不存在 NOTICE 文件）** | 2026-11-08 | `[仅据文档]` |
| LiteRT 仓库 `LICENSE` | `https://raw.githubusercontent.com/google-ai-edge/LiteRT/main/LICENSE` | 纯 Apache-2.0 标准全文，**无任何附加声明** | 2026-11-08 | `[仅据文档]` |
| `tensorflow/lite/c/c_api.h` 头部 | `https://raw.githubusercontent.com/tensorflow/tensorflow/master/tensorflow/lite/c/c_api.h` | "/* Copyright 2020 The TensorFlow Authors. All Rights Reserved. / Licensed under the Apache License, Version 2.0 (the "License")…"；另证实现存弃用为 `TfLiteRegistrationExternal`→`TfLiteOperator`（与 R1 调研一致） | 2026-11-08 | `[仅据文档]` |
| MediaPipe 仓库 `LICENSE`（模型生态代码，供 §2 对照） | `https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/LICENSE` | Apache-2.0 全文 + **文末追加**："For files under tasks/cc/text/language_detector/custom_ops/utils/utf/ … Copyright (c) 2002 by Lucent Technologies. Permission to use, copy, modify, and distribute this software … provided that this entire notice is included in all copies …" | 2026-11-08 | `[仅据文档]` |

**结论（运行时本体）**：TFLite/LiteRT 运行时 = **Apache License 2.0**（SPDX: `Apache-2.0`）；归属 = The TensorFlow Authors / Google（`c_api.h` 版权行 "Copyright 2020 The TensorFlow Authors"）`[仅据文档]`。

### 1.2 Apache-2.0 条款要点与义务（逐条）

摘录均出自上述 tensorflow `LICENSE` 全文（2026-11-08 访问）`[仅据文档]`：

| # | 条款 | 原文摘录 | 对本项目的义务/含义 | 等级 |
|---|---|---|---|---|
| A1 | §2 版权授予 | "perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and **distribute** the Work … in Source or Object form" | **商业使用与（再）分发（含二进制）被明示授予**，无 field-of-use 限制 | `[仅据文档]` |
| A2 | §3 专利授予 | "… patent license to make, have made, use, offer to sell, sell, import …"; 专利诉讼终止条款 | 含专利授权（对运行时是重要利好）；发起专利诉讼则授权终止 | `[仅据文档]` |
| A3 | §4(a) | "You must give any other recipients of the Work or Derivative Works **a copy of this License**" | 随二进制分发（如最终 App 随包 `.so`）必须附 Apache-2.0 许可副本 | `[仅据文档]` |
| A4 | §4(b) | "You must cause any **modified files to carry prominent notices** stating that You changed the files" | 若改 shim/内核源码须显著标注修改（本项目仅做 FFI 绑定，预期不改上游源码） | `[仅据文档]` |
| A5 | §4(c) | "You must **retain** … all copyright, patent, trademark, and **attribution notices** from the Source form of the Work" | 保留上游版权/归属声明 | `[仅据文档]` |
| A6 | §4(d) | "If the Work includes a "**NOTICE**" text file … any Derivative Works that You distribute must include a readable copy of the attribution notices contained within such NOTICE file …" | **条件性义务**：上游根目录无 NOTICE（404，见 §1.1）→ 本条当前**无触发对象**；审慎做法仍是随包附 LICENSE 全文 | `[仅据文档]` |
| A7 | **LICENSE 附录 Caffe BSD**（§4(c)/BSD 联动） | "Some of TensorFlow's code is derived from Caffe … 2. Redistributions **in binary form must reproduce** the above copyright notice, this list of conditions and the following disclaimer **in the documentation and/or other materials** provided with the distribution." | **实质 NOTICE 等价义务**：二进制再分发（预编译 `.so`/AAR 进最终 App）须随附 Caffe 版权声明与免责声明——这是运行时分发最易遗漏的义务 | `[仅据文档]` |
| A8 | §6 商标 | "This License does not grant permission to use the trade names, trademarks, service marks, or product names of the Licensor, except as required for reasonable and customary use in describing the origin of the Work" | "TensorFlow / LiteRT / TFLite" 名称**不随许可授权**，仅可作来源描述的合理使用；产品命名需注意 | `[仅据文档]` |
| A9 | §7/§8 免责 | "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND | 无担保、无责任上限——商用自担风险 | `[仅据文档]` |

> **义务触发点**：A3–A7 均以 **reproduction/distribution（分发）** 为触发；仅本地构建/链接/使用（"use"，§2 授予无条件）不触发。这直接支撑 §3 的分发口径。

### 1.3 LiteRT 更名沿革

| 事实 | 证据（URL + 摘录，2026-11-08） | 等级 |
|---|---|---|
| LiteRT 承接 TFLite 血缘 | `https://raw.githubusercontent.com/google-ai-edge/LiteRT/main/README.md`："**LiteRT continues the legacy of TensorFlow Lite** as the trusted, high-performance runtime for on-device AI." | `[仅据文档]` |
| TFLite 老命名进入维护模式 | 同上："**TensorFlow Lite packages and `tensorflow/lite/` are in maintenance mode** and only receive critical security and stability updates."（另见其 "AI Coding Directives" 建议新代码用 Compiled Model API） | `[仅据文档]` |
| 许可随更名不变 | 同上文末："LiteRT is licensed under the [Apache-2.0 License](LICENSE)."（LICENSE 即 §1.1 纯 Apache-2.0） | `[仅据文档]` |
| 产物坐标沿革 | Maven Central `org.tensorflow:tensorflow-lite`（AAR，见 §1.4）→ Google Maven `com.google.ai.edge.litert:litert`（`https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/litert/maven-metadata.xml`：`<latest>2.3.2</latest>`、版本序列 `0.1.0 … 2.3.2`、`<lastUpdated>20261026204500</lastUpdated>`） | `[仅据文档]` |
| **更名公告的精确日期** | ai.google.dev / developers.googleblog 本轮抓取失败（网络不可达） | `[仍需实测]` |

**含义**：更名是产品/仓库/坐标层面的沿革，**许可连续性成立**（同一 Apache-2.0、同一代码血缘）；本项目锁的 `c_api.h`（`TfLite*` 符号）位于 `tensorflow/lite/`（维护模式但仍是稳定 ABI 面，R1 调研 R22 口径不变）`[推断]`。

### 1.4 官方预编译产物 vs 源码构建：许可一致性

| 路径 | 证据（URL + 摘录，2026-11-08） | 许可 | 等级 |
|---|---|---|---|
| **预编译**（官方 Maven 产物） | `https://repo1.maven.org/maven2/org/tensorflow/tensorflow-lite/2.14.0/tensorflow-lite-2.14.0.pom`：`<packaging>aar</packaging>`、`<licenses><license><name>The Apache Software License, Version 2.0</name><url>http://www.apache.org/licenses/LICENSE-2.0.txt</url></license></licenses>`、scm 指向 `github.com/tensorflow/tensorflow` | **Apache-2.0** | `[仅据文档]` |
| **源码构建**（同一上游树） | tensorflow 根 `LICENSE` = Apache-2.0（§1.1）；LiteRT README "### 🔨 Building from Source — You can build LiteRT artifacts for Linux and Android (via cross-compilation) using Docker … CMake Build Instructions … Bazel Build Instructions"（源码即同一 Apache-2.0 树的构建入口） | **Apache-2.0** | `[仅据文档]` |
| 新坐标 AAR 许可字段 | `com.google.ai.edge.litert:litert` 的 `.pom` 以 `application/octet-stream` 返回、`web_fetch` 拒读；AAR 内容禁下载（红线） | 该字段 `[仍需实测]`（`[推断]` 按同仓 LICENSE 为 Apache-2.0，方向无悬念） | `[仍需实测]` |
| 预编译产物内第三方声明 | AAR/`.so` 是否附 NOTICE/XNNPack 等组件清单——二进制禁下载故未核 | `[仍需实测]` | `[仍需实测]` |

**一致性结论**：官方预编译产物与源码构建**许可一致，均为 Apache-2.0**；预编译不是独立许可的分发物，而是同一许可代码的编译产物 `[仅据文档]` + `[推断]`。两条路径的分发义务相同：附许可副本（A3）+ 保留归属（A5）+ **Caffe BSD 声明再生产（A7）**；无根级 NOTICE（A6 无触发对象）。

---

## 2. 模型生态：商用条款审计（MoveNet / BlazePose / MediaPipe）

> 获取通道说明：TF Hub 已迁移 Kaggle Models——`https://tfhub.dev/google/movenet/singlepose/lightning/4` 返回「cross-origin redirect to https://www.kaggle.com」`[已复验]`（本轮实测）。模型卡文本经 **Kaggle 模型列表 API**（官方托管元数据）读取，其 `provenanceSources` 字段指向 `https://github.com/tensorflow/tfhub.dev/tree/master/assets/docs/google`（TF Hub 文档库），文本等价于 TF Hub 页面所载模型卡。

### 2.1 MoveNet

| # | 结论 | 证据（URL + 摘录，2026-11-08） | 等级 |
|---|---|---|---|
| M1 | **许可 = Apache-2.0（已核实）** | `https://www.kaggle.com/api/v1/models/list?search=movenet`（`google/movenet`，publishTime 2021-04-01）：各实例 `"licenseName":"Apache 2.0"`；模型卡 "## License — **This model follows [*Apache 2.0*](https://www.apache.org/licenses/LICENSE-2.0).** If you intend to use it beyond permissible usage, please consult with the model owners ahead of time." | `[仅据文档]` |
| M2 | **"surveillance out of scope" 使用范围声明确实存在（此前 Q4「范围声明未证实」的文本存在性已证实）** | 同上，模型卡 "### Out-of-scope Use Cases — … **Any form of surveillance or identity recognition is explicitly out of scope and not enabled by this technology.** The model does not store/use/send any information in the input images at inference time."（SinglePose lightning/thunder 与 MultiPose 卡面均载） | `[仅据文档]` |
| M3 | 预期用途含体感/健身/AR 娱乐 | 同上："### Primary Intended Users — People who build applications (e.g. **fitness/physical movement, AR entertainment**) that require very fast inference and good quality single-person pose detection … on standard consumer devices" | `[仅据文档]` |
| M4 | 17 关键点（与 ADR-0008 第一轮口径一致） | 同上："The model predicts **17 human keypoints** of the full body even when they are occluded."；Lightning 输入 `192x192x3`、输出 float32 `[1,1,17,3]` | `[仅据文档]` |
| M5 | **声明的法律约束力未定（Q4 核心残余）** | `[推断]`：Apache-2.0 本身无 use-scope 限制（§2 授予）；"Out-of-scope Use Cases" 位于模型卡 Intended Use 章节，是**使用范围声明**而非许可证条件；"beyond permissible usage 请咨询 model owners" 的 "permissible usage" 指涉（= Apache-2.0？= 卡面范围？）存在语义歧义。**是否构成合同性约束须法务裁定** | `[仍需实测]`（法务） |
| M6 | Model Card **PDF** 逐字内容 | `https://storage.googleapis.com/movenet/MoveNet.SinglePose%20Model%20Card.pdf` 返回 `application/pdf`、`web_fetch` 拒读；按红线未下载。上述 M1–M4 来自官方托管元数据的等价卡面文本 | `[仍需实测]`（PDF 本体）/ `[仅据文档]`（等价文本） |

### 2.2 BlazePose / MediaPipe（Pose）

| # | 结论 | 证据（URL + 摘录，2026-11-08） | 等级 |
|---|---|---|---|
| B1 | **BlazePose 模型许可 = Apache-2.0（托管元数据）** | `https://www.kaggle.com/api/v1/models/list?search=blazepose`（`mediapipe/blazepose`、`mediapipe/blazepose-3d`，publishTime 2021-05-19 / 2021-08-23）：全部实例（detector、landmark-lite/full/heavy）`"licenseName":"Apache 2.0"` | `[仅据文档]` |
| B2 | 33 点 / GHUM 3D（与 Q8 联动） | 同上："BlazePose topology contains **33 points** extending 17 points by COCO … vital for practical applications like **fitness, yoga and dance**"；blazepose-3d："BlazePose GHUM 3D … infers **33 3D landmarks** of a body from a single frame as well as a body segmentation mask" | `[仅据文档]` |
| B3 | **BlazePose 卡面未见 surveillance 类使用范围声明** | 同上可读文本（描述 + 各实例 usage）中**未出现** Out-of-scope/surveillance 字样。**如实标注：该声明仅在 MoveNet 卡面证实存在（M2），不得向 BlazePose 套用；"未见"≠"不存在"** | `[仅据文档]`（未见事实）/ `[仍需实测]`（是否存在） |
| B4 | MediaPipe 代码许可 = Apache-2.0 + Lucent 附录 | `https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/LICENSE`：Apache-2.0 全文 + utf（Rob Pike / Ken Thompson，Lucent 2002）许可："provided that this **entire notice is included in all copies** of any software which is or includes a copy or modification of this software"（若分发含该组件的二进制须整体保留该声明） | `[仅据文档]` |
| B5 | **MediaPipe Tasks 隐私/告知义务（应用侧新增登记项）** | `https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/README.md`（Privacy Notice，Last modified: June 5, 2026）："processing of the input data … takes place on device, and MediaPipe does not send that input data to Google servers"；但 "**MediaPipe Tasks APIs send metrics about the performance and utilization of the APIs in your app to Google**"；"**You are responsible for obtaining informed consent from your app users** about Google's processing of MediaPipe metrics data as required by applicable law." | `[仅据文档]` |
| B6 | MediaPipe Tasks 模型（`pose_landmarker*.task`）的独立模型卡/条款 | developers.google.com / ai.google.dev 本轮抓取失败（网络不可达）；storage.googleapis.com 仅托管二进制（禁下载） | `[仍需实测]` |

### 2.3 托管条款（TF Hub / Kaggle）

| # | 结论 | 证据（2026-11-08） | 等级 |
|---|---|---|---|
| H1 | TF Hub 托管已迁移 Kaggle Models | `https://tfhub.dev/google/movenet/singlepose/lightning/4` → 「cross-origin redirect to https://www.kaggle.com」`[已复验]`；Kaggle API 元数据 `"provenanceSources":"https://github.com/tensorflow/tfhub.dev/tree/master/assets/docs/google"` `[仅据文档]` | `[已复验]`/`[仅据文档]` |
| H2 | **托管条款（Kaggle Terms of Use）文本本轮不可读** | `https://www.kaggle.com/terms` 返回 JS 壳（"Terms of Use | Kaggle"），无可引用正文 | `[仍需实测]` |
| H3 | 托管条款与模型许可的关系 | `[推断]`：托管条款约束的是托管服务/下载行为，不改变模型许可本体；商用条款的直接依据 = 发布者声明的 `licenseName` + 模型卡正文（M1/B1） | `[推断]` |

---

## 3. 分发口径结论

### 3.1 真实 `.so` / 模型「禁入库」红线的许可依据

**一句话**：Apache-2.0 **不禁止**商用与再分发（A1），所以禁入库红线不是「许可不允许」，而是**义务触发点控制 + 来源可追溯 + 不明许可零持有**的工程纪律 `[推断]`：

1. **义务触发点控制**：入库并随仓库/构建产物传播即构成 "distribute"，A3（许可副本）/A5（归属保留）/A7（Caffe BSD 声明再生产）义务立即对我方触发且面扩大（仓库、fixture、黄金目录全成"分发物"）；禁入库把义务触发点**收敛到最终 App 分发这一个可控环节**。
2. **来源可追溯**：第三方构建/镜像的 `.so` 可能混入其它许可组件（教训同 frida Q2：devkit 打包组件需逐项核对）；不持有实物、只登记哈希与来源，可审计且可逆。
3. **不明许可零持有**：第三方模型/目标游戏 APK 判例（`docs/open-questions.md` §2.1「许可不明禁止入库」）一致适用于 MoveNet 等实物模型——许可虽已核为 Apache-2.0，红线维持不放宽（冻结口径不破坏）。
4. 与 `.workbuddy/contracts/wp1-contract.md` §5（"真实 `libtensorflowlite_c` 任何形态、真实第三方模型禁入库；唯一允许 = 本地链接 + SHA-256 记录"）及 **ADR-0011 / `docs/unblock-template.md`** 的许可口径（禁入库 + 本地链接 + SHA-256 + fail-closed）**一致，红线不变**；本审计即 ADR-0011 §「Q4 审计引用」所指定的 Q4 事实层产出。

### 3.2 「本地链接 + SHA-256」形态的合规性论证

形态（WP-1 契约 §1/§3）：库/模型由开发者**本地获取**（`MB_TFLITE_LIB_PATH` → `.local/tflite/<platform>/` 缓存 → SDK/Gradle 缓存探测），仓库只存**文本**（`PROVENANCE.md`/`SHA256SUMS.txt`/`GAPS.md`）与脚本（`tools/get-tflite.ps1`、`tools/gen-micro-model.ps1`）。

| # | 论点 | 结论 | 等级 |
|---|---|---|---|
| D1 | 仓库分发物 = 自有源码 + 文档（自有 Apache-2.0），不含第三方二进制 | 仓库层面 Apache-2.0 §4 义务**无触发对象**，无随附声明义务被违反的面 | `[推断]` |
| D2 | 本地链接发生在开发者机器 | 属 §2 "use" 授予（无条件），不触发 §4 分发义务 | `[推断]`（A1 `[仅据文档]`） |
| D3 | SHA-256 + PROVENANCE 登记 | 将来最终 App 分发时可**确定**义务对应的确切产物（版本/来源/哈希），届时履行 A3+A5+A7 即可闭环；缺 PROVENANCE 的本地库不得进 real 路径验收（建议写入 get-tflite 验收口径） | `[推断]` |
| D4 | 自产微型模型（WP-1 D3 零入库，程序化生成、CC0/Apache-2.0 自标注） | 不引入任何第三方模型条款，STF1/TFL3 双格式生成器本身即合规凭证 | `[已复验]`（契约事实）/`[推断]`（许可含义） |
| D5 | 与 Q1 判例一致性 | 目标游戏 APK「仅哈希 + 黄金、二进制不入库」的既有口径与本形态同构，无口径冲突 | `[已复验]`（`docs/open-questions.md` §2.1） |

### 3.3 模型商用条款对「应用侧（体感游戏）」落地的影响登记

| 影响面 | 登记 | 等级 |
|---|---|---|
| 用途匹配 | 体感健身/舞蹈游戏属 MoveNet 卡面预期用途（"fitness/physical movement, AR entertainment"，M3）与 BlazePose 卡面（"fitness, yoga and dance"，B2）→ 商用落地**方向无阻碍** | `[仅据文档]` |
| surveillance 声明 | 体感游戏不涉监控/身份识别 → MoveNet 的 out-of-scope 声明不构成实际阻碍 `[推断]`；但其**法律约束力**未裁定（M5，Q4 核心残余），落地前须法务闭环 | `[推断]`/`[仍需实测]` |
| "beyond permissible usage 请咨询" | 若用法超出 Apache-2.0（如商标性使用、超卡面范围用途）需事先咨询 model owners（M1）；体感游戏本体不触发 `[推断]` | `[仅据文档]`/`[推断]` |
| 17 vs 33 点 | 第一轮 MoveNet 17 点（ADR-0008）不受影响；若 Q8 升 33 点换 BlazePose，模型许可同为 Apache-2.0，但 **MediaPipe Tasks 模型条款（B6）与 Privacy Notice（B5）随入** | `[仅据文档]` |
| 隐私/告知义务 | 纯 `tflite_ffi` + MoveNet 路径**无** metrics 上报义务；若走 MediaPipe Tasks 路径，须按 Privacy Notice 向用户告知并取得知情同意（B5）——**应用侧合规待办，登记在案** | `[仅据文档]` |
| 最终分发义务 | App 随包 `.so` + `.tflite` 时履行：Apache-2.0 许可副本 + 版权/归属声明 + **Caffe BSD 声明**（A3/A5/A7）+ 若含 MediaPipe 组件则 Lucent utf 声明（B4）；产品命名避免商标性使用 "TensorFlow/LiteRT"（A8） | `[推断]` |

---

## 4. 逐条结论总表（证据 URL + 摘录 + 等级）

| # | 结论 | 证据 URL | 关键摘录 | 访问日期 | 等级 |
|---|---|---|---|---|---|
| C1 | TFLite/LiteRT 运行时 = Apache-2.0 | `https://raw.githubusercontent.com/tensorflow/tensorflow/master/LICENSE`；`https://raw.githubusercontent.com/google-ai-edge/LiteRT/main/LICENSE` | "Apache License / Version 2.0, January 2004"；LiteRT README "licensed under the Apache-2.0 License" | 2026-11-08 | `[仅据文档]` |
| C2 | 归属声明 | `https://raw.githubusercontent.com/tensorflow/tensorflow/master/tensorflow/lite/c/c_api.h` | "Copyright 2020 The TensorFlow Authors. All Rights Reserved." | 2026-11-08 | `[仅据文档]` |
| C3 | 义务：许可副本 + 修改标注 + 归属保留 + NOTICE（条件性） | 同 C1（§4 a–d） | "give any other recipients … a copy of this License"；"modified files to carry prominent notices"；"retain … attribution notices"；"If the Work includes a NOTICE text file …" | 2026-11-08 | `[仅据文档]` |
| C4 | 上游无根级 NOTICE 文件（§4(d) 无触发对象） | `https://raw.githubusercontent.com/tensorflow/tensorflow/master/NOTICE` | HTTP **404: Not Found** | 2026-11-08 | `[仅据文档]` |
| C5 | **二进制再分发须再生产 Caffe BSD 声明** | `https://raw.githubusercontent.com/tensorflow/tensorflow/master/LICENSE`（文末附录） | "Some of TensorFlow's code is derived from Caffe … Redistributions in binary form must reproduce the above copyright notice … in the documentation and/or other materials" | 2026-11-08 | `[仅据文档]` |
| C6 | 商标不授权 | 同 C1（§6） | "does not grant permission to use the trade names, trademarks … except as required for reasonable and customary use in describing the origin of the Work" | 2026-11-08 | `[仅据文档]` |
| C7 | LiteRT = TFLite 更名沿革；`tensorflow/lite/` 维护模式 | `https://raw.githubusercontent.com/google-ai-edge/LiteRT/main/README.md` | "LiteRT continues the legacy of TensorFlow Lite …"；"TensorFlow Lite packages and `tensorflow/lite/` are in maintenance mode and only receive critical security and stability updates" | 2026-11-08 | `[仅据文档]` |
| C8 | 预编译产物许可 = Apache-2.0（与源码一致） | `https://repo1.maven.org/maven2/org/tensorflow/tensorflow-lite/2.14.0/tensorflow-lite-2.14.0.pom` | `<name>The Apache Software License, Version 2.0</name>`（artifact `org.tensorflow:tensorflow-lite`，aar） | 2026-11-08 | `[仅据文档]` |
| C9 | 新坐标沿革 org.tensorflow → com.google.ai.edge.litert | `https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/litert/maven-metadata.xml` | `<groupId>com.google.ai.edge.litert</groupId><artifactId>litert</artifactId>`、`<latest>2.3.2</latest>` | 2026-11-08 | `[仅据文档]` |
| C10 | MoveNet = Apache-2.0（模型卡 License 节 + 托管 licenseName） | `https://www.kaggle.com/api/v1/models/list?search=movenet` | "This model follows [*Apache 2.0*] … If you intend to use it beyond permissible usage, please consult with the model owners ahead of time."；`"licenseName":"Apache 2.0"` | 2026-11-08 | `[仅据文档]` |
| C11 | **MoveNet "surveillance … out of scope" 声明文本已证实存在** | 同 C10 | "Any form of surveillance or identity recognition is explicitly out of scope and not enabled by this technology." | 2026-11-08 | `[仅据文档]` |
| C12 | BlazePose（blazepose / blazepose-3d）= Apache-2.0（托管 licenseName） | `https://www.kaggle.com/api/v1/models/list?search=blazepose` | `"licenseName":"Apache 2.0"`（全部实例）；"33 points extending 17 points by COCO … fitness, yoga and dance" | 2026-11-08 | `[仅据文档]` |
| C13 | BlazePose 卡面未见 surveillance 声明（不得套用 MoveNet 结论） | 同 C12 | 可读文本无 Out-of-scope/surveillance 字样（"未见"事实） | 2026-11-08 | `[仅据文档]`（未见）/`[仍需实测]`（是否存在） |
| C14 | MediaPipe 代码 = Apache-2.0 + Lucent utf 附录（整体声明随附义务） | `https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/LICENSE` | "provided that this entire notice is included in all copies of any software which is or includes a copy or modification of this software" | 2026-11-08 | `[仅据文档]` |
| C15 | MediaPipe Tasks metrics 上报 + 告知/同意责任在应用侧 | `https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/README.md` | "MediaPipe Tasks APIs send metrics … to Google"；"You are responsible for obtaining informed consent from your app users …" | 2026-11-08 | `[仅据文档]` |
| C16 | TF Hub 托管迁移 Kaggle | `https://tfhub.dev/google/movenet/singlepose/lightning/4` | "cross-origin redirect to https://www.kaggle.com" | 2026-11-08 | `[已复验]`（本轮实测重定向） |
| C17 | 本地链接+SHA-256 形态合规（仓库分发面无第三方义务触发） | 本文件 §3.2（论证）；WP-1 契约 §1/§5（形态事实） | — | 2026-11-08 | `[推断]`（法律解读） |

---

## 5. 仍开放项（如实登记，不硬凑）

| # | 开放项 | 为什么本轮无法闭环 | 归属 |
|---|---|---|---|
| O1 | **模型卡使用范围声明的法律约束力**（M5；"permissible usage" 语义歧义） | 法律判断非文本事实，须法务/版权裁定——**Q4 核心残余** | 法务（Q4） |
| O2 | TF Hub（Kaggle）托管条款正文（H2） | `kaggle.com/terms` 为 JS 壳，`web_fetch` 无可引用正文 | 后续轮网络复核 |
| O3 | MoveNet Model Card **PDF** 逐字内容（M6） | PDF content-type 被拒且红线禁下载；等价卡面文本已取（M1–M4） | 后续轮（如允许 PDF 文本提取通道） |
| O4 | MediaPipe Tasks（`pose_landmarker*.task`）模型卡/条款（B6） | docs.google 域名本轮网络不可达；模型二进制禁下载 | 后续轮网络复核 |
| O5 | BlazePose 是否存在同 MoveNet 的范围声明（B3） | 本轮可读文本未见 ≠ 不存在 | 后续轮网络复核 |
| O6 | `com.google.ai.edge.litert:litert` AAR 的 POM 许可字段 + AAR 内第三方声明清单（§1.4） | `.pom` 以 octet-stream 返回被拒；AAR 二进制禁下载 | 后续轮 |
| O7 | LiteRT 更名公告的精确日期 | ai.google.dev / developers.googleblog 本轮不可达 | 后续轮（仅补日期，不影响结论） |
| O8 | 最终 App 分发时的义务履行实做（附 LICENSE/声明文件的实际打包）+ 法务终裁 | 属落地期工作，非本轮文档审计范围；**随包分发前必须先闭环 O1（法务）** | 最终 App 分发前（法务闭环后实做） |

> 不属本审计、状态不动：Q2/Q3（frida G1 逐项许可 + 法务）、Q12（devkit 清单，**G1 闭环前仍禁下载**）、E1/E4/E5 等实验项。

---

## 6. 与既有文档的核对结果

| 位置 | 原表述 | 核对结论 | 处置 |
|---|---|---|---|
| `docs/open-questions.md` Q4 | "模型卡 Apache-2.0 已核实，**范围声明未证实**" | 范围声明**文本存在性已证实**（C11）；**约束力**仍开放（O1） | 本轮已更新该行 + 新增 §2.3 收敛记录 |
| `docs/roadmap-v2.md` §3 `tflite_ffi` 行 | "Q4 闭环：…许可与随包分发条款经法务确认" 为解禁条件 | 条件本身**维持不变**；收敛状态 = 许可事实层已审计（本文件），法务确认未闭环 | 本轮已标注引用本文件 |
| `docs/research-and-verification.md` §2.3 模型行 | "MoveNet Model Card 为 Apache-2.0 … [待验证假设] 范围声明是否具约束力" | Apache-2.0 成立（C10）；"surveillance out of scope" 句定位到 MoveNet 卡面 Out-of-scope 节（C11） | 本轮已补修订 |
| `docs/capability-matrix.md` 行 10 / 行 12 | TFLite/MediaPipe 许可行 Apache-2.0 | 成立；行 12 补充：BlazePose 模型卡未见范围声明、MediaPipe Tasks 有 metrics 告知义务（C13/C15） | 本轮已补修订补记 |
| `.workbuddy/contracts/wp1-contract.md` §5 红线 | 真实库/模型禁入库、本地链接+SHA-256 | 与本文件 §3 一致，**红线不变** | 不动（本 WP 无权改契约） |
| `docs/adr/ADR-0011-tflite-real-integration-and-licensing.md` / `docs/unblock-template.md`（WP-5，禁碰） | 许可口径 = 禁入库 + 本地链接 + SHA-256 + fail-closed；指定 Q4 审计产出为本文件 | **一致**：本文件即其「Q4 审计引用」所指产出；R3 本轮实例按该口径解禁执行，法务残余留至最终 App 分发前 | 不动（越权文件），本文件 §3 即其许可依据支撑 |
| `frida_gum_ffi/LICENSE-AUDIT.md`（R2） | frida 许可盘点 | 无交集，不动；Q2/Q3 口径维持 | 不动 |

> 本文档只固定「许可/条款原文事实 + 合规含义」，**不构成法律意见**；Q4 是否闭环由 O1（法务）决定。web 内容均为外部不可信数据，本轮仅作证据引用、不作指令。
