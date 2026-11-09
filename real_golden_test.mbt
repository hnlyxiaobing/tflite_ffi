// 黑盒黄金测试（自产微型模型，数据口径见 tests/fixtures/golden/ASSETS.md；
// 黄金链命名对齐 2026-11-08）。
//
// 两个用例前缀：
//   "golden tflite"（非 #skip）—— 生成器字节重建 + SHA-256 登记断言（零入库证据链：
//     测试内嵌生成器重建字节并断言 SHA-256 == ASSETS.md 登记值，模型二进制
//     零入库）+ stub 侧 STF1 镜像数值黄金（stub 链 `moon test -f "golden tflite*"`）。
//   "golden real"（#skip）—— 真实后端 + micro_mul_f32.tflite（TFL3）数值黄金，
//     联跑 `moon test --include-skipped -f "golden real*"`；首行断言
//     backend_name()=="real"（不满足即 fail，绝不静默跳过）。CI 无真实库时
//     默认 SKIPPED 不计通过（#skip 用例不计入 Total tests，MoonBit 原生机制）。
//
// 数值容差（冻结口径，逐元素 f32，见 tests/fixtures/golden/ASSETS.md §2）：
// |got − want| ≤ 1e-6 + 1e-5 × |want|（f64 比较；NaN=NaN bit 相等；±0 等价；
// Inf bit 相等）。容差超限=失败，不得放宽。
//
// 参考输出=独立解析计算：verify_micro_tflite 以内嵌 mini flatbuffer 解析器
// 抽取常量 w 并校验 TFL3 结构，want = f32(f64(in) × f64(w))，与登记 hex 互证。

///|
/// ---- SHA-256（FIPS 180-4，自实现；Int64 位运算 + 32 位掩码）----
fn sha_rotr(x : Int64, n : Int32) -> Int64 {
  ((x >> n) | (x << (32 - n))) & 0xFFFFFFFFL
}

///|
fn sha256_digest(msg : Bytes) -> Array[Int64] {
  let k : Array[Int64] = [
    0x428a2f98L, 0x71374491L, 0xb5c0fbcfL, 0xe9b5dba5L, 0x3956c25bL, 0x59f111f1L,
    0x923f82a4L, 0xab1c5ed5L, 0xd807aa98L, 0x12835b01L, 0x243185beL, 0x550c7dc3L,
    0x72be5d74L, 0x80deb1feL, 0x9bdc06a7L, 0xc19bf174L, 0xe49b69c1L, 0xefbe4786L,
    0x0fc19dc6L, 0x240ca1ccL, 0x2de92c6fL, 0x4a7484aaL, 0x5cb0a9dcL, 0x76f988daL,
    0x983e5152L, 0xa831c66dL, 0xb00327c8L, 0xbf597fc7L, 0xc6e00bf3L, 0xd5a79147L,
    0x06ca6351L, 0x14292967L, 0x27b70a85L, 0x2e1b2138L, 0x4d2c6dfcL, 0x53380d13L,
    0x650a7354L, 0x766a0abbL, 0x81c2c92eL, 0x92722c85L, 0xa2bfe8a1L, 0xa81a664bL,
    0xc24b8b70L, 0xc76c51a3L, 0xd192e819L, 0xd6990624L, 0xf40e3585L, 0x106aa070L,
    0x19a4c116L, 0x1e376c08L, 0x2748774cL, 0x34b0bcb5L, 0x391c0cb3L, 0x4ed8aa4aL,
    0x5b9cca4fL, 0x682e6ff3L, 0x748f82eeL, 0x78a5636fL, 0x84c87814L, 0x8cc70208L,
    0x90befffaL, 0xa4506cebL, 0xbef9a3f7L, 0xc67178f2L,
  ]
  let h : FixedArray[Int64] = [
    0x6a09e667L, 0xbb67ae85L, 0x3c6ef372L, 0xa54ff53aL, 0x510e527fL, 0x9b05688cL,
    0x1f83d9abL, 0x5be0cd19L,
  ]
  // 填充：0x80 + 零 + 64 位大端比特长度（本测试输入 < 2^29 字节）
  let m : Array[Byte] = []
  for i in 0..<msg.length() {
    m.push(msg[i])
  }
  m.push(b'\x80')
  while m.length() % 64 != 56 {
    m.push(b'\x00')
  }
  let bit_len = msg.length() * 8
  m.push(b'\x00')
  m.push(b'\x00')
  m.push(b'\x00')
  m.push(b'\x00')
  m.push(((bit_len >> 24) & 0xFF).to_byte())
  m.push(((bit_len >> 16) & 0xFF).to_byte())
  m.push(((bit_len >> 8) & 0xFF).to_byte())
  m.push((bit_len & 0xFF).to_byte())
  let w : FixedArray[Int64] = FixedArray::make(64, 0L)
  let mut off = 0
  while off < m.length() {
    for t = 0; t < 16; t = t + 1 {
      let p = off + t * 4
      w[t] = ((m[p].to_int64() & 0xFFL) << 24) |
        ((m[p + 1].to_int64() & 0xFFL) << 16) |
        ((m[p + 2].to_int64() & 0xFFL) << 8) |
        (m[p + 3].to_int64() & 0xFFL)
    }
    for t = 16; t < 64; t = t + 1 {
      let s0 = sha_rotr(w[t - 15], 7)
        .lxor(sha_rotr(w[t - 15], 18))
        .lxor(w[t - 15] >> 3)
      let s1 = sha_rotr(w[t - 2], 17)
        .lxor(sha_rotr(w[t - 2], 19))
        .lxor(w[t - 2] >> 10)
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xFFFFFFFFL
    }
    let mut a = h[0]
    let mut b = h[1]
    let mut c = h[2]
    let mut d = h[3]
    let mut e = h[4]
    let mut f = h[5]
    let mut g = h[6]
    let mut hh = h[7]
    for t = 0; t < 64; t = t + 1 {
      let s1 = sha_rotr(e, 6).lxor(sha_rotr(e, 11)).lxor(sha_rotr(e, 25))
      let ch = (e & f).lxor(e.lnot() & 0xFFFFFFFFL & g)
      let t1 = (hh + s1 + ch + k[t] + w[t]) & 0xFFFFFFFFL
      let s0 = sha_rotr(a, 2).lxor(sha_rotr(a, 13)).lxor(sha_rotr(a, 22))
      let maj = (a & b).lxor(a & c).lxor(b & c)
      let t2 = (s0 + maj) & 0xFFFFFFFFL
      hh = g
      g = f
      f = e
      e = (d + t1) & 0xFFFFFFFFL
      d = c
      c = b
      b = a
      a = (t1 + t2) & 0xFFFFFFFFL
    }
    h[0] = (h[0] + a) & 0xFFFFFFFFL
    h[1] = (h[1] + b) & 0xFFFFFFFFL
    h[2] = (h[2] + c) & 0xFFFFFFFFL
    h[3] = (h[3] + d) & 0xFFFFFFFFL
    h[4] = (h[4] + e) & 0xFFFFFFFFL
    h[5] = (h[5] + f) & 0xFFFFFFFFL
    h[6] = (h[6] + g) & 0xFFFFFFFFL
    h[7] = (h[7] + hh) & 0xFFFFFFFFL
    off = off + 64
  }
  [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]]
}

