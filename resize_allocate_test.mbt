// 黑盒测试（R4，2026-11-09）：公开 API `Interpreter::{resize_input,
// allocate_tensors}` 的双路径语义与错误路径（stub 侧可验证部分）。
//
// 覆盖：
// - resize → allocate → set_input → invoke 全链路，动态输出维镜像 input 0；
// - resize 后未 allocate 即 invoke / output_raw / set_input → 状态码 2
//   （NOT_ALLOCATED；stub 专属语义，real 折叠为 1，见 docs/DESIGN.md §14.4）；
// - 尺寸不匹配（allocate 前后都按新张量字节数校验）→ BufferSizeMismatch；
// - 负维 / 零维 / 空 rank / rank>8 → ResizeFailed(1, _)（不 panic）；
// - 越界 index → InvalidTensorIndex；close 后调用 → AlreadyClosed；
// - allocate 形状冲突（rank 不足）→ AllocateTensorsFailed(1)；
// - 未 resize 直接 allocate 幂等，语义与 from_bytes 后全链路一致。

///|
/// 动态尺寸模型：输出 [-1, 4] 在 allocate_tensors 时镜像 input 0 的轴 0。
fn ra_model_dynamic() -> Bytes {
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
/// resize 成 [2,4] 后的 8 元素 f32 输入（1..8）。
fn ra_input_2x4() -> Bytes {
  f32_bytes([
    0x3F800000, 0x40000000, 0x40400000, 0x40800000, 0x40A00000, 0x40C00000, 0x40E00000,
    0x41000000,
  ])
}

///|
/// 期望输出（scale=2.0）：[2,4,6,8,10,12,14,16]。
fn ra_output_2x4() -> Bytes {
  f32_bytes([
    0x40000000, 0x40800000, 0x40C00000, 0x41000000, 0x41200000, 0x41400000, 0x41600000,
    0x41800000,
  ])
}

///|
/// 1 输入 1 输出、输出两轴均为动态的模型（allocate 需 input rank 2）。
fn ra_model_rank_conflict() -> Bytes {
  build_model(
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
}

///|
test "blackbox resize allocate flow mirrors dynamic output dims" {
  let interp = @tflite_ffi.Interpreter::from_bytes(ra_model_dynamic(), opts())
  interp.resize_input(0, [2, 4])
  interp.allocate_tensors()
  // allocate 后：输入 32 字节、输出动态维镜像为 [2, 4]
  interp.set_input(0, ra_input_2x4())
  interp.invoke()
  let desc = interp.output_desc(0)
  assert_eq("dyn_out", desc.name)
  assert_eq([2, 4], desc.shape)
  assert_eq(32, desc.byte_size)
  assert_true(interp.output_raw(0) == ra_output_2x4())
  interp.close()
}

///|
test "blackbox invoke before allocate after resize fails" {
  let interp = @tflite_ffi.Interpreter::from_bytes(ra_model_dynamic(), opts())
  interp.resize_input(0, [2, 4])
  let e1 = expect_err(() => interp.invoke())
  assert_true(e1 is @tflite_ffi.TfLiteError::InvokeFailed(2))
  let e2 = expect_err(() => ignore(interp.output_raw(0)))
  assert_true(e2 is @tflite_ffi.TfLiteError::CopyToBufferFailed(2))
  let e3 = expect_err(() => interp.set_input(0, ra_input_2x4()))
  assert_true(e3 is @tflite_ffi.TfLiteError::CopyFromBufferFailed(2))
  interp.close()
}

///|
test "blackbox resize buffer mismatch before and after allocate" {
  let interp = @tflite_ffi.Interpreter::from_bytes(ra_model_dynamic(), opts())
  interp.resize_input(0, [2, 4])
  // 未 allocate：先按 resize 后的新字节数（32）校验，长度不符立即报错
  let e1 = expect_err(() => interp.set_input(0, zeros(16)))
  assert_true(e1 is @tflite_ffi.TfLiteError::BufferSizeMismatch(32, 16))
  interp.allocate_tensors()
  let e2 = expect_err(() => interp.set_input(0, zeros(16)))
  assert_true(e2 is @tflite_ffi.TfLiteError::BufferSizeMismatch(32, 16))
  // 正确长度仍可写入并推理
  interp.set_input(0, ra_input_2x4())
  interp.invoke()
  assert_true(interp.output_raw(0) == ra_output_2x4())
  interp.close()
}

///|
test "blackbox resize rejects invalid dims" {
  let interp = @tflite_ffi.Interpreter::from_bytes(ra_model_dynamic(), opts())
  let empty : Array[Int32] = []
  let e1 = expect_err(() => interp.resize_input(0, empty))
  assert_true(e1 is @tflite_ffi.TfLiteError::ResizeFailed(1, _))
  let neg : Array[Int32] = [1, -2]
  let e2 = expect_err(() => interp.resize_input(0, neg))
  assert_true(e2 is @tflite_ffi.TfLiteError::ResizeFailed(1, _))
  let zero_dim : Array[Int32] = [0, 4]
  let e3 = expect_err(() => interp.resize_input(0, zero_dim))
  assert_true(e3 is @tflite_ffi.TfLiteError::ResizeFailed(1, _))
  let nine : Array[Int32] = [1, 1, 1, 1, 1, 1, 1, 1, 1]
  let e4 = expect_err(() => interp.resize_input(0, nine))
  assert_true(e4 is @tflite_ffi.TfLiteError::ResizeFailed(1, _))
  // 全部拒绝后解释器仍可用（畸形输入不 panic、不破坏状态）
  interp.set_input(
    0,
    f32_bytes([0x3F800000, 0x40000000, 0x40400000, 0x40800000]),
  )
  interp.invoke()
  interp.close()
}

///|
test "blackbox resize invalid tensor index" {
  let interp = @tflite_ffi.Interpreter::from_bytes(ra_model_dynamic(), opts())
  let dims : Array[Int32] = [1, 4]
  let e1 = expect_err(() => interp.resize_input(1, dims))
  assert_true(e1 is @tflite_ffi.TfLiteError::InvalidTensorIndex(1))
  let e2 = expect_err(() => interp.resize_input(-1, dims))
  assert_true(e2 is @tflite_ffi.TfLiteError::InvalidTensorIndex(-1))
  interp.close()
}

///|
test "blackbox resize allocate after close raises AlreadyClosed" {
  let interp = @tflite_ffi.Interpreter::from_bytes(ra_model_dynamic(), opts())
  interp.close()
  let dims : Array[Int32] = [1, 4]
  let e1 = expect_err(() => interp.resize_input(0, dims))
  assert_true(e1 is @tflite_ffi.TfLiteError::AlreadyClosed)
  let e2 = expect_err(() => interp.allocate_tensors())
  assert_true(e2 is @tflite_ffi.TfLiteError::AlreadyClosed)
}

///|
test "blackbox allocate fails on rank conflict" {
  let interp = @tflite_ffi.Interpreter::from_bytes(
    ra_model_rank_conflict(),
    opts(),
  )
  interp.resize_input(0, [4]) // rank 1，而输出 [-1,-1] 需要 input 至少 rank 2
  let e = expect_err(() => interp.allocate_tensors())
  assert_true(e is @tflite_ffi.TfLiteError::AllocateTensorsFailed(1))
  interp.close()
}

///|
test "blackbox allocate without resize is idempotent" {
  let interp = @tflite_ffi.Interpreter::from_bytes(model_f32(), opts())
  interp.allocate_tensors()
  interp.set_input(0, f32_input())
  interp.invoke()
  assert_true(interp.output_raw(0) == f32_output())
  interp.close()
}
