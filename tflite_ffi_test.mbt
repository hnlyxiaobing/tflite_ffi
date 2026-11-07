// Blackbox tests run against the package's public API. Use `@tflite_ffi` to import.
// 覆盖：from_bytes→set_input→invoke→output_raw/output_desc→close 全链路、
// 重复 close、未 invoke 读输出、越界 TensorIndex、缓冲不符、
// resize_input+allocate_tensors 流程、output_desc 形状/dtype 快照、
// 错误映射（ModelCreateFailed/InterpreterCreateFailed/InvalidTensorIndex/
// BufferSizeMismatch/CopyFromBufferFailed/CopyToBufferFailed/InvokeFailed/
// AlreadyClosed/UnsupportedDtype）。

///|
/// 测试辅助：STF1 stub 模型张量描述（格式见 `stub/README.md`）。
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
/// 构造 STF1 模型字节。
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
/// 按 f16 位模式构造张量字节。
fn f16_bytes(bits : Array[Int32]) -> Bytes {
  let buf : Array[Byte] = []
  for b in bits {
    buf.push((b & 0xFF).to_byte())
    buf.push(((b >> 8) & 0xFF).to_byte())
  }
  Bytes::from_array(buf[:])
}

///|
fn zeros(n : Int32) -> Bytes {
  Bytes::make(n, b'\x00')
}

///|
fn opts() -> @tflite_ffi.InterpreterOptions {
  @tflite_ffi.InterpreterOptions::{ thread_count: 1, allow_fp16: false, }
}

///|
/// 捕获 `raise TfLiteError` 的错误值（catch 绑定为通用 `Error` 类型）。
fn expect_err(f : () -> Unit raise @tflite_ffi.TfLiteError) -> Error {
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
fn model_f32() -> Bytes {
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
/// f32 输入 [1,2,3,4] 的位模式。
fn f32_input() -> Bytes {
  f32_bytes([0x3F800000, 0x40000000, 0x40400000, 0x40800000])
}

///|
/// scale=2.0 后期望输出 [2,4,6,8] 的位模式。
fn f32_output() -> Bytes {
  f32_bytes([0x40000000, 0x40800000, 0x40C00000, 0x41000000])
}

///|
test "blackbox full chain from_bytes set_input invoke output_raw output_desc close" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  assert_eq(1, interp.input_count)
  assert_eq(1, interp.output_count)
  let desc = interp.output_desc(0)
  assert_eq("out", desc.name)
  assert_true(desc.dtype is @tflite_ffi.TensorDtype::Float32)
  assert_eq([1, 4], desc.shape)
  assert_eq(16, desc.byte_size)
  assert_eq(0.0, desc.quantization.scale)
  assert_eq(0, desc.quantization.zero_point)
  interp.set_input(0, f32_input())
  interp.invoke()
  let out = interp.output_raw(0)
  assert_eq(16, out.length())
  assert_true(out == f32_output())
  interp.close()
  assert_true(interp.state is @tflite_ffi.InterpreterState::Closed)
}

///|
test "blackbox output_desc quantized snapshot" {
  let model = build_model(
    0x3F800000,
    [
      TensorSpec::{
        name: b"x",
        dtype: 0,
        dims: [2, 3],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
    [
      TensorSpec::{
        name: b"q_out",
        dtype: 4,
        dims: [1, 3],
        qscale_bits: 0x3E800000,
        qzero: -7,
      },
    ],
  )
  let interp = @tflite_ffi.Interpreter::from_bytes(model, opts())
  let desc = interp.output_desc(0)
  assert_eq("q_out", desc.name)
  assert_true(desc.dtype is @tflite_ffi.TensorDtype::Int8)
  assert_eq([1, 3], desc.shape)
  assert_eq(3, desc.byte_size)
  assert_eq(0.25, desc.quantization.scale)
  assert_eq(-7, desc.quantization.zero_point)
  interp.close()
}

///|
test "blackbox close twice raises AlreadyClosed" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  interp.close()
  let e = expect_err(() => interp.close())
  assert_true(e is @tflite_ffi.TfLiteError::AlreadyClosed)
  // 重复 close 不破坏状态：仍为 Closed
  assert_true(interp.state is @tflite_ffi.InterpreterState::Closed)
}

///|
test "blackbox use after close raises AlreadyClosed" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  interp.close()
  let e1 = expect_err(() => interp.set_input(0, f32_input()))
  assert_true(e1 is @tflite_ffi.TfLiteError::AlreadyClosed)
  let e2 = expect_err(() => ignore(interp.output_raw(0)))
  assert_true(e2 is @tflite_ffi.TfLiteError::AlreadyClosed)
  let e3 = expect_err(() => interp.invoke())
  assert_true(e3 is @tflite_ffi.TfLiteError::AlreadyClosed)
  let e4 = expect_err(() => ignore(interp.output_desc(0)))
  assert_true(e4 is @tflite_ffi.TfLiteError::AlreadyClosed)
}

///|
test "blackbox output before invoke is zeroed" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  let out = interp.output_raw(0)
  assert_eq(16, out.length())
  assert_true(out == zeros(16))
  interp.close()
}

