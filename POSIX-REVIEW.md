# POSIX `dlopen` 分支走查与实跑（tflite_ffi · R4，2026-11-09）

> 范围：`native/mb_tfl_real.c` 的 POSIX 分支（`dlopen`/`dlsym`、`stat`/`open`/ELF
> 头探测）与 `native/mb_tfl_dispatch.c` 的 POSIX 线程/env 分支。
>
> **任务前提修正（如实）**：原计划「POSIX 分支无法在本机 Windows 实跑，只做设计
> 走查」。本机装有 **WSL2 Ubuntu（Linux 6.6 x86_64，gcc 15.2）**，因此除走查外，
> 还**手工编译并实跑了 POSIX 分支**（§3）。但这不是 Windows 原生运行，也**不是**
> `moon test` 的 Linux CI 路径，更不是 Android 真机——后三者仍为 `[仍需实测]`。
>
> 证据等级：`[已复验-WSL]` = WSL Linux x86_64 手工 gcc 编译/运行；`[已复验-代码审查]`
> = 逐行走查；`[仍需实测]` = 无证据，不得当通过。

## 1. 代码走查（POSIX 分支）

| # | 位置 | 行为 | 评估 |
|---|---|---|---|
| 1 | `mb_tfl_real.c:24-30` | 引入 `dlfcn/errno/fcntl/sys/stat/unistd` | 头文件齐全；`-std=c11` 下 `setenv` 需 `_POSIX_C_SOURCE`（仅测试 harness 问题，库不用） |
| 2 | `mb_tfl_real.c:39-48` | `g_module` 为 `void*`；`dlclose` 释放 | 正确；`g_module` 访问由 dispatch 锁保护（见 #10） |
| 3 | `mb_tfl_real.c:139-172` | `stat` → `S_ISREG` → `open` → `read` 4 字节 → 校验 `0x7F ELF` | 主路径正确；仅校验 magic，不校验 `EI_CLASS/EI_DATA/e_machine`（见 F1-1）；存在 TOCTOU/FIFO 风险（F2-2）、短读/EINTR（F2-3） |
| 4 | `mb_tfl_real.c:180` | `dlsym` 经 `void*` 转函数指针 | POSIX 保证该转换；ISO C 语义上 UB，属可接受惯例（F3-2） |
| 5 | `mb_tfl_real.c:183-249` | 24 个必需符号逐个 `dlsym`，缺失 → F2 | 与 `c_api.h` 稳定子集一致；缺失导出实跑为 F2（§3 E） |
| 6 | `mb_tfl_real.c:312-326` | 显式路径 `dlopen(RTLD_NOW|RTLD_LOCAL)`；失败 → F3；标准搜索失败 → F1 | 显式路径分类合理；标准搜索的分类粒度不足（F1-2） |
| 7 | `mb_tfl_real.c:335-343` | `TfLiteSchemaVersion ∈ [1,16]`，不符 → F2 | 实跑 schema=99 → F2（§3 F） |
| 8 | `mb_tfl_real.c:345-351` | 记录 `TfLiteVersion` 文本 | 正确（信息性） |
| 9 | `mb_tfl_dispatch.c:100-129` | POSIX `pthread_mutex` + `__atomic_*` 计数 | 正确；`__atomic` 要求 GCC/Clang（POSIX 构建即如此） |
| 10 | `mb_tfl_dispatch.c:296-302, 674-688` | 一次性解析/重置在锁内；`live_handles>0` 拒绝重解析 | 实跑通过（§3 I）；`g_state.resolved` 的 fast-path 无锁读为 C11 数据竞争（F3-4） |
| 11 | `mb_tfl_dispatch.c:590-668` | real `tensor_meta` 映射 `TfLiteTensor*` | 实跑通过（§3 H：dims/dtype/byte_size/name） |

## 2. 走查发现（按严重度）

### F1-1（P1）ELF 架构/类别不匹配被归类为 F3，而非 F2

`probe_path` 只校验 4 字节 ELF magic；一个 AArch64 或 32 位 ELF 在 x86_64 上会
通过探测，随后 `dlopen` 失败 → 被归为 **F3（加载失败）**。Windows 分支对
`ERROR_BAD_EXE_FORMAT` 明确归 F2。分类语义应一致：**映像无效 = F2**。
建议：读取 ELF header 的 `EI_CLASS`/`EI_DATA`/`e_machine`，与本机
`sizeof(void*)` 及编译目标架构比对，不符返回 F2。**[仍需实测]**（本次未构造
错架构 ELF 实跑；截断 ELF 的 F3 路径已实跑，见 §3 G）。

### F1-2（P1）标准搜索失败一律 F1，丢失「依赖缺失 = F3」区分

