///|
/// W2/W3 契约测试（白盒）：可复用产物扫描驱动、元数据 fail-closed 边界、
/// 双路径诊断 golden、状态序列 golden、13/13 错误簿记门禁。
/// golden 文本位于 `tests/fixtures/golden/`，测试真实读取（非内嵌复制）。

///|
/// 读取仓库内 golden 文本（`moon test` 以模块根为工作目录）。
async fn cw_golden_text(rel : String) -> String {
  let raw = @utf8.decode(@fs.read_binary(rel))
  // 跨平台/Win 检出兼容：golden 比较口径统一为 LF。
  raw.replace_all(old="\r\n", new="\n")
}

///|
/// 前缀截断扫描驱动（M0/W3 T-W3-4）：对 `artifact` 的每个严格前缀调用 `on_case`，
/// 返回扫描样本数。后续工作包以一行 `cw_scan_truncations(x, observe)` 注册新产物。
fn cw_scan_truncations(artifact : Bytes, on_case : (Bytes) -> Unit) -> Int32 {
  for n in 0..<artifact.length() {
    let prefix : Array[Byte] = []
    for i in 0..<n {
      prefix.push(artifact[i])
    }
    on_case(Bytes::from_array(prefix[:]))
  }
  artifact.length()
}

///|
/// 单字节突变扫描驱动：逐个位置异或 0x5A，返回扫描样本数。
fn cw_scan_byte_mutations(artifact : Bytes, on_case : (Bytes) -> Unit) -> Int32 {
  for i in 0..<artifact.length() {
    let mutated : Array[Byte] = []
    for j in 0..<artifact.length() {
      let b = if j == i {
        (artifact[j].to_int() ^ 0x5A).to_byte()
      } else {
        artifact[j]
      }
      mutated.push(b)
    }
    on_case(Bytes::from_array(mutated[:]))
  }
  artifact.length()
}

///|
/// 非空行拆分（golden 文本按行登记）。
fn cw_nonempty_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  for line in text.split("\n") {
    let s = line.to_owned()
    if s != "" {
      out.push(s)
    }
  }
  out
}

///|
/// 从 `backend_info()` 的 key=value 行中取值；缺键返回空串。
fn cw_info_value(info : String, key : String) -> String {
  let prefix = key + "="
  for line in info.split("\n") {
    let s = line.to_owned()
    if s.has_prefix(prefix) {
      return s[prefix.length():].to_owned()
    }
  }
  ""
}

///|
fn cw_state_name(s : InterpreterState) -> String {
  match s {
    Uninitialized => "Uninitialized"
    Ready => "Ready"
    Invoking => "Invoking"
    Closed => "Closed"
  }
}

///|
fn cw_dtype_name(t : TensorDtype) -> String {
  match t {
    Float32 => "f32"
    Float16 => "f16"
    Int32 => "i32"
    UInt8 => "u8"
    Int8 => "i8"
    Int64 => "i64"
  }
}

///|
fn cw_shape_text(shape : Array[Int32]) -> String {
  let parts : Array[String] = []
  for d in shape {
    parts.push(d.to_string())
  }
  parts.join(" ")
}

///|
/// f32 小端字节 → 8 位小写 hex（按 IEEE-754 位型从高到低，逗号分隔）。
fn cw_hex(data : Bytes) -> String {
  let digits = "0123456789abcdef"
  let parts : Array[String] = []
  let mut i = 0
  while i + 3 < data.length() {
    let mut word = ""
    for k in 0..<4 {
      let v = data[i + 3 - k].to_int()
      let hi = (v >> 4) & 0xF
      let lo = v & 0xF
      word = word + digits[hi:hi + 1].to_owned()
      word = word + digits[lo:lo + 1].to_owned()
    }
    parts.push(word)
    i = i + 4
  }
  parts.join(",")
}

///|
fn cw_ascii_lower(s : String) -> String {
  let out : Array[Char] = []
  for c in s {
    out.push(c.to_ascii_lowercase())
  }
  String::from_array(out[:])
}

///|
fn cw_hex_val(c : Int32) -> Int32 {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 65 && c <= 70 {
    c - 65 + 10
  } else if c >= 97 && c <= 102 {
    c - 97 + 10
  } else {
    0
  }
}

