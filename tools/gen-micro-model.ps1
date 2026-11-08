# gen-micro-model.ps1 — 自产微型模型生成器（WP-1，2026-11-08，契约 §4）
#
# 【产物】（零入库；默认写入 tflite_ffi/.local/models/，.local/ 已被 .gitignore 覆盖）
#   micro_mul_f32.tflite — 真实 TFLite flatbuffer（TFL3，real 后端用）
#     输入 "in" f32 [1,4]；常量 "w" f32 [4]=[0.5, 1.0, 2.0, -1.0]；
#     单 MUL(builtin=18) -> 输出 "out" f32 [1,4]。
#   micro_mul_f32.stf1 — STF1 镜像（stub 后端用；同名同 I/O 形状；
#     STF1 仅支持标量 scale 逐元素缩放，无法表达 MUL 权重逐元素语义，
#     镜像取 scale=1.0，语义差异见 DESIGN.md「双路径语义差异登记」）。
#
# 【发射方式】自研 flatbuffer 手工发射（无三方依赖），与
# tflite_ffi/real_golden_test.mbt 内嵌生成器逐字节一致（测试断言
# SHA-256 == ASSETS.md 登记值）。布局算法（两实现共同规范）：
#   反向构造（pos 从缓冲区尾部向下递减）；对象分配 alloc(size, align) 先补零至
#   (已写长度 + size) % align == 0；字符串对象先预补零使内容块结束于 4 对齐
#   边界（[u32 len][bytes][NUL] 连续、len 4 对齐）；表字段按 id 升序写入
#  （字段 0 在最高地址）；vtable 在表体之后（更低地址）写出，
#   soffset = table_pos - vtable_pos > 0；结尾 pad 至 已写长度 % 16 == 8，
#   写文件标识 "TFL3"（偏移 4..8），最后写根 uoffset（偏移 0），
#   总长 % 16 == 0（Buffer.data force_align=16 所需）。
#
# 【许可】自产内容，Apache-2.0（与 tflite_ffi/LICENSE 同口径）；无第三方素材。
#
# 用法: powershell -File tools/gen-micro-model.ps1 [-OutDir <dir>]
# 退出码: 0=成功 2=参数错 4=产物写入失败

param(
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# ---------------- 参数与输出目录 ----------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgRoot = Split-Path -Parent $scriptDir
if ($OutDir -eq "") {
  $OutDir = Join-Path $pkgRoot ".local\models"
}
if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
  Write-Error "OutDir 不是目录: $OutDir"
  exit 2
}

# ---------------- 迷你 flatbuffer 构造器（反向构造） ----------------
$CAP = 8192
$script:buf = New-Object byte[] $CAP
$script:pos = $CAP

function Alloc([int]$s, [int]$n) {
  while (((($CAP - $script:pos) + $s) % $n) -ne 0) {
    $script:pos--
    $script:buf[$script:pos] = 0
  }
  $script:pos -= $s
  $script:pos
}

function PutU8([int]$p, [int]$v) {
  $script:buf[$p] = [byte]($v -band 0xFF)
}

function PutU16([int]$p, [int]$v) {
  $script:buf[$p] = [byte]($v -band 0xFF)
  $script:buf[$p + 1] = [byte](($v -shr 8) -band 0xFF)
}

function PutU32([int]$p, [long]$v) {
  $script:buf[$p] = [byte]($v -band 0xFF)
  $script:buf[$p + 1] = [byte](($v -shr 8) -band 0xFF)
  $script:buf[$p + 2] = [byte](($v -shr 16) -band 0xFF)
  $script:buf[$p + 3] = [byte](($v -shr 24) -band 0xFF)
}