///|
test "blackbox invalid tensor index" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  let e1 = expect_err(() => interp.set_input(1, f32_input()))
  assert_true(e1 is @tflite_ffi.TfLiteError::InvalidTensorIndex(1))
  let e2 = expect_err(() => interp.set_input(-1, f32_input()))
  assert_true(e2 is @tflite_ffi.TfLiteError::InvalidTensorIndex(-1))
  let e3 = expect_err(() => ignore(interp.output_raw(3)))
  assert_true(e3 is @tflite_ffi.TfLiteError::InvalidTensorIndex(3))
  let e4 = expect_err(() => ignore(interp.output_desc(-2)))
  assert_true(e4 is @tflite_ffi.TfLiteError::InvalidTensorIndex(-2))
  interp.close()
}

///|
test "blackbox buffer size mismatch" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  let e = expect_err(() => interp.set_input(0, zeros(8)))
  assert_true(e is @tflite_ffi.TfLiteError::BufferSizeMismatch(16, 8))
  let e2 = expect_err(() => interp.set_input(0, zeros(24)))
  assert_true(e2 is @tflite_ffi.TfLiteError::BufferSizeMismatch(16, 24))
  interp.close()
}

///|
/// 动态尺寸模型：输出 [-1, 4] 在 allocate_tensors 时镜像 input 0 的轴 0。
fn model_dynamic() -> Bytes {
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
test "blackbox resize_input and allocate_tensors flow" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_dynamic(), opts())
  let dims : FixedArray[Int32] = [2, 4]
  assert_eq(0, @tflite_ffi.mb_tfl_resize_input(interp.interp, 0, dims, 2))
  // resize 后缓冲失效：未 allocate 之前写入按 CopyFromBufferFailed 传播
  let input = f32_bytes([
    0x3F800000, 0x40000000, 0x40400000, 0x40800000, 0x40A00000, 0x40C00000, 0x40E00000,
    0x41000000,
  ])
  let e = expect_err(() => interp.set_input(0, input))
  assert_true(e is @tflite_ffi.TfLiteError::CopyFromBufferFailed(2))
  assert_eq(0, @tflite_ffi.mb_tfl_allocate_tensors(interp.interp))
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
test "blackbox ops before allocate after resize fail" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_dynamic(), opts())
  let dims : FixedArray[Int32] = [2, 4]
  assert_eq(0, @tflite_ffi.mb_tfl_resize_input(interp.interp, 0, dims, 2))
  let e1 = expect_err(() => interp.invoke())
  assert_true(e1 is @tflite_ffi.TfLiteError::InvokeFailed(2))
  let e2 = expect_err(() => ignore(interp.output_raw(0)))
  assert_true(e2 is @tflite_ffi.TfLiteError::CopyToBufferFailed(2))
  interp.close()
}

///|
test "blackbox allocate_tensors fails on rank conflict" {
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
  let interp = @tflite_ffi.Interpreter::from_bytes(model, opts())
  let dims : FixedArray[Int32] = [4]
  assert_eq(0, @tflite_ffi.mb_tfl_resize_input(interp.interp, 0, dims, 1))
  assert_eq(1, @tflite_ffi.mb_tfl_allocate_tensors(interp.interp))
  interp.close()
}

///|
test "blackbox resize_input rejects invalid dims" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  let empty : FixedArray[Int32] = []
  assert_eq(1, @tflite_ffi.mb_tfl_resize_input(interp.interp, 0, empty, 0))
  let neg : FixedArray[Int32] = [1, -2]
  assert_eq(1, @tflite_ffi.mb_tfl_resize_input(interp.interp, 0, neg, 2))
  let zero_dim : FixedArray[Int32] = [0, 4]
  assert_eq(1, @tflite_ffi.mb_tfl_resize_input(interp.interp, 0, zero_dim, 2))
  let bad_index : FixedArray[Int32] = [1, 4]
  assert_eq(1, @tflite_ffi.mb_tfl_resize_input(interp.interp, 5, bad_index, 2))
  interp.close()
}

///|
test "blackbox bad model bytes raise ModelCreateFailed" {
  let e1 = expect_err(() => {
    ignore(@tflite_ffi.Interpreter::from_bytes(b"", opts()))
  })
  assert_true(e1 is @tflite_ffi.TfLiteError::ModelCreateFailed(-1))
  let e2 = expect_err(() => {
    ignore(@tflite_ffi.Interpreter::from_bytes(b"XXXX garbage", opts()))
  })
  assert_true(e2 is @tflite_ffi.TfLiteError::ModelCreateFailed(-1))
  // 截断
  let full = model_f32()
  let trunc : Array[Byte] = []
  for i in 0..<(full.length() - 1) {
    trunc.push(full[i])
  }
  let e3 = expect_err(() => {
    ignore(
      @tflite_ffi.Interpreter::from_bytes(Bytes::from_array(trunc[:]), opts()),
    )
  })
  assert_true(e3 is @tflite_ffi.TfLiteError::ModelCreateFailed(-1))
  // 尾随字节
  let buf : Array[Byte] = []
  for i in 0..<full.length() {
    buf.push(full[i])
  }
  buf.push(b'\x00')
  let e4 = expect_err(() => {
    ignore(
      @tflite_ffi.Interpreter::from_bytes(Bytes::from_array(buf[:]), opts()),
    )
  })
  assert_true(e4 is @tflite_ffi.TfLiteError::ModelCreateFailed(-1))
}