///|
/// 解析登记文件中的大写 8 位 hex 词（逗号分隔）为小端 f32 字节。
fn cw_hex_to_bytes(hex : String) -> Bytes {
  let ascii = @utf8.encode(hex)
  let out : Array[Byte] = []
  let mut i = 0
  while i + 7 < ascii.length() {
    let mut v : Int64 = 0
    for k in 0..<8 {
      v = v * 16 + cw_hex_val(ascii[i + k].to_int()).to_int64()
    }
    out.push((v & 0xFF).to_int().to_byte())
    out.push(((v >> 8) & 0xFF).to_int().to_byte())
    out.push(((v >> 16) & 0xFF).to_int().to_byte())
    out.push(((v >> 24) & 0xFF).to_int().to_byte())
    i = i + 9
  }
  Bytes::from_array(out[:])
}

///|
/// 13 个错误变体的稳定名（穷尽匹配：新增变体未同步时 `moon check --deny-warn`
/// 因非穷尽匹配变红，构成本登记的双向门禁）。
fn cw_error_name(e : TfLiteError) -> String {
  match e {
    LibraryNotLoaded(_) => "LibraryNotLoaded"
    ModelCreateFailed(_) => "ModelCreateFailed"
    InterpreterCreateFailed(_) => "InterpreterCreateFailed"
    AllocateTensorsFailed(_) => "AllocateTensorsFailed"
    InvalidTensorIndex(_) => "InvalidTensorIndex"
    ResizeFailed(_, _) => "ResizeFailed"
    CopyFromBufferFailed(_) => "CopyFromBufferFailed"
    CopyToBufferFailed(_) => "CopyToBufferFailed"
    InvokeFailed(_) => "InvokeFailed"
    BufferSizeMismatch(_, _) => "BufferSizeMismatch"
    UnsupportedDtype(_) => "UnsupportedDtype"
    AlreadyClosed => "AlreadyClosed"
    NullHandle(_) => "NullHandle"
  }
}

///|
/// W3 T-W3-1：越界 rank 在分配前 fail-closed 为 `NullHandle`，无 panic。
test "w3 checked_tensor_meta rejects out-of-range rank" {
  fn rank_zero() -> Unit raise TfLiteError {
    ignore(checked_tensor_meta(0, 0, 4, 1))
  }

  fn rank_nine() -> Unit raise TfLiteError {
    ignore(checked_tensor_meta(0, 9, 4, 1))
  }

  fn rank_negative() -> Unit raise TfLiteError {
    ignore(checked_tensor_meta(0, -1, 4, 1))
  }

  assert_true(expect_err(rank_zero) is TfLiteError::NullHandle(_))
  assert_true(expect_err(rank_nine) is TfLiteError::NullHandle(_))
  assert_true(expect_err(rank_negative) is TfLiteError::NullHandle(_))
}

///|
/// W3 T-W3-2：负值/超上限 byte_size → `BufferSizeMismatch(268435456, actual)`，
/// 不触发大分配；边界值 0 与 256 MiB 接受。
test "w3 checked_tensor_meta bounds byte_size" {
  fn negative() -> Unit raise TfLiteError {
    ignore(checked_tensor_meta(0, 1, -1, 1))
  }

  fn overflow() -> Unit raise TfLiteError {
    ignore(checked_tensor_meta(0, 1, 268435457, 1))
  }

  assert_true(
    expect_err(negative) is TfLiteError::BufferSizeMismatch(268435456, -1),
  )
  assert_true(
    expect_err(overflow)
    is TfLiteError::BufferSizeMismatch(268435456, 268435457),
  )
  assert_eq((1, 1), checked_tensor_meta(0, 1, 0, 1))
  assert_eq((8, 1), checked_tensor_meta(0, 8, 268435456, 1))
}

///|
/// W3：name_len 夹到 0..64，rank 边界 1/8 接受。
test "w3 checked_tensor_meta clamps name length" {
  assert_eq((8, 64), checked_tensor_meta(0, 8, 4, 65))
  assert_eq((1, 0), checked_tensor_meta(0, 1, 4, -1))
  assert_eq((1, 63), checked_tensor_meta(0, 1, 4, 63))
}