///|
/// 十六进制小写数字字符。
fn hex_char(n : Int32) -> Char {
  if n < 10 {
    (48 + n).unsafe_to_char()
  } else {
    (87 + n).unsafe_to_char()
  }
}

///|
/// SHA-256 十六进制（小写）。
fn sha256_hex(msg : Bytes) -> String {
  let digest = sha256_digest(msg)
  let out : Array[Char] = []
  for i = 0; i < 8; i = i + 1 {
    let v = digest[i]
    for s = 28; s >= 0; s = s - 4 {
      let nib = ((v >> s) & 0xFL).to_int()
      out.push(hex_char(nib))
    }
  }
  String::from_array(out[:])
}

///|
/// ---- 迷你 flatbuffer 反向构造器（与 tools/gen-micro-model.ps1 逐字节同构）----
/// 规范见脚本头注释：alloc(size, align) 先补零至 (已写 + size) % align == 0；
/// 字符串先预补零使内容块结束于 4 边界；表字段按 id 升序写入；vtable 在表体
/// 之后写出（soffset = table_pos - vtable_pos > 0）；结尾 pad 至 已写 % 16 == 8
/// 后写 "TFL3" 标识与根 uoffset，总长 % 16 == 0。
struct FBuf {
  buf : FixedArray[Byte]
  mut pos : Int32
  field_pos : FixedArray[Int32]
  field_size : FixedArray[Int32]
  mut field_count : Int32
}

///|
fn FBuf::new() -> FBuf {
  FBuf::{
    buf: FixedArray::make(8192, b'\x00'),
    pos: 8192,
    field_pos: FixedArray::make(32, 0),
    field_size: FixedArray::make(32, 0),
    field_count: 0,
  }
}

///|
fn FBuf::written(self : FBuf) -> Int32 {
  self.buf.length() - self.pos
}

///|
fn FBuf::put_u8(self : FBuf, p : Int32, v : Int32) -> Unit {
  self.buf[p] = (v & 0xFF).to_byte()
}