# 字符串对象：[u32 len][bytes][NUL]；返回 len 字段位置。
# 先预补零使内容块结束于 4 对齐边界，保证 len 字段与内容连续且 4 对齐
#（否则 Alloc 的补零会插进 len 与内容之间，破坏 flatbuffers 字符串布局）。
function EmitString([byte[]]$s) {
  while (((($CAP - $script:pos) + $s.Length + 1) % 4) -ne 0) {
    $script:pos--
    $script:buf[$script:pos] = 0
  }
  $null = Alloc 1 1
  PutU8 $script:pos 0
  for ($i = $s.Length - 1; $i -ge 0; $i--) {
    $null = Alloc 1 1
    PutU8 $script:pos $s[$i]
  }
  $p = Alloc 4 4
  PutU32 $p $s.Length
  $p
}

# int32 向量：[u32 len][i32 * len]；返回 len 字段位置
function EmitI32Vector([int[]]$vals) {
  for ($i = $vals.Count - 1; $i -ge 0; $i--) {
    $p = Alloc 4 4
    PutU32 $p ([long]$vals[$i])
  }
  $p = Alloc 4 4
  PutU32 $p $vals.Count
  $p
}

# 表偏移向量：[u32 len][uoffset32 * len]；返回 len 字段位置
function EmitOffsetVector([int[]]$childPos) {
  for ($i = $childPos.Count - 1; $i -ge 0; $i--) {
    $p = Alloc 4 4
    PutU32 $p ([long]($childPos[$i] - $p))
  }
  $p = Alloc 4 4
  PutU32 $p $childPos.Count
  $p
}

# ubyte 向量（force_align 对齐 data 起点）；返回 len 字段位置
function EmitBytesVector([byte[]]$data, [int]$align) {
  while (((($CAP - $script:pos) + $data.Length) % $align) -ne 0) {
    $script:pos--
    $script:buf[$script:pos] = 0
  }
  $script:pos -= $data.Length
  [Array]::Copy($data, 0, $script:buf, $script:pos, $data.Length)
  $p = Alloc 4 4
  PutU32 $p $data.Length
  $p
}

# ---------------- 表构造（字段按 id 升序写入） ----------------
$script:fieldPos = New-Object int[] 32
$script:fieldSize = New-Object int[] 32
$script:fieldCount = 0

function StartTable {
  for ($i = 0; $i -lt 32; $i++) { $script:fieldPos[$i] = 0; $script:fieldSize[$i] = 0 }
  $script:fieldCount = 0
}

function NoteField([int]$id, [int]$p, [int]$size) {
  $script:fieldPos[$id] = $p
  $script:fieldSize[$id] = $size
  if ($id + 1 -gt $script:fieldCount) { $script:fieldCount = $id + 1 }
}

function AddU8([int]$id, [int]$v) {
  $p = Alloc 1 1
  PutU8 $p $v
  NoteField $id $p 1
}

function AddU32([int]$id, [long]$v) {
  $p = Alloc 4 4
  PutU32 $p $v
  NoteField $id $p 4
}

function AddOffset([int]$id, [int]$childPos) {
  $p = Alloc 4 4
  PutU32 $p ([long]($childPos - $p))
  NoteField $id $p 4
}

function EndTable {
  $t = Alloc 4 4
  PutU32 $t 0
  $objSize = 4
  for ($i = 0; $i -lt $script:fieldCount; $i++) {
    if ($script:fieldPos[$i] -ne 0) {
      $end = $script:fieldPos[$i] + $script:fieldSize[$i] - $t
      if ($end -gt $objSize) { $objSize = $end }
    }
  }
  for ($i = $script:fieldCount - 1; $i -ge 0; $i--) {
    $p = Alloc 2 2
    if ($script:fieldPos[$i] -ne 0) {
      PutU16 $p ($script:fieldPos[$i] - $t)
    } else {
      PutU16 $p 0
    }
  }
  $p = Alloc 2 2
  PutU16 $p $objSize
  $vp = Alloc 2 2
  PutU16 $vp (4 + 2 * $script:fieldCount)
  PutU32 $t ([long]($t - $vp))
  $t
}