///|
test "blackbox invalid thread count raises InterpreterCreateFailed" {
  let bad = @tflite_ffi.InterpreterOptions::{
    thread_count: 0,
    allow_fp16: false,
  }
  let e = expect_err(() => {
    ignore(@tflite_ffi.Interpreter::from_bytes(model_f32(), bad))
  })
  assert_true(e is @tflite_ffi.TfLiteError::InterpreterCreateFailed(-2))
}

///|
test "blackbox capi version is stable" {
  assert_eq(0x00010001, @tflite_ffi.mb_tfl_capi_version())
}

///|
test "blackbox fp16 requires allow_fp16 and computes deterministically" {
  let model = build_model(
    0x40000000,
    [
      TensorSpec::{
        name: b"h",
        dtype: 1,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
    [
      TensorSpec::{
        name: b"ho",
        dtype: 1,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
  )
  let e = expect_err(() => {
    ignore(@tflite_ffi.Interpreter::from_bytes(model, opts()))
  })
  assert_true(e is @tflite_ffi.TfLiteError::UnsupportedDtype(_))
  let ok = @tflite_ffi.InterpreterOptions::{
    thread_count: 1,
    allow_fp16: true,
  }
  let interp = @tflite_ffi.Interpreter::from_bytes(model, ok)
  let desc = interp.output_desc(0)
  assert_true(desc.dtype is @tflite_ffi.TensorDtype::Float16)
  assert_eq(4, desc.byte_size)
  interp.set_input(0, f16_bytes([0x3C00, 0x4000])) // [1.0, 2.0]
  interp.invoke()
  assert_true(interp.output_raw(0) == f16_bytes([0x4000, 0x4400])) // [2.0, 4.0]
  interp.close()
}

///|
test "blackbox multi input multi output pairing" {
  let model = build_model(
    0x40400000,
    [
      TensorSpec::{
        name: b"i0",
        dtype: 0,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
      TensorSpec::{
        name: b"i1",
        dtype: 0,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
    [
      TensorSpec::{
        name: b"o0",
        dtype: 0,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
      TensorSpec::{
        name: b"o1",
        dtype: 0,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
  )
  let interp = @tflite_ffi.Interpreter::from_bytes(model, opts())
  assert_eq(2, interp.input_count)
  assert_eq(2, interp.output_count)
  interp.set_input(0, f32_bytes([0x3F800000, 0x40000000])) // [1,2]
  interp.set_input(1, f32_bytes([0x3F000000, 0xBF800000])) // [0.5,-1]
  interp.invoke()
  // scale = 3.0；o0 源自 i0，o1 源自 i1
  assert_true(interp.output_raw(0) == f32_bytes([0x40400000, 0x40C00000]))
  assert_true(interp.output_raw(1) == f32_bytes([0x3FC00000, 0xC0400000]))
  let e = expect_err(() => interp.set_input(2, f32_input()))
  assert_true(e is @tflite_ffi.TfLiteError::InvalidTensorIndex(2))
  interp.close()
}

///|
/// 包外（测试包）为本地类型实现 `InferenceRuntime`：验证 `pub(open)` trait
/// 契约可被包外实现（组合根适配模式，DESIGN.md §3 / ADR-0004）。
struct RuntimeAdapter {
  interp : @tflite_ffi.Interpreter
}

///|
impl @tflite_ffi.InferenceRuntime for RuntimeAdapter with fn invoke(self) {
  self.interp.invoke()
}

///|
impl @tflite_ffi.InferenceRuntime for RuntimeAdapter with fn output_count(self) {
  self.interp.output_count
}

///|
test "blackbox InferenceRuntime trait is implementable outside the package" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  let rt = RuntimeAdapter::{ interp, }
  assert_eq(1, @tflite_ffi.InferenceRuntime::output_count(rt))
  interp.set_input(0, f32_input())
  @tflite_ffi.InferenceRuntime::invoke(rt)
  assert_true(interp.output_raw(0) == f32_output())
  interp.close()
}

///|
test "blackbox state machine transitions" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  assert_true(interp.state is @tflite_ffi.InterpreterState::Ready)
  interp.invoke()
  assert_true(interp.state is @tflite_ffi.InterpreterState::Ready)
  interp.close()
  assert_true(interp.state is @tflite_ffi.InterpreterState::Closed)
}