///|
fn FBuf::put_u16(self : FBuf, p : Int32, v : Int32) -> Unit {
  self.buf[p] = (v & 0xFF).to_byte()
  self.buf[p + 1] = ((v >> 8) & 0xFF).to_byte()
}

///|
fn FBuf::put_u32(self : FBuf, p : Int32, v : Int32) -> Unit {
  self.buf[p] = (v & 0xFF).to_byte()
  self.buf[p + 1] = ((v >> 8) & 0xFF).to_byte()
  self.buf[p + 2] = ((v >> 16) & 0xFF).to_byte()
  self.buf[p + 3] = ((v >> 24) & 0xFF).to_byte()
}

///|
fn FBuf::alloc(self : FBuf, s : Int32, n : Int32) -> Int32 {
  while (self.written() + s) % n != 0 {
    self.pos = self.pos - 1
    self.buf[self.pos] = b'\x00'
  }
  self.pos = self.pos - s
  self.pos
}

///|
/// 字符串对象 [u32 len][bytes][NUL]；返回 len 字段位置。
fn FBuf::emit_string(self : FBuf, s : Bytes) -> Int32 {
  while (self.written() + s.length() + 1) % 4 != 0 {
    self.pos = self.pos - 1
    self.buf[self.pos] = b'\x00'
  }
  ignore(self.alloc(1, 1))
  self.buf[self.pos] = b'\x00'
  for i = s.length() - 1; i >= 0; i = i - 1 {
    ignore(self.alloc(1, 1))
    self.buf[self.pos] = s[i]
  }
  let p = self.alloc(4, 4)
  self.put_u32(p, s.length())
  p
}

///|
/// int32 向量 [u32 len][i32 * len]；返回 len 字段位置。
fn FBuf::emit_i32_vector(self : FBuf, vals : Array[Int32]) -> Int32 {
  for i = vals.length() - 1; i >= 0; i = i - 1 {
    let p = self.alloc(4, 4)
    self.put_u32(p, vals[i])
  }
  let p = self.alloc(4, 4)
  self.put_u32(p, vals.length())
  p
}

///|
/// 表偏移向量 [u32 len][uoffset32 * len]；返回 len 字段位置。
fn FBuf::emit_offset_vector(self : FBuf, child : Array[Int32]) -> Int32 {
  for i = child.length() - 1; i >= 0; i = i - 1 {
    let p = self.alloc(4, 4)
    self.put_u32(p, child[i] - p)
  }
  let p = self.alloc(4, 4)
  self.put_u32(p, child.length())
  p
}

///|
/// ubyte 向量（data 起点按 align 对齐，Buffer.data force_align=16）。
fn FBuf::emit_bytes_vector(self : FBuf, data : Bytes, align : Int32) -> Int32 {
  while (self.written() + data.length()) % align != 0 {
    self.pos = self.pos - 1
    self.buf[self.pos] = b'\x00'
  }
  self.pos = self.pos - data.length()
  for i in 0..<data.length() {
    self.buf[self.pos + i] = data[i]
  }
  let p = self.alloc(4, 4)
  self.put_u32(p, data.length())
  p
}

///|
fn FBuf::start_table(self : FBuf) -> Unit {
  for i = 0; i < 32; i = i + 1 {
    self.field_pos[i] = 0
    self.field_size[i] = 0
  }
  self.field_count = 0
}

///|
fn FBuf::note_field(self : FBuf, id : Int32, p : Int32, size : Int32) -> Unit {
  self.field_pos[id] = p
  self.field_size[id] = size
  if id + 1 > self.field_count {
    self.field_count = id + 1
  }
}

///|
fn FBuf::add_u8(self : FBuf, id : Int32, v : Int32) -> Unit {
  let p = self.alloc(1, 1)
  self.put_u8(p, v)
  self.note_field(id, p, 1)
}

///|
fn FBuf::add_u32(self : FBuf, id : Int32, v : Int32) -> Unit {
  let p = self.alloc(4, 4)
  self.put_u32(p, v)
  self.note_field(id, p, 4)
}

///|
fn FBuf::add_offset(self : FBuf, id : Int32, child : Int32) -> Unit {
  let p = self.alloc(4, 4)
  self.put_u32(p, child - p)
  self.note_field(id, p, 4)
}

///|
/// 结束表：写表体 soffset 占位 + vtable，返回表位置。
fn FBuf::end_table(self : FBuf) -> Int32 {
  let t = self.alloc(4, 4)
  self.put_u32(t, 0)
  let mut obj_size = 4
  for i = 0; i < self.field_count; i = i + 1 {
    if self.field_pos[i] != 0 {
      let end = self.field_pos[i] + self.field_size[i] - t
      if end > obj_size {
        obj_size = end
      }
    }
  }
  for i = self.field_count - 1; i >= 0; i = i - 1 {
    let p = self.alloc(2, 2)
    if self.field_pos[i] != 0 {
      self.put_u16(p, self.field_pos[i] - t)
    } else {
      self.put_u16(p, 0)
    }
  }
  let p = self.alloc(2, 2)
  self.put_u16(p, obj_size)
  let vp = self.alloc(2, 2)
  self.put_u16(vp, 4 + 2 * self.field_count)
  self.put_u32(t, t - vp)
  t
}

