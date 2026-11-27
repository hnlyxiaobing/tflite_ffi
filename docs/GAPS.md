# 缺口登记（GAPS）

> 本文件是 `tools/get-tflite.ps1` 的 fail-closed 登记目标（脚本以 `docs/GAPS.md` 追加），
> 也是 README §6「风险与未决」的明细账本。所有条目保持 fail-closed：未实测即 SKIPPED，
> 不写成通过；真实库/真实模型二进制永不入库（红线见 [`LICENSE-INDEX.md`](LICENSE-INDEX.md)）。

## 当前缺口

| 缺口 | 状态 | 具体阻塞条件 | 复验入口 |
|---|---|---|---|
| Linux x86-64 真实库加载（F1/F2/F3 分类与 `backend_info` 矩阵） | SKIPPED | 需 Linux 主机的 `tensorflowlite_c.so`；本机仅 Windows 实测 | `MB_TFLITE_BACKEND=real MB_TFLITE_LIB_PATH=<path> moon test --include-skipped -f "golden real*"` |
| Android/NDK 真实库与 Q10 real 算子集合 | SKIPPED | 需 Android 设备/NDK 与授权样本 | W5 M5-3（设备轮） |
| Python tflite-runtime 数值对齐（<1e-4） | SKIPPED | 需真实库 + Python 运行时 | W5 M5-3 |
| win-x64 `golden real` 两条（micro_mul_f32 v1/v2） | 已复验（本机未入库库） | 2026-11-27 显式 real 路径实跑 2/2；默认 `moon test` 仍将两条记为 `#skip` | `MB_TFLITE_BACKEND=real MB_TFLITE_LIB_PATH=<path> moon test --include-skipped -f "golden real*"` |
| Q4 法务残余（模型使用范围声明约束力、随包分发终裁） | 开放 | 需用户/法务确认目标模型使用范围 | [`LICENSE-INDEX.md`](LICENSE-INDEX.md) |
| async 测试夹具依赖 `moonbitlang/core/async` | 跟踪 | 测试使用 core 自带 async 包；当前工具链会误报 `unused_package`，本包以 `warnings: "-unused_package"` 兼容。若 core/async 被移除，需把 golden 读取改为同步 C 辅助或内嵌快照 | `moon check --deny-warn` / `moon test` |

## 登记规则

- 每个缺口必须写明「具体阻塞条件」与「复验入口」；不得只写「未实现」。
- 真实库哈希/路径/日期只登记到仓库外 `.local/`（`PROVENANCE.md` / `SHA256SUMS.txt`），
  本文件只保留仓库内可复验的事实。
- 缺口关闭时同提交更新本表与 [`CHANGELOG.md`](CHANGELOG.md)，并附命令 + 日期 + 计数。
