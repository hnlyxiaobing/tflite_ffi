///|
/// MoonBit 侧公开 API 的实现（API.md「MoonBit 侧公开 API」）。
/// 既有 6 个方法签名零变化；冻结前 P0 仅新增 3 个只读访问器
/// `Interpreter::{state, input_count, output_count}`（字段收紧为包私有后的包外读取通道）。
///
/// 状态机：`from_bytes` → `Ready`；`invoke` 期间 `Invoking`；`close` → `Closed`。
/// 资源生命周期（API.md 句柄表）：
/// - `model`：`from_bytes` 获取，`Interpreter::close` 释放（`owns_model = true`）；
/// - `options`：创建 interpreter 后立即由本层释放（生命周期最短）；
/// - `interpreter`：`Interpreter::close` 释放；
/// - `tensor`：借用句柄，不单独释放。
/// `from_bytes` 失败时由 `errdefer` 按创建逆序释放已获取的句柄。

///|
/// stub 打包版本断言值（与 `stub/mb_tfl_stub.c` 的 `MB_TFL_STUB_CAPI_VERSION` 一致）。
let expected_capi_version : Int32 = 0x00010001

///|
/// 内部 ABI：句柄存活探测（`stub/` 私有符号，不属于 API.md 的 17 个
/// `mb_tfl_*` shim，不出现在 `pkg.generated.mbti`）。真实库对接时映射到空指针检查。
extern "C" fn stub_model_alive(model : TfLiteModelRaw) -> Int32 = "tflite_ffi_private_model_alive"

///|
extern "C" fn stub_options_alive(options : TfLiteOptionsRaw) -> Int32 = "tflite_ffi_private_options_alive"

///|
extern "C" fn stub_interp_alive(interp : TfLiteInterpreterRaw) -> Int32 = "tflite_ffi_private_interp_alive"

///|
/// 内部 ABI：张量元数据查询（API.md `output_desc` 的「从 shim 取元数据」）。
/// 出参布局：`dims` = [rank, d0..d7]；`misc` = [dtype, byte_size, quant_zero,
/// name_len]；`qscale` = [量化 scale]；`name` = 名称字节（64 字节缓冲）。
#borrow(dims, misc, qscale, name)
extern "C" fn stub_tensor_meta(
  interp : TfLiteInterpreterRaw,
  index : Int32,
  is_output : Int32,
  dims : FixedArray[Int32],
  misc : FixedArray[Int32],
  qscale : FixedArray[Double],
  name : FixedArray[Byte],
) -> StatusCode = "tflite_ffi_private_tensor_meta"

///|
/// dtype 编码 → `TensorDtype`（stub STF1 编码，见 `stub/README.md`）。
fn dtype_of_code(code : Int32) -> TensorDtype raise TfLiteError {
  match code {
    0 => Float32
    1 => Float16
    2 => Int32
    3 => UInt8
    4 => Int8
    5 => Int64
    _ => raise UnsupportedDtype("unknown dtype code " + code.to_string())
  }
}

///|
/// STF1 张量名（UTF-8 字节）→ `String`。非法序列以 U+FFFD 替换
/// （名称来自本库 stub 的模型格式，合法模型不会触发替换）。
/// 不用 `Bytes::to_unchecked_string`：它按 UTF-16 重解释字节。
fn string_of_utf8(bytes : Bytes) -> String {
  let chars : Array[Char] = []
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b0 = bytes[i].to_int()
    if b0 < 0x80 {
      chars.push(b0.unsafe_to_char())
      i = i + 1
    } else if b0 < 0xC2 || b0 > 0xF4 {
      chars.push((0xFFFD).unsafe_to_char())
      i = i + 1
    } else if b0 < 0xE0 {
      if i + 1 < n && (bytes[i + 1].to_int() & 0xC0) == 0x80 {
        let b1 = bytes[i + 1].to_int()
        chars.push((((b0 & 0x1F) << 6) | (b1 & 0x3F)).unsafe_to_char())
        i = i + 2
      } else {
        chars.push((0xFFFD).unsafe_to_char())
        i = i + 1
      }
    } else if b0 < 0xF0 {
      if i + 2 < n &&
        (bytes[i + 1].to_int() & 0xC0) == 0x80 &&
        (bytes[i + 2].to_int() & 0xC0) == 0x80 {
        let b1 = bytes[i + 1].to_int()
        let b2 = bytes[i + 2].to_int()
        chars.push(
          (((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)).unsafe_to_char(),
        )
        i = i + 3
      } else {
        chars.push((0xFFFD).unsafe_to_char())
        i = i + 1
      }
    } else if i + 3 < n &&
      (bytes[i + 1].to_int() & 0xC0) == 0x80 &&
      (bytes[i + 2].to_int() & 0xC0) == 0x80 &&
      (bytes[i + 3].to_int() & 0xC0) == 0x80 {
      let b1 = bytes[i + 1].to_int()
      let b2 = bytes[i + 2].to_int()
      let b3 = bytes[i + 3].to_int()
      chars.push(
        (((b0 & 0x07) << 18) |
        ((b1 & 0x3F) << 12) |
        ((b2 & 0x3F) << 6) |
        (b3 & 0x3F)).unsafe_to_char(),
      )
      i = i + 4
    } else {
      chars.push((0xFFFD).unsafe_to_char())
      i = i + 1
    }
  }
  String::from_array(chars[:])
}

