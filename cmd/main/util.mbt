///|
/// tflite-cli 公共辅助：帮助文本拼接、十六进制渲染、f32 解码、
/// 形状/dtype 渲染、正整数解析。仅使用 moonbitlang/core 与内置类型；
/// 不依赖外部库，不触碰 tflite_ffi 库内部 ABI。

///|
/// 文本行拼接（`\n` 分隔；帮助文本用）。
fn join_lines(lines : Array[String]) -> String {
  let mut s = ""
  let mut first = true
  for l in lines {
    if first {
      first = false
    } else {
      s = s + "\n"
    }
    s = s + l
  }
  s
}

///|
/// 两个十六进制数字（0..255，小写）。
fn hex2(v : Int32) -> String {
  let digits = "0123456789abcdef"
  let hi = (v >> 4) & 0xF
  let lo = v & 0xF
  digits[hi:hi + 1].to_owned() + digits[lo:lo + 1].to_owned()
}

///|
/// Bytes 渲染为小写十六进制串（无分隔符）。
fn bytes_hex(data : Bytes) -> String {
  let mut s = ""
  for i in 0..<data.length() {
    s = s + hex2(data[i].to_int())
  }
  s
}

///|
/// 2^e（e 为 Int32；循环乘除实现，避免额外依赖）。
fn pow2(e : Int32) -> Double {
  let mut v = 1.0
  if e >= 0 {
    let mut i = 0
    while i < e {
      v = v * 2.0
      i = i + 1
    }
  } else {
    let mut i = 0
    while i < -e {
      v = v / 2.0
      i = i + 1
    }
  }
  v
}

///|
/// IEEE754 f32 位型（小端 4 字节，起点 `off`）→ 十进制文本。
/// NaN/Inf 文本化（nan / inf / -inf）；其余按 f64 精确还原后 to_string。
fn f32_text(data : Bytes, off : Int32) -> String {
  let b0 = data[off].to_int()
  let b1 = data[off + 1].to_int()
  let b2 = data[off + 2].to_int()
  let b3 = data[off + 3].to_int()
  let bits = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
  let neg = bits < 0
  let u = bits & 0x7FFFFFFF
  let e = (u >> 23) & 0xFF
  let m = u & 0x7FFFFF
  if e == 255 {
    if m == 0 {
      if neg {
        "-inf"
      } else {
        "inf"
      }
    } else {
      "nan"
    }
  } else {
    let val = if e == 0 {
      m.to_double() * pow2(-149)
    } else {
      (1.0 + m.to_double() / 8388608.0) * pow2(e - 127)
    }
    if neg {
      (-val).to_string()
    } else {
      val.to_string()
    }
  }
}

///|
/// 输出张量字节 → 值文本：f32 输出解码为十进制序列（空格分隔），
/// 其余 dtype 输出小写十六进制（不做类型解释，保持确定性）。
fn output_values_text(data : Bytes, is_f32 : Bool) -> String {
  if is_f32 && data.length() % 4 == 0 && data.length() > 0 {
    let mut s = ""
    let mut first = true
    let mut off = 0
    while off < data.length() {
      if first {
        first = false
      } else {
        s = s + " "
      }
      s = s + f32_text(data, off)
      off = off + 4
    }
    s
  } else {
    bytes_hex(data)
  }
}

///|
/// 张量 dtype → 稳定小写标签（记录行渲染用）。
fn dtype_name(t : @tflite_ffi.TensorDtype) -> String {
  match t {
    @tflite_ffi.TensorDtype::Float32 => "f32"
    @tflite_ffi.TensorDtype::Float16 => "f16"
    @tflite_ffi.TensorDtype::Int32 => "i32"
    @tflite_ffi.TensorDtype::UInt8 => "u8"
    @tflite_ffi.TensorDtype::Int8 => "i8"
    @tflite_ffi.TensorDtype::Int64 => "i64"
  }
}

///|
/// 形状数组 → `1 4` 式空格分隔文本（空形状为空串）。
fn shape_text(shape : Array[Int32]) -> String {
  let mut s = ""
  let mut first = true
  for d in shape {
    if first {
      first = false
    } else {
      s = s + " "
    }
    s = s + d.to_string()
  }
  s
}

///|
/// 十进制正整数解析（`--threads`）；空串/非数字/非正/超上限返回 None。
fn parse_pos_int(s : String) -> Int32? {
  if s == "" {
    return None
  }
  let mut n = 0
  for c in s.iter() {
    let v = c.to_int()
    if v < 48 || v > 57 {
      return None
    }
    n = n * 10 + (v - 48)
    if n > 1000000 {
      return None
    }
  }
  if n < 1 {
    None
  } else {
    Some(n)
  }
}

///|
/// 构造 `n` 字节演示输入：以 1.0f32 位型（小端 00 00 80 3F）平铺，
/// 尾部不足 4 字节补 0。仅演示用途；数值黄金在 moon test 冻结。
fn demo_input(n : Int32) -> Bytes {
  let buf : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  let pat = [b'\x00', b'\x00', b'\x80', b'\x3F']
  let mut i = 0
  while i < n {
    buf[i] = pat[i % 4]
    i = i + 1
  }
  Bytes::from_array(buf)
}