`path_utf8 == NULL` 时直接 `dlopen("libtensorflowlite_c.so")`，失败即
`F1 library_not_found`（`mb_tfl_real.c:317-321`），不读取 `dlerror()`。若库在
`LD_LIBRARY_PATH` 中存在但缺少依赖（应 F3）或架构不符（应 F2），会被误报 F1。
Windows 分支只把 `FILE/PATH/MOD_NOT_FOUND` 归 F1，其余归 F3，POSIX 与之不对称。
建议：标准搜索失败时也读取 `dlerror()` 并写入 `detail`，至少可诊断；分类可保守
保持 F1（契约把「标准搜索未命中」定义为 F1），但需在文档明确该不对称。
**[仍需实测]**（Linux 包管理环境）。

### F2-1（P2）POSIX 下 `path_len` 未使用（编译器实测警告）

`probe_path(const char *path_utf8, int32_t path_len, ...)` 在 POSIX 分支完全不使用
`path_len`，依赖 NUL 结尾；dispatch 内部保证 NUL，但 `mb_tfl_real_try_load` 是
内部头公开函数，若未来调用方传入非 NUL 结尾缓冲会越界读。gcc
`-Wall -Wextra` 实测：`warning: unused parameter 'path_len' [-Wunused-parameter]`
（`[已复验-WSL]`）。建议：POSIX 侧先复制到有界缓冲（如 `char p[520]`）再使用，
或显式 `(void)path_len;` 并写明前置条件。

### F2-2（P2）`stat` → `open` 的 TOCTOU 与 FIFO 阻塞

先 `stat` 判常规文件，再 `open` 读取；两者之间路径可被替换为 FIFO/设备，
`open(O_RDONLY)` 对 FIFO 会**阻塞**（可挂起加载线程）。建议：`open` 后
`fstat(fd)` 再判 `S_ISREG`；在 `O_NONBLOCK` 可用时加上以避免 FIFO 阻塞；
`O_CLOEXEC` 防止 fd 泄漏到子进程。**[仍需实测]**（未构造 FIFO 竞争场景）。

### F2-3（P2）短读/EINTR 被误判为 F2

`read(fd, magic, 4)` 一次调用：返回 1–3 字节或 `-1/EINTR` 时直接
`not_elf_image`（F2）。合法 ELF 在信号打断/短读时可能被误分类。建议：循环读满
4 字节，`EINTR` 重试，`0` 才判 EOF。**[仍需实测]**（信号场景）。

### F3-1（P3）`dlsym` 的 `void*`→函数指针转换

POSIX 明确允许，ISO C 未定义；这是动态加载的通行做法，保留并在注释说明即可。

### F3-2（P3）`RTLD_LOCAL` 不阻止全局符号插桩

`RTLD_LOCAL` 只限制本库符号的可见性，不改变其解析顺序；宿主进程若已导出同名
`TfLite*`/absl 符号，可能被优先绑定。glibc 可用 `RTLD_DEEPBIND` 缓解，但不可移植。
建议：记录为已知风险；真实集成时避免宿主导出同名符号。**[仍需实测]**。

### F3-3（P3）`g_state.resolved` fast-path 无锁读

`ensure_resolved()` 先无锁读 `g_state.resolved`，解析线程写同一字段；严格 C11
语义是数据竞争（x86 上实践良性）。建议改 `atomic_int` 或始终持锁读；本轮不改，
登记为可移植性风险。**[已复验-代码审查]**。

### F3-4（P3）ABI 假设：`TfLiteTensorQuantizationParams` 结构体按值返回

`mb_tfl_quant_params { float; int32 }` 必须与真实 `TfLiteQuantizationParams` 布局/
调用约定一致。POSIX 同编译器 ABI 下成立；跨编译器（GCC/Clang 混用）未验证。
**[仍需实测]**。

## 3. WSL 实跑（新增证据，`[已复验-WSL]`）

环境：WSL2 Ubuntu，kernel `6.6.87.2-microsoft-standard-WSL2`，`x86_64`，
gcc `15.2.0`。**手工 gcc 构建**（非 moon 构建链）：

```bash
# 1) 三个 C 翻译单元
gcc -std=c11 -O2 -I native -c native/mb_tfl_real.c      -o /tmp/tfl_posix/real.o
gcc -std=c11 -O2 -I native -c native/mb_tfl_dispatch.c  -o /tmp/tfl_posix/dispatch.o
gcc -std=c11 -O2 -c stub/mb_tfl_stub.c                  -o /tmp/tfl_posix/stub.o
# 2) 测试替身（TEST DOUBLE，不是 TFLite）：完整 mock / 缺导出 / schema=99
gcc -shared -fPIC -o /tmp/tfl_posix/mock/libtensorflowlite_c.so .local/posix/mock_tflite.c
gcc -shared -fPIC -o /tmp/tfl_posix/partial/partial.so        .local/posix/partial_tflite.c
gcc -DMOCK_SCHEMA_VERSION=99 -shared -fPIC -o /tmp/tfl_posix/badschema/badschema.so .local/posix/mock_tflite.c
# 3) 冒烟 harness（40 项断言）
gcc -std=c11 -O2 -I native .local/posix/posix_smoke.c \
    /tmp/tfl_posix/{real,dispatch,stub}.o -o /tmp/tfl_posix/posix_smoke -lm -ldl -pthread
/tmp/tfl_posix/posix_smoke
```