///|
/// W3 T-W3-4：截断/单字节突变模型字节扫描无 panic、无句柄泄漏。
test "w3 truncated and mutated model bytes never panic" {
  let model = wb_model_f32()
  fn observe(candidate : Bytes) -> Unit {
    try {
      let interp = Interpreter::from_bytes(candidate, wb_opts())
      interp.close()
    } catch {
      _ => ()
    }
  }
  let truncations = cw_scan_truncations(model, observe)
  let mutations = cw_scan_byte_mutations(model, observe)
  assert_eq(model.length(), truncations)
  assert_eq(model.length(), mutations)
  assert_eq(
    0,
    _tfl_backend_live_handles(),
    msg="畸形样本扫描不泄漏句柄",
  )
}

///|
/// W2 T-W2-1：stub 默认态 `backend_info()` 键序与内容 golden。
async test "w2 backend info golden stub" {
  assert_eq(0, _tfl_backend_reset(0, b"", 0))
  let want = cw_golden_text("tests/fixtures/golden/backend_info_stub.txt")
  assert_eq(want, backend_info())
  assert_eq(0, bs_restore())
}

///|
/// W2 T-W2-1：auto + F1 回退 stub 的 `backend_info()` golden。
async test "w2 backend info golden auto fallback f1" {
  let p = bs_utf8("no_such_library_file")
  assert_eq(0, _tfl_backend_reset(2, p, p.length()))
  let want = cw_golden_text("tests/fixtures/golden/backend_info_auto_f1.txt")
  assert_eq(want, backend_info())
  assert_eq(0, bs_restore())
}

///|
/// W2 T-W2-1：real 强制 + F1 的 `backend_info()` golden（resolved=none）。
async test "w2 backend info golden real forced f1" {
  let p = bs_utf8("no_such_library_file")
  assert_eq(2, _tfl_backend_reset(1, p, p.length()))
  let want = cw_golden_text("tests/fixtures/golden/backend_info_real_f1.txt")
  assert_eq(want, backend_info())
  assert_eq(0, bs_restore())
}

///|
/// W2 T-W2-1/2：`from_bytes → set_input → invoke → output_raw → close`
/// 状态序列与输出 golden（stub 路径，确定性）。
async test "w2 state sequence golden stub" {
  let interp = Interpreter::from_bytes(wb_model_f32(), wb_opts())
  let lines : Array[String] = []
  lines.push("state.initial=" + cw_state_name(interp.state()))
  let d = interp.output_desc(0)
  lines.push(
    "desc.out=" +
    d.name +
    "|" +
    cw_dtype_name(d.dtype) +
    "|" +
    cw_shape_text(d.shape) +
    "|" +
    d.byte_size.to_string(),
  )
  interp.set_input(
    0,
    f32_bytes([0x3F800000, 0x40000000, 0x40400000, 0x40800000]),
  )
  lines.push("state.after_set_input=" + cw_state_name(interp.state()))
  interp.invoke()
  lines.push("state.after_invoke=" + cw_state_name(interp.state()))
  lines.push("output.hex=" + cw_hex(interp.output_raw(0)))
  interp.close()
  lines.push("state.after_close=" + cw_state_name(interp.state()))
  let close2 = try {
    interp.close()
    "ok"
  } catch {
    AlreadyClosed => "AlreadyClosed"
    _ => "other"
  }
  lines.push("close.again=" + close2)
  let want = cw_golden_text("tests/fixtures/golden/state_sequence.txt")
  assert_eq(want, lines.join("\n") + "\n")
}

///|
/// W2 T-W2-2：close 后任一方法恒 `AlreadyClosed`（状态机恒等式）。
test "w2 closed interpreter always raises AlreadyClosed" {
  let interp = Interpreter::from_bytes(wb_model_f32(), wb_opts())
  interp.close()
  fn set_input_after_close() -> Unit raise TfLiteError {
    interp.set_input(0, f32_bytes([0x3F800000]))
  }

  fn invoke_after_close() -> Unit raise TfLiteError {
    interp.invoke()
  }

  fn output_after_close() -> Unit raise TfLiteError {
    ignore(interp.output_raw(0))
  }

  fn resize_after_close() -> Unit raise TfLiteError {
    interp.resize_input(0, [1, 4])
  }

  fn allocate_after_close() -> Unit raise TfLiteError {
    interp.allocate_tensors()
  }

  assert_true(expect_err(set_input_after_close) is TfLiteError::AlreadyClosed)
  assert_true(expect_err(invoke_after_close) is TfLiteError::AlreadyClosed)
  assert_true(expect_err(output_after_close) is TfLiteError::AlreadyClosed)
  assert_true(expect_err(resize_after_close) is TfLiteError::AlreadyClosed)
  assert_true(expect_err(allocate_after_close) is TfLiteError::AlreadyClosed)
  // 状态访问器仍可读（Closed 后除 state/count 外一律 AlreadyClosed）
  assert_true(interp.state() is Closed)
  assert_eq(1, interp.input_count())
  assert_eq(1, interp.output_count())
}

