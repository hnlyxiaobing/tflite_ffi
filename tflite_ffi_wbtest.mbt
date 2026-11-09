// Whitebox tests run within the package scope.
// 覆盖内部映射：dtype 编码 → TensorDtype、版本断言常量、
// tensor_desc_of 的 NullHandle 错误映射（内部 shim 异常路径）、
// 以及冻结前 P0（决策 6）由黑盒迁入的 `mb_tfl_resize_input` /
// `mb_tfl_allocate_tensors` 直调测试（shim 已收紧为包私有）。

///|
fn wb_model() -> Bytes {
  let buf : Array[Byte] = []
  fn push_u32(v : Int32) {
    buf.push((v & 0xFF).to_byte())
    buf.push(((v >> 8) & 0xFF).to_byte())
    buf.push(((v >> 16) & 0xFF).to_byte())
    buf.push(((v >> 24) & 0xFF).to_byte())
  }
  fn push_tensor(name : Bytes) {
    push_u32(name.length())
    for j in 0..<name.length() {
      buf.push(name[j])
    }
    push_u32(0) // dtype Float32
    push_u32(1) // rank 1
    push_u32(1) // dim 1
    push_u32(0) // qscale
    push_u32(0) // qzero
  }
  push_u32(0x31465453) // magic "STF1"
  push_u32(1) // version
  push_u32(1) // input_count
  push_u32(1) // output_count
  push_u32(0x3F800000) // scale 1.0
  push_tensor(b"i")
  push_tensor(b"o")
  Bytes::from_array(buf[:])
}

///|
test "wb dtype_of_code maps all supported codes" {
  assert_true(dtype_of_code(0) is Float32)
  assert_true(dtype_of_code(1) is Float16)
  assert_true(dtype_of_code(2) is Int32)
  assert_true(dtype_of_code(3) is UInt8)
  assert_true(dtype_of_code(4) is Int8)
  assert_true(dtype_of_code(5) is Int64)
}

///|
test "wb dtype_of_code rejects unknown code" {
  let e = try {
    ignore(dtype_of_code(6))
    None
  } catch {
    err => Some(err)
  }
  assert_true(e is Some(UnsupportedDtype(_)))
}

///|
test "wb expected_capi_version matches shim" {
  assert_eq(expected_capi_version, mb_tfl_capi_version())
  assert_eq(0x00010001, expected_capi_version)
}

///|
test "wb tensor_desc_of maps shim failure to NullHandle" {
  let interp = Interpreter::from_bytes(wb_model(), InterpreterOptions::{
    thread_count: 1,
    allow_fp16: false,
  })
  // 越界下标让内部 shim 返回非 0 状态码
  let e = try {
    ignore(tensor_desc_of(interp.interp, 99, true))
    None
  } catch {
    err => Some(err)
  }
  assert_true(e is Some(NullHandle(_)))
  // 正常下标仍可取描述
  let desc = tensor_desc_of(interp.interp, 0, true)
  assert_eq("o", desc.name)
  assert_eq(4, desc.byte_size)
  interp.close()
}

///|
test "wb ensure_open guards closed interpreters" {
  let interp = Interpreter::from_bytes(wb_model(), InterpreterOptions::{
    thread_count: 1,
    allow_fp16: false,
  })
  interp.close()
  let e = try {
    ensure_open(interp)
    None
  } catch {
    err => Some(err)
  }
  assert_true(e is Some(AlreadyClosed))
}

///|
/// ---- 冻结前 P0（决策 6）：直接调用 `mb_tfl_*` shim 的测试由黑盒转白盒 ----
/// 17 个 shim 已收紧为包私有，黑盒测试无法再直接调用；`resize_input` /
/// `allocate_tensors` 语义未暴露 MoonBit 层公开 API（新增公开 API 属冻结禁区），
/// 故按约定转为白盒（`*_wbtest.mbt`，包内可访问私有字段与 shim）。
/// 下列 STF1 构造辅助与黑盒侧同源；测试夹具在黑盒/白盒两个编译单元各自独立，
/// 故在此复制一份（`wb_` 前缀避免与包内符号混淆）。

///|
struct TensorSpec {
  name : Bytes
  dtype : Int32
  dims : Array[Int32]
  qscale_bits : Int32
  qzero : Int32
}

///|
/// 小端追加 u32（负数按补码写入）。
fn push_u32(buf : Array[Byte], v : Int32) -> Unit {
  buf.push((v & 0xFF).to_byte())
  buf.push(((v >> 8) & 0xFF).to_byte())
  buf.push(((v >> 16) & 0xFF).to_byte())
  buf.push(((v >> 24) & 0xFF).to_byte())
}

///|
fn push_spec(buf : Array[Byte], s : TensorSpec) -> Unit {
  push_u32(buf, s.name.length())
  for j in 0..<s.name.length() {
    buf.push(s.name[j])
  }
  push_u32(buf, s.dtype)
  push_u32(buf, s.dims.length())
  for d in s.dims {
    push_u32(buf, d)
  }
  push_u32(buf, s.qscale_bits)
  push_u32(buf, s.qzero)
}