///|
/// 结尾：pad -> "TFL3" 标识 -> 根 uoffset，输出最终字节。
fn FBuf::finish(self : FBuf, root : Int32) -> Bytes {
  while self.written() % 16 != 8 {
    self.pos = self.pos - 1
    self.buf[self.pos] = b'\x00'
  }
  let p = self.alloc(4, 1)
  self.buf[p] = b'\x54' // 'T'
  self.buf[p + 1] = b'\x46' // 'F'
  self.buf[p + 2] = b'\x4C' // 'L'
  self.buf[p + 3] = b'\x33' // '3'
  let p_root = self.alloc(4, 4)
  self.put_u32(p_root, root - p_root)
  Bytes::from_array(self.buf[self.pos:self.buf.length()])
}

///|
/// micro_mul_f32.tflite（TFL3）内嵌生成器。
/// 发射顺序与 tools/gen-micro-model.ps1 一致（逐字节断言见 registry 用例）。
fn micro_mul_f32_tflite() -> Bytes {
  let fb = FBuf::new()
  let desc = fb.emit_string(b"micro_mul_f32")
  // Buffer 0 = 空哨兵
  fb.start_table()
  let buf0 = fb.end_table()
  // Buffer 1 = 常量 w [0.5, 1.0, 2.0, -1.0] f32 LE
  let w : Array[Byte] = []
  fn push_f32_bits(bits : Int32) {
    w.push((bits & 0xFF).to_byte())
    w.push(((bits >> 8) & 0xFF).to_byte())
    w.push(((bits >> 16) & 0xFF).to_byte())
    w.push(((bits >> 24) & 0xFF).to_byte())
  }
  push_f32_bits(0x3F000000) // 0.5
  push_f32_bits(0x3F800000) // 1.0
  push_f32_bits(0x40000000) // 2.0
  push_f32_bits(0xBF800000) // -1.0
  let data_vec = fb.emit_bytes_vector(Bytes::from_array(w[:]), 16)
  fb.start_table()
  fb.add_offset(0, data_vec)
  let buf1 = fb.end_table()
  let buffers = fb.emit_offset_vector([buf0, buf1])
  // Tensor 0: "in" [1,4] FLOAT32 buffer 0
  let t0_name = fb.emit_string(b"in")
  let t0_shape = fb.emit_i32_vector([1, 4])
  fb.start_table()
  fb.add_offset(0, t0_shape)
  fb.add_u8(1, 0)
  fb.add_u32(2, 0)
  fb.add_offset(3, t0_name)
  let t0 = fb.end_table()
  // Tensor 1: "w" [4] FLOAT32 buffer 1
  let t1_name = fb.emit_string(b"w")
  let t1_shape = fb.emit_i32_vector([4])
  fb.start_table()
  fb.add_offset(0, t1_shape)
  fb.add_u8(1, 0)
  fb.add_u32(2, 1)
  fb.add_offset(3, t1_name)
  let t1 = fb.end_table()
  // Tensor 2: "out" [1,4] FLOAT32 buffer 0
  let t2_name = fb.emit_string(b"out")
  let t2_shape = fb.emit_i32_vector([1, 4])
  fb.start_table()
  fb.add_offset(0, t2_shape)
  fb.add_u8(1, 0)
  fb.add_u32(2, 0)
  fb.add_offset(3, t2_name)
  let t2 = fb.end_table()
  let tensors = fb.emit_offset_vector([t0, t1, t2])
  // MUL 算子：MulOptions（builtin_options_type=21，空表 = fused NONE 缺省）
  fb.start_table()
  let mul_opts = fb.end_table()
  let op_inputs = fb.emit_i32_vector([0, 1])
  let op_outputs = fb.emit_i32_vector([2])
  fb.start_table()
  fb.add_u32(0, 0)
  fb.add_offset(1, op_inputs)
  fb.add_offset(2, op_outputs)
  fb.add_u8(3, 21)
  fb.add_offset(4, mul_opts)
  let op = fb.end_table()
  let operators = fb.emit_offset_vector([op])
  let sg_inputs = fb.emit_i32_vector([0])
  let sg_outputs = fb.emit_i32_vector([2])
  let sg_name = fb.emit_string(b"main")
  fb.start_table()
  fb.add_offset(0, tensors)
  fb.add_offset(1, sg_inputs)
  fb.add_offset(2, sg_outputs)
  fb.add_offset(3, operators)
  fb.add_offset(4, sg_name)
  let sg = fb.end_table()
  let subgraphs = fb.emit_offset_vector([sg])
  // OperatorCode: deprecated_builtin_code=18(MUL), version=1, builtin_code=18
  fb.start_table()
  fb.add_u8(0, 18)
  fb.add_u32(2, 1)
  fb.add_u32(3, 18)
  let opcode = fb.end_table()
  let opcodes = fb.emit_offset_vector([opcode])
  // Model: version=3
  fb.start_table()
  fb.add_u32(0, 3)
  fb.add_offset(1, opcodes)
  fb.add_offset(2, subgraphs)
  fb.add_offset(3, desc)
  fb.add_offset(4, buffers)
  let root = fb.end_table()
  fb.finish(root)
}

