// Whitebox tests run within the package scope.
// 覆盖内部映射：dtype 编码 → TensorDtype、版本断言常量、
// tensor_desc_of 的 NullHandle 错误映射（内部 shim 异常路径）。

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