///|
/// W2 T-W2-2：resize 后未 allocate 的 stub 状态码差异（stub=2）。
/// real 路径的同类差异折叠为 1，需仓库外真实库实测（W5），此处不混报。
test "w2 stub resize status code difference" {
  let interp = Interpreter::from_bytes(wb_model_dynamic(), wb_opts())
  let dims : FixedArray[Int32] = [2, 4]
  assert_eq(0, mb_tfl_resize_input(interp.interp, 0, dims, 2))
  let e1 = expect_err(() => {
    interp.set_input(
      0,
      f32_bytes([
        0x3F800000, 0x40000000, 0x40400000, 0x40800000, 0x40A00000, 0x40C00000, 0x40E00000,
        0x41000000,
      ]),
    )
  })
  assert_true(e1 is TfLiteError::CopyFromBufferFailed(2))
  let e2 = expect_err(() => interp.invoke())
  assert_true(e2 is TfLiteError::InvokeFailed(2))
  interp.close()
}

///|
/// W2 T-W2-3：13/13 错误变体双向簿记门禁（golden 文件 ↔ 穷尽匹配）。
async test "w2 error variant ledger thirteen" {
  let wanted = cw_nonempty_lines(
    cw_golden_text("tests/fixtures/golden/error_variants.txt"),
  )
  let samples : Array[TfLiteError] = [
    LibraryNotLoaded("x"),
    ModelCreateFailed(0),
    InterpreterCreateFailed(0),
    AllocateTensorsFailed(0),
    InvalidTensorIndex(0),
    ResizeFailed(0, "x"),
    CopyFromBufferFailed(0),
    CopyToBufferFailed(0),
    InvokeFailed(0),
    BufferSizeMismatch(0, 0),
    UnsupportedDtype("x"),
    AlreadyClosed,
    NullHandle("x"),
  ]
  let got : Array[String] = []
  for e in samples {
    got.push(cw_error_name(e))
  }
  assert_eq(13, wanted.length())
  assert_eq(wanted, got)
}

///|
/// W2 T-W2-1：数值黄金登记文件（`micro_mul_f32.numeric.norm.txt`）的
/// stub `VEC` 行与 `TOL` 行被真实消费。stub 为恒等拷贝语义，故登记的
/// `wanthex` 同时是输入位型与期望输出位型；real `VEC` 行归 W5 真实库。
async test "w2 numeric norm ledger stub vectors" {
  let text = cw_golden_text(
    "tests/fixtures/golden/micro_mul_f32.numeric.norm.txt",
  )
  assert_true(
    text.contains(
      "TOL|abs=1e-6|rel=1e-5|cmp=f64|nan=bit-equal|pm0=equal|inf=bit-equal",
    ),
    msg="容差登记行漂移",
  )
  let model = build_model(
    0x3F800000,
    [
      TensorSpec::{
        name: b"in",
        dtype: 0,
        dims: [1, 4],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
    [
      TensorSpec::{
        name: b"out",
        dtype: 0,
        dims: [1, 4],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
  )
  let mut consumed = 0
  for line in text.split("\n") {
    let row = line.to_owned()
    if row.has_prefix("VEC|stub|") {
      let mut want_hex = ""
      for field in row.split("|") {
        let f = field.to_owned()
        if f.has_prefix("wanthex=") {
          want_hex = f[8:].to_owned()
        }
      }
      if want_hex != "" {
        let bits = cw_hex_to_bytes(want_hex)
        assert_eq(16, bits.length())
        let interp = Interpreter::from_bytes(model, wb_opts())
        interp.set_input(0, bits)
        interp.invoke()
        let got = cw_hex(interp.output_raw(0))
        interp.close() // 先释放句柄，失败断言也不污染后端 reset 守卫
        assert_eq(cw_ascii_lower(want_hex), got)
        consumed = consumed + 1
      }
    }
  }
  assert_eq(2, consumed, msg="stub VEC 行应恰好消费 2 条")
}