///|
/// 构造 STF1 模型字节（格式见 `stub/README.md`）。
fn build_model(
  scale_bits : Int32,
  inputs : Array[TensorSpec],
  outputs : Array[TensorSpec],
) -> Bytes {
  let buf : Array[Byte] = []
  push_u32(buf, 0x31465453) // magic "STF1" 小端
  push_u32(buf, 1) // version
  push_u32(buf, inputs.length())
  push_u32(buf, outputs.length())
  push_u32(buf, scale_bits)
  for s in inputs {
    push_spec(buf, s)
  }
  for s in outputs {
    push_spec(buf, s)
  }
  Bytes::from_array(buf[:])
}

///|
/// 按 f32 IEEE754 位模式构造张量字节。
fn f32_bytes(bits : Array[Int32]) -> Bytes {
  let buf : Array[Byte] = []
  for b in bits {
    push_u32(buf, b)
  }
  Bytes::from_array(buf[:])
}

///|
fn wb_opts() -> InterpreterOptions {
  InterpreterOptions::{ thread_count: 1, allow_fp16: false, }
}

///|
/// 捕获 `raise TfLiteError` 的错误值（白盒版本）。
fn expect_err(f : () -> Unit raise TfLiteError) -> Error {
  try {
    f()
    assert_true(false) // 期望出错却成功返回
    panic()
  } catch {
    e => e
  }
}

///|
/// 1 输入 1 输出的 f32 模型（[1,4]，scale = 2.0）。
fn wb_model_f32() -> Bytes {
  build_model(
    0x40000000,
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
}

///|
/// 动态尺寸模型：输出 [-1, 4] 在 allocate_tensors 时镜像 input 0 的轴 0。
fn wb_model_dynamic() -> Bytes {
  build_model(
    0x40000000,
    [
      TensorSpec::{
        name: b"dyn_in",
        dtype: 0,
        dims: [1, 4],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
    [
      TensorSpec::{
        name: b"dyn_out",
        dtype: 0,
        dims: [-1, 4],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
  )
}

///|
test "wb resize_input and allocate_tensors flow" {
  let interp = Interpreter::from_bytes(wb_model_dynamic(), wb_opts())
  let dims : FixedArray[Int32] = [2, 4]
  assert_eq(0, mb_tfl_resize_input(interp.interp, 0, dims, 2))
  // resize 后缓冲失效：未 allocate 之前写入按 CopyFromBufferFailed 传播
  let input = f32_bytes([
    0x3F800000, 0x40000000, 0x40400000, 0x40800000, 0x40A00000, 0x40C00000, 0x40E00000,
    0x41000000,
  ])
  let e = expect_err(() => interp.set_input(0, input))
  assert_true(e is TfLiteError::CopyFromBufferFailed(2))
  assert_eq(0, mb_tfl_allocate_tensors(interp.interp))
  // allocate 后：输入 32 字节、输出动态维镜像为 [2, 4]
  interp.set_input(0, input)
  interp.invoke()
  let desc = interp.output_desc(0)
  assert_eq("dyn_out", desc.name)
  assert_eq([2, 4], desc.shape)
  assert_eq(32, desc.byte_size)
  let out = interp.output_raw(0)
  assert_eq(32, out.length())
  assert_true(
    out ==
    f32_bytes([
      0x40000000, 0x40800000, 0x40C00000, 0x41000000, 0x41200000, 0x41400000, 0x41600000,
      0x41800000,
    ]),
  )
  interp.close()
}

///|
test "wb ops before allocate after resize fail" {
  let interp = Interpreter::from_bytes(wb_model_dynamic(), wb_opts())
  let dims : FixedArray[Int32] = [2, 4]
  assert_eq(0, mb_tfl_resize_input(interp.interp, 0, dims, 2))
  let e1 = expect_err(() => interp.invoke())
  assert_true(e1 is TfLiteError::InvokeFailed(2))
  let e2 = expect_err(() => ignore(interp.output_raw(0)))
  assert_true(e2 is TfLiteError::CopyToBufferFailed(2))
  interp.close()
}

///|
test "wb allocate_tensors fails on rank conflict" {
  // 输出 [-1, -1] 需要 input 0 至少 rank 2；resize 成 rank 1 后 allocate 失败
  let model = build_model(
    0x3F800000,
    [
      TensorSpec::{
        name: b"a",
        dtype: 0,
        dims: [2, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
    [
      TensorSpec::{
        name: b"b",
        dtype: 0,
        dims: [-1, -1],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
  )
  let interp = Interpreter::from_bytes(model, wb_opts())
  let dims : FixedArray[Int32] = [4]
  assert_eq(0, mb_tfl_resize_input(interp.interp, 0, dims, 1))
  assert_eq(1, mb_tfl_allocate_tensors(interp.interp))
  interp.close()
}

///|
test "wb resize_input rejects invalid dims" {
  let interp = Interpreter::from_bytes(wb_model_f32(), wb_opts())
  let empty : FixedArray[Int32] = []
  assert_eq(1, mb_tfl_resize_input(interp.interp, 0, empty, 0))
  let neg : FixedArray[Int32] = [1, -2]
  assert_eq(1, mb_tfl_resize_input(interp.interp, 0, neg, 2))
  let zero_dim : FixedArray[Int32] = [0, 4]
  assert_eq(1, mb_tfl_resize_input(interp.interp, 0, zero_dim, 2))
  let bad_index : FixedArray[Int32] = [1, 4]
  assert_eq(1, mb_tfl_resize_input(interp.interp, 5, bad_index, 2))
  interp.close()
}