///|
/// 从 shim 取第 `index` 个张量的元数据快照；shim 异常（空句柄 / 越界）按
/// `NullHandle` 传播。
fn tensor_desc_of(
  interp : TfLiteInterpreterRaw,
  index : Int32,
  is_output : Bool,
) -> TensorDesc raise TfLiteError {
  let dims : FixedArray[Int32] = FixedArray::make(9, 0)
  let misc : FixedArray[Int32] = FixedArray::make(4, 0)
  let qscale : FixedArray[Double] = FixedArray::make(1, 0.0)
  let name_buf : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  let code = stub_tensor_meta(
    interp,
    index,
    if is_output {
      1
    } else {
      0
    },
    dims,
    misc,
    qscale,
    name_buf,
  )
  if code != 0 {
    raise NullHandle("tensor[" + index.to_string() + "]")
  }
  let rank = dims[0]
  let shape : Array[Int32] = Array::makei(rank, i => dims[1 + i])
  let name = string_of_utf8(Bytes::from_array(name_buf[0:misc[3]]))
  TensorDesc::{
    name,
    dtype: dtype_of_code(misc[0]),
    shape,
    byte_size: misc[1],
    quantization: Quantization::{ scale: qscale[0], zero_point: misc[2], },
  }
}

///|
/// 状态机守卫：`Closed` 后一切操作返回 `AlreadyClosed`。
fn ensure_open(interp : Interpreter) -> Unit raise TfLiteError {
  if interp.state is Closed {
    raise AlreadyClosed
  }
}

///|
/// 只读访问器（冻结前 P0 · 决策 5）：`Interpreter` 字段收紧为包私有后，
/// 包外读取状态机状态的唯一通道；无 setter，包外不可改写状态。
pub fn Interpreter::state(self : Interpreter) -> InterpreterState {
  self.state
}

///|
/// 只读访问器：输入张量数量快照（`from_bytes` 创建时取定，不可变）。
pub fn Interpreter::input_count(self : Interpreter) -> Int32 {
  self.input_count
}

///|
/// 只读访问器：输出张量数量快照（`from_bytes` 创建时取定，不可变）。
pub fn Interpreter::output_count(self : Interpreter) -> Int32 {
  self.output_count
}