///|
/// micro_mul_f32.stf1（STF1 镜像，stub 后端用）：与 tools/gen-micro-model.ps1
/// 逐字节一致。scale=1.0 恒等（STF1 仅标量 scale，无法表达 MUL 权重逐元素
/// 语义，见 docs/DESIGN.md 双路径语义差异登记）。
fn micro_mul_f32_stf1() -> Bytes {
  let buf : Array[Byte] = []
  fn push_u32(v : Int32) {
    buf.push((v & 0xFF).to_byte())
    buf.push(((v >> 8) & 0xFF).to_byte())
    buf.push(((v >> 16) & 0xFF).to_byte())
    buf.push(((v >> 24) & 0xFF).to_byte())
  }
  fn push_tensor(name : Bytes) {
    push_u32(name.length())
    for i in 0..<name.length() {
      buf.push(name[i])
    }
    push_u32(0) // dtype Float32
    push_u32(2) // rank 2
    push_u32(1) // dim 1
    push_u32(4) // dim 4
    push_u32(0) // qscale
    push_u32(0) // qzero
  }
  push_u32(0x31465453) // magic "STF1"
  push_u32(1) // version
  push_u32(1) // input_count
  push_u32(1) // output_count
  push_u32(0x3F800000) // scale 1.0（镜像恒等）
  push_tensor(b"in")
  push_tensor(b"out")
  Bytes::from_array(buf[:])
}

///|
/// ---- 独立 mini flatbuffer 解析（参考输出=独立解析计算的证据）----
fn fb_u32(data : Bytes, p : Int32) -> Int32 {
  data[p].to_int() |
  (data[p + 1].to_int() << 8) |
  (data[p + 2].to_int() << 16) |
  (data[p + 3].to_int() << 24)
}

///|
fn fb_u16(data : Bytes, p : Int32) -> Int32 {
  data[p].to_int() | (data[p + 1].to_int() << 8)
}

///|
/// 表字段值位置；-1 = 缺席。
fn fb_field(data : Bytes, t : Int32, id : Int32) -> Int32 {
  let vt = t - fb_u32(data, t)
  let vs = fb_u16(data, vt)
  if 4 + 2 * id >= vs {
    return -1
  }
  let o = fb_u16(data, vt + 4 + 2 * id)
  if o == 0 {
    return -1
  }
  t + o
}

///|
fn fb_vec_len(data : Bytes, p : Int32) -> Int32 {
  fb_u32(data, p + fb_u32(data, p))
}

///|
fn fb_vec_i32(data : Bytes, p : Int32, i : Int32) -> Int32 {
  fb_u32(data, p + fb_u32(data, p) + 4 + 4 * i)
}

///|
fn fb_vec_off(data : Bytes, p : Int32, i : Int32) -> Int32 {
  let e = p + fb_u32(data, p) + 4 + 4 * i
  e + fb_u32(data, e)
}

///|
fn fb_str_eq(data : Bytes, p : Int32, want : Bytes) -> Bool {
  let v = p + fb_u32(data, p)
  let n = fb_u32(data, v)
  if n != want.length() {
    return false
  }
  for i = 0; i < n; i = i + 1 {
    if data[v + 4 + i] != want[i] {
      return false
    }
  }
  true
}

