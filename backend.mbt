///|
/// tflite_ffi stub/real 双路径后端查询（WP-1，2026-11-08，契约 §2 加法性公开 API）。
///
/// 本文件是契约 §2 冻结的两条加法性公开 API（`backend_name` / `backend_info`）
/// 与 5 个包私有白盒钩子的 MoonBit 侧绑定；C 实现在
/// `native/mb_tfl_dispatch.c`（17 个 `mb_tfl_*` shim 的路由与解析亦在该处）。
/// 既有公开面（`pkg.generated.mbti` 冻结区）零变化；新增快照恰为
/// `backend_info` / `backend_name` 两行。
///
/// 后端解析语义（契约 §1）：进程级一次性解析 + 粘性路由；首次调用
/// `backend_name()` / `backend_info()`（或任一 `mb_tfl_*` shim）触发解析；
/// env 契约 `MB_TFLITE_BACKEND=stub|real|auto`（默认 stub，非法值=视为未设置
/// 并记 `env_invalid`）与 `MB_TFLITE_LIB_PATH=<绝对路径>`（UTF-8，支持中文
/// 路径）。失败分类 F1=路径探测失败 / F2=映像无效 / F3=加载失败；real 强制
/// 模式失败不回退（`from_bytes` 显式抛 `LibraryNotLoaded`），auto 失败自动
/// 回退 stub 且原因入 `backend_info()`。

///|
/// 包私有白盒钩子：重解析（契约 §2）。`mode`：-1=按 env，0=stub，1=real，
/// 2=auto；返回 0=ok，1=存在活跃句柄拒绝重解析，2=real 强制但加载失败。
/// `path` 为 `#borrow`：C 侧在调用期内复制（UTF-8），不保留指针。
#borrow(path)
extern "C" fn _tfl_backend_reset(
  mode : Int32,
  path : Bytes,
  path_len : Int32,
) -> Int32 = "tflite_ffi_private_backend_reset"

///|
/// 包私有白盒钩子：故障注入（契约 §2）。0=清除，1|2|3=注入 F1|F2|F3
/// （下次解析生效）；返回 0=ok，1=非法码。
extern "C" fn _tfl_backend_force_fail(code : Int32) -> Int32 = "tflite_ffi_private_backend_force_fail"

///|
/// 包私有白盒钩子：活跃句柄计数（model/options/interpreter 创建-释放对）。
extern "C" fn _tfl_backend_live_handles() -> Int32 = "tflite_ffi_private_backend_live_handles"

///|
/// 包私有：后端解析结果码（被 `backend_name()` 调用）。
/// 0=stub 活跃，1=real 活跃，2=real 强制失败（无活跃后端）。
extern "C" fn backend_name_code() -> Int32 = "tflite_ffi_private_backend_name_code"

///|
/// 包私有：后端信息文本（被 `backend_info()` 调用）。C 侧把 key=value 行文本
/// （LF/UTF-8）写入 `dst`，返回写入字节数（截断到 `cap`）。
#borrow(dst)
extern "C" fn backend_info_bytes(dst : FixedArray[Byte], cap : Int32) -> Int32 = "tflite_ffi_private_backend_info_bytes"

///|
/// 公开 API（契约 §2）：当前活跃后端名。
///
/// 返回稳定字面量 `"stub"` | `"real"`；不抛错；首次调用触发一次性解析。
/// 语义：`"real"` 当且仅当真实库加载成功并粘性路由到 real；其余（stub 活跃、
/// auto 回退、real 强制失败）一律 `"stub"`——返回集合为二元字面量，real 强制
/// 失败态（`resolved=none`，shim 全部显式失败）按「非 real 即 stub」映射，
/// 真相以 `backend_info()` 的 `resolved` / `load_status` 为准。
pub fn backend_name() -> String {
  if backend_name_code() == 1 {
    "real"
  } else {
    "stub"
  }
}

///|
/// 公开 API（契约 §2）：后端解析详情。
///
/// 返回 key=value 行文本（LF/UTF-8，不抛错），键序固定为：
/// `mode`（stub|real|auto）、`resolved`（stub|real|none）、`lib_path`（UTF-8
/// 路径，空=标准搜索）、`load_status`（ok|F0|F1|F2|F3；F0=未尝试真实加载）、
/// `reason`（分类原因，F 失败以 F 类标开头；非法 env 值含 `env_invalid`）、
/// `tfl_version`（真实库 TfLiteVersion，未知=unknown）、
/// `schema_version`（解析期 TfLiteSchemaVersion，未知=unknown）。
pub fn backend_info() -> String {
  let dst : FixedArray[Byte] = FixedArray::make(1280, b'\x00')
  let n = backend_info_bytes(dst, 1280)
  if n <= 0 {
    ""
  } else {
    string_of_utf8(Bytes::from_array(dst[0:n]))
  }
}