///|
/// 从模型字节创建解释器。
///
/// - 获取资源：model / options / interpreter 三个 C 句柄；失败时按创建逆序释放。
/// - 返回：`Interpreter` 包装值，`owns_model = true`，`state = Ready`。
/// - 错误：`LibraryNotLoaded`（版本断言失败）、`ModelCreateFailed`（模型字节非法）、
///   `InterpreterCreateFailed`（options/线程数非法或创建失败）、`NullHandle`、
///   `UnsupportedDtype`（`allow_fp16 = false` 且模型含 Float16 张量）。
/// - 线程：调用线程本地；返回值可由其它线程持有，但 `invoke` 必须串行化。
pub fn Interpreter::from_bytes(
  model_bytes : Bytes,
  options : InterpreterOptions,
) -> Interpreter raise TfLiteError {
  let version = mb_tfl_capi_version()
  if version != expected_capi_version {
    raise LibraryNotLoaded(
      "mb_tfl_capi_version mismatch: got " +
      version.to_string() +
      ", expected " +
      expected_capi_version.to_string(),
    )
  }
  if options.thread_count < 1 {
    // -2：options.thread_count 非法（< 1）
    raise InterpreterCreateFailed(-2)
  }
  let model_h = mb_tfl_model_create(model_bytes, model_bytes.length())
  if stub_model_alive(model_h) == 0 {
    // -1：C shim 创建返回 NULL，无状态码
    raise ModelCreateFailed(-1)
  }
  errdefer mb_tfl_model_delete(model_h)
  let options_h = mb_tfl_options_create()
  if stub_options_alive(options_h) == 0 {
    raise NullHandle("options")
  }
  mb_tfl_options_set_threads(options_h, options.thread_count)
  let interp_h = mb_tfl_interpreter_create(model_h, options_h)
  // 释放点：创建 interpreter 后立即释放 options（API.md 句柄表）
  mb_tfl_options_delete(options_h)
  if stub_interp_alive(interp_h) == 0 {
    raise InterpreterCreateFailed(-1)
  }
  errdefer mb_tfl_interpreter_delete(interp_h)
  let input_count = mb_tfl_input_count(interp_h)
  let output_count = mb_tfl_output_count(interp_h)
  // 校验全部张量 dtype；Float16 需显式 allow_fp16
  for i in 0..<input_count {
    let desc = tensor_desc_of(interp_h, i, false)
    if desc.dtype is Float16 && !options.allow_fp16 {
      raise UnsupportedDtype(
        "Float16 input tensor \"" + desc.name + "\" requires allow_fp16 = true",
      )
    }
  }
  for i in 0..<output_count {
    let desc = tensor_desc_of(interp_h, i, true)
    if desc.dtype is Float16 && !options.allow_fp16 {
      raise UnsupportedDtype(
        "Float16 output tensor \"" + desc.name + "\" requires allow_fp16 = true",
      )
    }
  }
  Interpreter::{
    model: model_h,
    interp: interp_h,
    owns_model: true,
    state: Ready,
    input_count,
    output_count,
  }
}

///|
/// 释放全部 C 句柄并使包装值失效。close 语义（冻结前 P0 · 决策 8，与
/// API.md / DESIGN.md / README 统一）：**不会二次释放，重复调用返回明确错误**
/// （`AlreadyClosed`）：首次调用置 `state = Closed` 并释放，其后一律 raise。
/// 逆序释放：interpreter → model（options 已在 `from_bytes` 内释放）。
pub fn Interpreter::close(self : Interpreter) -> Unit raise TfLiteError {
  if self.state is Closed {
    raise AlreadyClosed
  }
  self.state = Closed
  mb_tfl_interpreter_delete(self.interp)
  if self.owns_model {
    mb_tfl_model_delete(self.model)
  }
}

///|
/// 动态调整第 `index` 个输入张量的形状（R4 加法性公开 API，2026-11-09）。
///
/// - **前置**：解释器未关闭；`index ∈ [0, input_count)`；`dims` 为 rank 1..8、
///   每维 ≥ 1 的具体尺寸（不支持 `-1` 动态维；动态维只允许出现在 STF1 的
///   输出描述里，由 `allocate_tensors` 镜像解析）。
/// - **后置**：该输入的形状更新，全部张量缓冲失效——必须再调用
///   `allocate_tensors` 才能 `set_input` / `invoke`（stub 未 allocate 时返回
///   状态码 2，映射为 `CopyFromBufferFailed(2)` / `InvokeFailed(2)` /
///   `CopyToBufferFailed(2)`）。
/// - **错误**：`AlreadyClosed`、`InvalidTensorIndex`、`ResizeFailed(code, detail)`
///   （dims 非法或后端拒绝 resize）。
/// - **平台语义**：stub 允许改变 rank；real TFLite 要求 rank 与模型签名一致，
///   不符时折叠为 `ResizeFailed(1, ...)`（双路径差异见 DESIGN.md §14.4）。
pub fn Interpreter::resize_input(
  self : Interpreter,
  index : TensorIndex,
  dims : Array[Int32],
) -> Unit raise TfLiteError {
  ensure_open(self)
  if index < 0 || index >= self.input_count {
    raise InvalidTensorIndex(index)
  }
  let rank = dims.length()
  if rank < 1 || rank > 8 {
    raise ResizeFailed(
      1,
      "rank " + rank.to_string() + " out of supported range 1..8",
    )
  }
  for i in 0..<rank {
    if dims[i] < 1 {
      raise ResizeFailed(
        1,
        "dims[" + i.to_string() + "] = " + dims[i].to_string() + " must be >= 1",
      )
    }
  }
  let c_dims : FixedArray[Int32] = FixedArray::make(rank, 0)
  for i in 0..<rank {
    c_dims[i] = dims[i]
  }
  let code = mb_tfl_resize_input(self.interp, index, c_dims, rank)
  if code != 0 {
    raise ResizeFailed(
      code,
      "resize_input(index=" + index.to_string() + ") failed",
    )
  }
}