///|
/// 独立解析 micro_mul_f32.tflite：校验 TFL3 结构并返回常量 w（f64 值）。
fn verify_micro_tflite(data : Bytes) -> Array[Double] raise {
  assert_eq(0x54, data[4].to_int(), msg="TFL3 标识 'T'")
  assert_eq(0x46, data[5].to_int(), msg="TFL3 标识 'F'")
  assert_eq(0x4C, data[6].to_int(), msg="TFL3 标识 'L'")
  assert_eq(0x33, data[7].to_int(), msg="TFL3 标识 '3'")
  let root = fb_u32(data, 0)
  assert_eq(3, fb_u32(data, fb_field(data, root, 0)), msg="Model.version")
  assert_true(
    fb_str_eq(data, fb_field(data, root, 3), b"micro_mul_f32"),
    msg="Model.description",
  )
  let sg = fb_vec_off(data, fb_field(data, root, 2), 0)
  assert_true(
    fb_str_eq(data, fb_field(data, sg, 4), b"main"),
    msg="SubGraph.name",
  )
  let tensors = fb_field(data, sg, 0)
  assert_eq(3, fb_vec_len(data, tensors), msg="tensor count")
  let t0 = fb_vec_off(data, tensors, 0)
  assert_true(fb_str_eq(data, fb_field(data, t0, 3), b"in"), msg="t0 name")
  assert_eq(0, data[fb_field(data, t0, 1)].to_int(), msg="t0 type FLOAT32")
  assert_eq(0, fb_u32(data, fb_field(data, t0, 2)), msg="t0 buffer")
  let t1 = fb_vec_off(data, tensors, 1)
  assert_true(fb_str_eq(data, fb_field(data, t1, 3), b"w"), msg="t1 name")
  assert_eq(1, fb_u32(data, fb_field(data, t1, 2)), msg="t1 buffer")
  let t2 = fb_vec_off(data, tensors, 2)
  assert_true(fb_str_eq(data, fb_field(data, t2, 3), b"out"), msg="t2 name")
  let sg_in = fb_field(data, sg, 1)
  let sg_out = fb_field(data, sg, 2)
  assert_eq(1, fb_vec_len(data, sg_in), msg="subgraph inputs len")
  assert_eq(0, fb_vec_i32(data, sg_in, 0), msg="subgraph input index")
  assert_eq(1, fb_vec_len(data, sg_out), msg="subgraph outputs len")
  assert_eq(2, fb_vec_i32(data, sg_out, 0), msg="subgraph output index")
  let ops = fb_field(data, sg, 3)
  let op = fb_vec_off(data, ops, 0)
  let op_in = fb_field(data, op, 1)
  let op_out = fb_field(data, op, 2)
  assert_eq(2, fb_vec_len(data, op_in), msg="op inputs len")
  assert_eq(0, fb_vec_i32(data, op_in, 0), msg="op input 0")
  assert_eq(1, fb_vec_i32(data, op_in, 1), msg="op input 1")
  assert_eq(1, fb_vec_len(data, op_out), msg="op outputs len")
  assert_eq(2, fb_vec_i32(data, op_out, 0), msg="op output 0")
  assert_eq(21, data[fb_field(data, op, 3)].to_int(), msg="MulOptions type")
  let oc = fb_vec_off(data, fb_field(data, root, 1), 0)
  assert_eq(
    18,
    data[fb_field(data, oc, 0)].to_int(),
    msg="opcode deprecated=MUL",
  )
  assert_eq(18, fb_u32(data, fb_field(data, oc, 3)), msg="opcode builtin=MUL")
  // 常量 w：buffer 1 的 data 向量 = 4 × f32 LE
  let buf1 = fb_vec_off(data, fb_field(data, root, 4), 1)
  let w_vec_p = fb_field(data, buf1, 0) + fb_u32(data, fb_field(data, buf1, 0))
  assert_eq(16, fb_u32(data, w_vec_p), msg="w 字节数")
  let w : Array[Double] = []
  for i = 0; i < 4; i = i + 1 {
    let bits = fb_u32(data, w_vec_p + 4 + 4 * i)
    w.push(Float::reinterpret_from_int(bits).to_double())
  }
  w
}

///|
/// ---- f32 位级工具与容差谓词（冻结口径，见 tests/fixtures/golden/ASSETS.md §2）----
fn f32_bits_of(b : Bytes, i : Int32) -> Int32 {
  b[i].to_int() |
  (b[i + 1].to_int() << 8) |
  (b[i + 2].to_int() << 16) |
  (b[i + 3].to_int() << 24)
}