function Finish([int]$rootPos) {
  while ((($CAP - $script:pos) % 16) -ne 8) {
    $script:pos--
    $script:buf[$script:pos] = 0
  }
  $p = Alloc 4 1
  $script:buf[$p] = 0x54      # 'T'
  $script:buf[$p + 1] = 0x46  # 'F'
  $script:buf[$p + 2] = 0x4C  # 'L'
  $script:buf[$p + 3] = 0x33  # '3'
  $pRoot = Alloc 4 4
  PutU32 $pRoot ([long]($rootPos - $pRoot))
  $out = New-Object byte[] ($CAP - $script:pos)
  [Array]::Copy($script:buf, $script:pos, $out, 0, $out.Length)
  ,$out
}

# ---------------- micro_mul_f32.tflite（TFL3）----------------
function EmitTfliteModel {
  # 发射顺序（与 real_golden_test.mbt 内嵌生成器一致）：
  # 子对象自内向外：description -> buffers -> tensors -> operator -> subgraph
  # -> operator_codes -> Model 根表
  $desc = EmitString ([System.Text.Encoding]::ASCII.GetBytes("micro_mul_f32"))
  # Buffer 0 = 空哨兵（无字段）
  StartTable
  $buf0 = EndTable
  # Buffer 1 = 常量 w [0.5, 1.0, 2.0, -1.0] f32 LE
  $w = New-Object byte[] 16
  [Array]::Copy([BitConverter]::GetBytes([float]0.5), 0, $w, 0, 4)
  [Array]::Copy([BitConverter]::GetBytes([float]1.0), 0, $w, 4, 4)
  [Array]::Copy([BitConverter]::GetBytes([float]2.0), 0, $w, 8, 4)
  [Array]::Copy([BitConverter]::GetBytes([float]-1.0), 0, $w, 12, 4)
  $dataVec = EmitBytesVector $w 16
  StartTable
  AddOffset 0 $dataVec
  $buf1 = EndTable
  $buffers = EmitOffsetVector (@($buf0, $buf1))
  # Tensor 0: "in" [1,4] FLOAT32(buffer 0)
  $t0name = EmitString ([System.Text.Encoding]::ASCII.GetBytes("in"))
  $t0shape = EmitI32Vector (@(1, 4))
  StartTable
  AddOffset 0 $t0shape
  AddU8 1 0
  AddU32 2 0
  AddOffset 3 $t0name
  $t0 = EndTable
  # Tensor 1: "w" [4] FLOAT32(buffer 1)
  $t1name = EmitString ([System.Text.Encoding]::ASCII.GetBytes("w"))
  $t1shape = EmitI32Vector (@(4))
  StartTable
  AddOffset 0 $t1shape
  AddU8 1 0
  AddU32 2 1
  AddOffset 3 $t1name
  $t1 = EndTable
  # Tensor 2: "out" [1,4] FLOAT32(buffer 0)
  $t2name = EmitString ([System.Text.Encoding]::ASCII.GetBytes("out"))
  $t2shape = EmitI32Vector (@(1, 4))
  StartTable
  AddOffset 0 $t2shape
  AddU8 1 0
  AddU32 2 0
  AddOffset 3 $t2name
  $t2 = EndTable
  $tensors = EmitOffsetVector (@($t0, $t1, $t2))
  # MUL 算子：MulOptions（builtin_options_type=21），空表（fused_activation=NONE 缺省）
  StartTable
  $mulOpts = EndTable
  $opInputs = EmitI32Vector (@(0, 1))
  $opOutputs = EmitI32Vector (@(2))
  StartTable
  AddU32 0 0
  AddOffset 1 $opInputs
  AddOffset 2 $opOutputs
  AddU8 3 21
  AddOffset 4 $mulOpts
  $op = EndTable
  $operators = EmitOffsetVector (@($op))
  $sgInputs = EmitI32Vector (@(0))
  $sgOutputs = EmitI32Vector (@(2))
  $sgName = EmitString ([System.Text.Encoding]::ASCII.GetBytes("main"))
  StartTable
  AddOffset 0 $tensors
  AddOffset 1 $sgInputs
  AddOffset 2 $sgOutputs
  AddOffset 3 $operators
  AddOffset 4 $sgName
  $sg = EndTable
  $subgraphs = EmitOffsetVector (@($sg))
  # OperatorCode: deprecated_builtin_code=18(MUL), version=1, builtin_code=18
  StartTable
  AddU8 0 18
  AddU32 2 1
  AddU32 3 18
  $opcode = EndTable
  $opcodes = EmitOffsetVector (@($opcode))
  # Model: version=3
  StartTable
  AddU32 0 3
  AddOffset 1 $opcodes
  AddOffset 2 $subgraphs
  AddOffset 3 $desc
  AddOffset 4 $buffers
  $root = EndTable
  Finish $root
}