结果：`BUILD_OK`，**40/40 检查 OK，`SMOKE_EXIT=0`**。覆盖：

| 场景 | 结果 |
|---|---|
| A auto + 路径不存在 | F1 → 回退 stub，`resolved=stub`，`auto_fallback_stub` |
| B auto + 非 ELF 损坏文件 | F2（`image_invalid`）→ 回退 stub |
| C real 强制 + 路径不存在 | `reset=2`、`capi_version=-1`（F1 哨兵）、`model_create=NULL`、`resolved=none` |
| D 注入 F3 | `capi_version=-3`、`load_status=F3`、`injected_failure` |
| E `dlopen` 成功但缺导出 | F2（`missing_export:`） |
| F schema=99 | F2（`schema_incompatible:99`） |
| G 截断 ELF（magic 通过、`dlopen` 失败） | F3（`load_error` 路径） |
| H mock 库加载成功 | `load_status=ok`、`resolved=real`、`TfLiteVersion/SchemaVersion` 回显；`resize[2,4]`→未 allocate 时 invoke=1→allocate→copy/invoke/copy 输出 = 输入×2.0；real `tensor_meta` dims/dtype/byte_size/name 正确 |
| I 活跃句柄 | `reset=1` 拒绝；句柄清零后允许；切回 stub |
| J 标准搜索（无路径） | F1（`library_not_found`） |

编译告警（如实）：`unused parameter 'path_len'`（F2-1）与 dispatch
`-Wstringop-truncation`（`copy_str`，有界截断属预期，非缺陷）。

**边界声明**：以上是 **C 层手工构建**，不是 `moon test`；mock 库不是真实
`libtensorflowlite_c`。因此不能据此宣称「Linux CI 已跑通」或「真实库 POSIX 已
跑通」。

## 4. 仍未闭环（全部 `[仍需实测]`）

1. **Linux CI 路径**：在 Linux runner 上安装 MoonBit 工具链，`moon test` 全量
   （48 用例）实跑，验证 `moon.pkg` 的 `native-stub` 多文件 C 在 gcc 下的链接。
2. **真实 `libtensorflowlite_c.so`**（非 mock）：Linux 上的加载、schema、全链路与
   数值对齐。
3. **Android armv7/arm64**：`dlopen` 路径、页大小、NDK 工具链、JNI 包装（非本轮）。
4. **F1-1 错架构分类**、**F1-2 标准搜索分类**、**F2-2 FIFO/TOCTOU**、
   **F2-3 EINTR** 的补丁与回归（建议补丁见 §5，本轮未改代码以免引入未验证行为）。
5. **Linux `.so` 命名**：标准搜索只试 `libtensorflowlite_c.so`，发行版常见的
   `libtensorflowlite_c.so.<major>` 需 `MB_TFLITE_LIB_PATH` 显式指定或补充搜索。

## 5. 建议补丁（未应用，待 Linux 回归）

```c
/* probe_path POSIX: open 后 fstat，避免 TOCTOU/FIFO；EINTR 重试；O_CLOEXEC */
int flags = O_RDONLY;
#ifdef O_CLOEXEC
flags |= O_CLOEXEC;
#endif
#ifdef O_NONBLOCK
flags |= O_NONBLOCK;
#endif
fd = open(path_utf8, flags);
if (fd < 0) { /* ENOENT -> F1 path_not_found; 其余 -> F1/F3 记录 errno */ }
if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) { close(fd); /* F1 not_regular_file */ }
while (got < 4) {
  ssize_t r = read(fd, magic + got, (size_t)(4 - got));
  if (r < 0 && errno == EINTR) continue;
  if (r <= 0) break;
  got += r;
}
/* 另加 EI_CLASS/EI_DATA/e_machine 校验 -> F2（F1-1） */
```

## 6. 结论

- POSIX 分支**设计成立**：失败分类 F1/F2/F3、real 强制哨兵、auto 回退、粘性路由、
  句柄守卫与 real 张量元数据映射均在 WSL 手工构建下按契约工作（40/40）。
- 主要残余是**分类粒度**（错架构 F3↔F2、标准搜索 F1↔F3）与**路径健壮性**
  （TOCTOU/FIFO/EINTR），不影响默认 stub 路径，也不影响 Windows 路径。
- **不得**把本节写成「Linux CI 已通过」「Android 已通过」「真实 POSIX 库已跑通」；
  这些仍是 `[仍需实测]`。