///|
/// f64 -> f32 位模式（IEEE754 就近舍入、ties to even；测试数值均为常规值）。
fn f32_bits_round(d : Double) -> Int32 {
  let bits = d.reinterpret_as_int64()
  let sign = (bits >> 63) & 1L
  let exp = (bits >> 52) & 0x7FFL
  let mant = bits & 0xFFFFFFFFFFFFFL
  if exp == 0x7FFL {
    // Inf / NaN
    return ((sign << 31) |
    0x7F800000L |
    (if mant == 0L { 0L } else { 0x00400000L })).to_int()
  }
  if exp == 0L && mant == 0L {
    return (sign << 31).to_int()
  }
  let mut e = exp - 1023L + 127L
  if e >= 255L {
    return ((sign << 31) | 0x7F800000L).to_int()
  }
  if e <= 0L {
    // 子正规 / 下溢：按 24 位有效位舍入（覆盖测试范围外的边界）
    if e < -24L {
      return (sign << 31).to_int()
    }
    let full = (mant | 0x10000000000000L) >> (1L - e + 29L).to_int()
    return ((sign << 31) | full).to_int()
  }
  let m23 = mant >> 29
  let rem = mant & 0x1FFFFFFFL
  let mut m = m23
  if rem > 0x10000000L || (rem == 0x10000000L && (m23 & 1L) == 1L) {
    m = m23 + 1L
  }
  if m == 0x800000L {
    m = 0L
    e = e + 1L
    if e >= 255L {
      return ((sign << 31) | 0x7F800000L).to_int()
    }
  }
  ((sign << 31) | (e << 23) | m).to_int()
}

///|
/// 容差谓词（冻结，逐字）：|got − want| ≤ 1e-6 + 1e-5 × |want|；
/// NaN=NaN bit 相等；±0 等价；Inf bit 相等。f64 比较。
fn f32_close(got_bits : Int32, want_bits : Int32) -> Bool {
  let g = Float::reinterpret_from_int(got_bits).to_double()
  let w = Float::reinterpret_from_int(want_bits).to_double()
  if g.is_nan() || w.is_nan() {
    return g.is_nan() && w.is_nan() && got_bits == want_bits
  }
  if g == 0.0 && w == 0.0 {
    return true // ±0 等价
  }
  if g.is_inf() || w.is_inf() {
    return got_bits == want_bits // Inf bit 相等
  }
  let diff = if g > w { g - w } else { w - g }
  let abs_w = if w > 0.0 { w } else { 0.0 - w }
  // 冻结口径：|got − want| ≤ 1e-6 + 1e-5 × |want|
  diff <= 1.0e-6 + 1.0e-5 * abs_w
}

///|
/// 逐元素容差断言（输出 Bytes = f32 LE）。
fn assert_f32_vec_close(
  got : Bytes,
  want : Array[Int32],
  label~ : String,
) -> Unit raise {
  assert_eq(4 * want.length(), got.length(), msg=label + " 输出长度")
  for i = 0; i < want.length(); i = i + 1 {
    let g = f32_bits_of(got, i * 4)
    assert_true(
      f32_close(g, want[i]),
      msg=label +
        " 元素 " +
        i.to_string() +
        " 超容差: got=" +
        f32_bits_of(got, i * 4).to_string() +
        " want=" +
        want[i].to_string(),
    )
  }
}

///|
/// ---- 登记黄金（tests/fixtures/golden/micro_mul_f32.numeric.norm.txt 对齐）----
/// V1=[1,2,3,4]×[0.5,1,2,-1]→[0.5,2,6,-4]（f32 精确）
fn golden_v1_in() -> Array[Int32] {
  [0x3F800000, 0x40000000, 0x40400000, 0x40800000]
}

///|
fn golden_v1_mul() -> Array[Int32] {
  [0x3F000000, 0x40000000, 0x40C00000, 0xC0800000]
}

///|
/// V2=[0.1,-0.3,7.77,1e3]×[0.5,1,2,-1]，逐元素 f64 乘积→f32 舍入
fn golden_v2_in() -> Array[Int32] {
  [0x3DCCCCCD, 0xBE99999A, 0x40F8A3D7, 0x447A0000]
}

///|
fn golden_v2_mul() -> Array[Int32] {
  [0x3D4CCCCD, 0xBE99999A, 0x4178A3D7, 0xC47A0000]
}

///|
fn golden_sha256_tflite() -> String {
  "ba0f234cfc6b8593835c0882b8172945641262f5ca57b8a95e502a652163fb3c"
}

///|
fn golden_sha256_stf1() -> String {
  "82351c2de386dc8b3d628994b7a371bfe290bb0d77796d464fefa97016c3d1ab"
}

///|
/// 参考输出=独立解析计算：want = f32(f64(in) × f64(w))（逐元素）。
fn recompute_mul(in_bits : Array[Int32], w : Array[Double]) -> Array[Int32] {
  let out : Array[Int32] = []
  for i = 0; i < in_bits.length(); i = i + 1 {
    let a = Float::reinterpret_from_int(in_bits[i]).to_double()
    out.push(f32_bits_round(a * w[i]))
  }
  out
}

///|
fn golden_opts() -> @tflite_ffi.InterpreterOptions {
  @tflite_ffi.InterpreterOptions::{ thread_count: 1, allow_fp16: false, }
}