///|
/// 分配/重新分配全部张量（R4 加法性公开 API，2026-11-09）。
///
/// 必须在 `resize_input` 之后调用；`from_bytes` 已隐式完成首次分配，因此
/// 未 resize 时调用等价于按当前形状重新分配（幂等，stub 与 real 均可）。
/// 错误：`AlreadyClosed`、`AllocateTensorsFailed(code)`（形状冲突/后端拒绝）。
pub fn Interpreter::allocate_tensors(
  self : Interpreter,
) -> Unit raise TfLiteError {
  ensure_open(self)
  let code = mb_tfl_allocate_tensors(self.interp)
  if code != 0 {
    raise AllocateTensorsFailed(code)
  }
}

///|
/// 写入第 `index` 个输入张量（`data` 只读，长度必须等于张量字节数）。
pub fn Interpreter::set_input(
  self : Interpreter,
  index : TensorIndex,
  data : Bytes,
) -> Unit raise TfLiteError {
  ensure_open(self)
  if index < 0 || index >= self.input_count {
    raise InvalidTensorIndex(index)
  }
  let desc = tensor_desc_of(self.interp, index, false)
  if data.length() != desc.byte_size {
    raise BufferSizeMismatch(desc.byte_size, data.length())
  }
  let tensor = mb_tfl_input_tensor(self.interp, index)
  let code = mb_tfl_tensor_copy_from(tensor, data, data.length())
  if code != 0 {
    raise CopyFromBufferFailed(code)
  }
}

///|
/// 读取第 `index` 个输出张量，返回原始字节（不做类型解释）。
/// `invoke` 之前输出缓冲为全 0（stub 语义：allocate 时零初始化）。
pub fn Interpreter::output_raw(
  self : Interpreter,
  index : TensorIndex,
) -> Bytes raise TfLiteError {
  ensure_open(self)
  if index < 0 || index >= self.output_count {
    raise InvalidTensorIndex(index)
  }
  let desc = tensor_desc_of(self.interp, index, true)
  let buf : FixedArray[Byte] = FixedArray::make(desc.byte_size, b'\x00')
  let tensor = mb_tfl_output_tensor(self.interp, index)
  let code = mb_tfl_tensor_copy_to(tensor, buf, desc.byte_size)
  if code != 0 {
    raise CopyToBufferFailed(code)
  }
  Bytes::from_array(buf)
}

///|
/// 执行一次同步推理（同一 `Interpreter` 不可并发）。
/// 逻辑直接实现于本方法，本包不提供任何 trait 接口
/// （原 `InferenceRuntime` 已于冻结前 P0 删除，决策 2）；
/// 后端抽象由 `pose::PoseBackend` 承担，由组合根适配（DESIGN.md §3）。
pub fn Interpreter::invoke(self : Interpreter) -> Unit raise TfLiteError {
  ensure_open(self)
  self.state = Invoking
  errdefer {
    self.state = Ready
  }
  let code = mb_tfl_invoke(self.interp)
  if code != 0 {
    raise InvokeFailed(code)
  }
  self.state = Ready
}

///|
/// 返回输出张量描述（形状 / dtype / 字节数 / 量化 / 名称快照）。
pub fn Interpreter::output_desc(
  self : Interpreter,
  index : TensorIndex,
) -> TensorDesc raise TfLiteError {
  ensure_open(self)
  if index < 0 || index >= self.output_count {
    raise InvalidTensorIndex(index)
  }
  tensor_desc_of(self.interp, index, true)
}