# ---------------- micro_mul_f32.stf1（STF1 镜像）----------------
# STF1（stub/README.md）：magic "STF1"、version 1、1 入 1 出、scale=1.0（镜像取恒等；
# STF1 无法表达 MUL 权重逐元素语义），张量 "in"/"out" f32 [1,4]。
function PushU32LE([System.Collections.Generic.List[byte]]$lst, [long]$v) {
  $lst.Add([byte]($v -band 0xFF))
  $lst.Add([byte](($v -shr 8) -band 0xFF))
  $lst.Add([byte](($v -shr 16) -band 0xFF))
  $lst.Add([byte](($v -shr 24) -band 0xFF))
}

function PushTensorLE([System.Collections.Generic.List[byte]]$lst, [byte[]]$name) {
  PushU32LE $lst $name.Length
  foreach ($b in $name) { $lst.Add($b) }
  PushU32LE $lst 0    # dtype Float32
  PushU32LE $lst 2    # rank 2
  PushU32LE $lst 1    # dim 1
  PushU32LE $lst 4    # dim 4
  PushU32LE $lst 0    # qscale
  PushU32LE $lst 0    # qzero
}

function EmitStf1Mirror {
  $lst = New-Object System.Collections.Generic.List[byte]
  PushU32LE $lst 0x31465453  # magic "STF1"
  PushU32LE $lst 1           # version
  PushU32LE $lst 1           # input_count
  PushU32LE $lst 1           # output_count
  PushU32LE $lst 0x3F800000  # scale 1.0（镜像恒等）
  PushTensorLE $lst ([System.Text.Encoding]::ASCII.GetBytes("in"))
  PushTensorLE $lst ([System.Text.Encoding]::ASCII.GetBytes("out"))
  ,$lst.ToArray()
}

# ---------------- 生成 + SHA-256 ----------------
$tflitePath = Join-Path $OutDir "micro_mul_f32.tflite"
$stf1Path = Join-Path $OutDir "micro_mul_f32.stf1"

$tfliteBytes = EmitTfliteModel
$stf1Bytes = EmitStf1Mirror

try {
  [System.IO.File]::WriteAllBytes($tflitePath, $tfliteBytes)
  [System.IO.File]::WriteAllBytes($stf1Path, $stf1Bytes)
} catch {
  Write-Error "产物写入失败: $_"
  exit 4
}

$sha = [System.Security.Cryptography.SHA256]::Create()
function Sha256Hex([byte[]]$b) {
  $h = $sha.ComputeHash($b)
  -join ($h | ForEach-Object { $_.ToString("x2") })
}

Write-Output ("sha256  " + (Sha256Hex $tfliteBytes) + "  " + $tflitePath)
Write-Output ("sha256  " + (Sha256Hex $stf1Bytes) + "  " + $stf1Path)
Write-Output ("bytes   " + $tfliteBytes.Length + "  " + $tflitePath)
Write-Output ("bytes   " + $stf1Bytes.Length + "  " + $stf1Path)
exit 0
