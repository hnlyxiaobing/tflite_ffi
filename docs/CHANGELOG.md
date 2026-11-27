# CHANGELOG（逐包交付与门禁状态）

> 本表是 rollout 的可恢复状态（skill §7）：每包一行，记录新增 pub、快照 diff、
> 测试增量与门禁结果。日期均为本机实测日期；SKIPPED/结构断言单列，不折入通过数。

| 日期 | 工作包 | 交付内容 | 新增 pub | 快照 diff | 测试 | 门禁 |
|---|---|---|---|---|---|---|
| 2026-11-27 | 基线（工具链漂移修复） | `@fs.mkdir` 参数改为 `allow_existing`；移除 `cmd/main` 冗余 `async` 导入；根包 `max_concurrent_tests = 1`（后端全局态测试串行）；`warnings: "-unused_package"` 仅抑制 async 测试导入误报（坚持零第三方依赖） | 无 | 空 | 49/49（+2 `#skip`） | 五门禁绿 |
| 2026-11-27 | W1 漂移清理与自包含 | README 成为唯一入口文档 + docs 索引；§3 索引与 `pkg.generated.mbti` 逐条对齐（4 个 `#external`、2 个别名、`to_repr`、`type Interpreter`）；失效的旧文档名（API/DESIGN/DECISIONS/Q10-OPERATOR-COVERAGE/stub README）与旧目录（tests/golden）引用全部改指实存文档；新建 `docs/GAPS.md`、`docs/CHANGELOG.md`；`.gitattributes` LF 策略 | 无 | 空 | 49/49 | 五门禁绿 + 引用实存性扫描零失效 |
| 2026-11-27 | W3 C 元数据 fail-closed | `checked_tensor_meta`：rank 1..8（越界 `NullHandle`）、byte_size 0..256 MiB（越界 `BufferSizeMismatch`）、name_len 夹到 0..64；截断/单字节突变扫描驱动 | 无 | 空 | 49→53（+4） | 五门禁绿 |
| 2026-11-27 | W2 双路径契约 golden | `tests/fixtures/golden/` 新增 backend_info（stub/auto-F1/real-F1）、状态序列、13/13 错误簿记、CLI 记录行/hex 夹具；`contract_wbtest.mbt` 真实读取 backend_info/状态序列/错误簿记/数值 norm（stub VEC + TOL）golden；`tools/cli-golden.py` 作为可选 L4 附加检查（9 场景：help/usage/stub/out-raw/auto/real-fail/bad-input） | 无 | 空 | 53→61（+8） | 五门禁绿；L4 CLI golden 通过 |
| 2026-11-27 | W4 `backend_resolved()` | 新增 `pub fn backend_resolved() -> String`（`stub`/`real`/`none`），与 `backend_info().resolved` 一致；旧 `backend_name()` 二元映射冻结（none→stub） | `backend_resolved` | 纯加法 +2 行 | 61→62（+1） | 五门禁绿；快照加法性通过 |
| — | W5 真实库跨平台与设备轮 | 仅 W5-A runner（`tools/real-golden.sh`）与哈希门禁落地；Linux/Android/数值对齐/真机报告 **SKIPPED** | 无 | 空 | 2 条 `#skip` | 见 `GAPS.md` |
| — | W6 Q4 许可与分发终裁 | W6-A 许可索引 [`LICENSE-INDEX.md`](LICENSE-INDEX.md) 落地；法务残余开放 | 无 | 空 | — | 零第三方二进制 |

## 状态说明

- 当前 `moon test`：**62/62 + 2 skip**（2026-11-27 本机实测；2 条 `golden real` `#skip` 不计入通过）。
- `golden real` 两条在无真实库时保持 SKIPPED（退出码 78 口径），历史 2/2 不计入当前结论。
- W3 的 rank/byte_size 上界为**防御性结构断言**（stub 解析器与 real C 分发先拒绝畸形元数据）；
  截断/突变扫描为实测行为覆盖。
- W2 的 real 侧状态码 1、双路径真实分类矩阵归 W5，未实测前不预写通过。