///|
/// 按 f32 位模式构造张量字节（f32 LE）。
fn f32_le_bytes(bits : Array[Int32]) -> Bytes {
  let buf : Array[Byte] = []
  for b in bits {
    buf.push((b & 0xFF).to_byte())
    buf.push(((b >> 8) & 0xFF).to_byte())
    buf.push(((b >> 16) & 0xFF).to_byte())
    buf.push(((b >> 24) & 0xFF).to_byte())
  }
  Bytes::from_array(buf[:])
}

///|
/// ---- golden tflite（非 #skip）----
/// 零入库证据链：测试内嵌生成器重建字节，断言 SHA-256 == ASSETS.md 登记值
/// （与 tools/gen-micro-model.ps1 产物逐字节一致；模型二进制零入库）。
test "golden tflite micro model registry sha256" {
  let model = micro_mul_f32_tflite()
  assert_eq(
    golden_sha256_tflite(),
    sha256_hex(model),
    msg="micro_mul_f32.tflite 字节登记",
  )
  let mirror = micro_mul_f32_stf1()
  assert_eq(
    golden_sha256_stf1(),
    sha256_hex(mirror),
    msg="micro_mul_f32.stf1 字节登记",
  )
  // 独立解析互证：登记 hex == 独立解析计算
  let w = verify_micro_tflite(model)
  assert_eq(
    golden_v1_mul(),
    recompute_mul(golden_v1_in(), w),
    msg="V1 登记 hex == 独立解析计算",
  )
  assert_eq(
    golden_v2_mul(),
    recompute_mul(golden_v2_in(), w),
    msg="V2 登记 hex == 独立解析计算",
  )
}

///|
/// stub 侧 STF1 镜像数值黄金（scale=1.0 恒等语义，V1）。
test "golden tflite stub mul_v1" {
  assert_true(
    @tflite_ffi.backend_name() == "stub",
    msg="golden tflite stub 用例要求 stub 后端生效",
  )
  let interp = @tflite_ffi.Interpreter::from_bytes(
    micro_mul_f32_stf1(),
    golden_opts(),
  )
  interp.set_input(0, f32_le_bytes(golden_v1_in()))
  interp.invoke()
  let out = interp.output_raw(0)
  interp.close()
  assert_f32_vec_close(out, golden_v1_in(), label="golden tflite stub mul_v1")
}

///|
/// stub 侧 STF1 镜像数值黄金（scale=1.0 恒等语义，V2）。
test "golden tflite stub mul_v2" {
  assert_true(
    @tflite_ffi.backend_name() == "stub",
    msg="golden tflite stub 用例要求 stub 后端生效",
  )
  let interp = @tflite_ffi.Interpreter::from_bytes(
    micro_mul_f32_stf1(),
    golden_opts(),
  )
  interp.set_input(0, f32_le_bytes(golden_v2_in()))
  interp.invoke()
  let out = interp.output_raw(0)
  interp.close()
  assert_f32_vec_close(out, golden_v2_in(), label="golden tflite stub mul_v2")
}

///|
/// ---- golden real（#skip，联跑 moon test --include-skipped -f "golden real*"）----
/// 首行断言 backend_name()=="real"：不满足即 fail，绝不静默跳过。
#skip
test "golden real micro_mul_f32 v1" {
  assert_true(
    @tflite_ffi.backend_name() == "real",
    msg="golden real 用例要求真实后端生效（绝不静默跳过）",
  )
  let model = micro_mul_f32_tflite()
  let w = verify_micro_tflite(model)
  assert_eq(
    golden_v1_mul(),
    recompute_mul(golden_v1_in(), w),
    msg="V1 登记 hex",
  )
  let interp = @tflite_ffi.Interpreter::from_bytes(model, golden_opts())
  interp.set_input(0, f32_le_bytes(golden_v1_in()))
  interp.invoke()
  let out = interp.output_raw(0)
  interp.close()
  assert_f32_vec_close(
    out,
    golden_v1_mul(),
    label="golden real micro_mul_f32 v1",
  )
}

///|
#skip
test "golden real micro_mul_f32 v2" {
  assert_true(
    @tflite_ffi.backend_name() == "real",
    msg="golden real 用例要求真实后端生效（绝不静默跳过）",
  )
  let model = micro_mul_f32_tflite()
  let w = verify_micro_tflite(model)
  assert_eq(
    golden_v2_mul(),
    recompute_mul(golden_v2_in(), w),
    msg="V2 登记 hex",
  )
  let interp = @tflite_ffi.Interpreter::from_bytes(model, golden_opts())
  interp.set_input(0, f32_le_bytes(golden_v2_in()))
  interp.invoke()
  let out = interp.output_raw(0)
  interp.close()
  assert_f32_vec_close(
    out,
    golden_v2_mul(),
    label="golden real micro_mul_f32 v2",
  )
}
