// Q10 算子覆盖（R4，2026-11-09）：矩阵的 stub 侧可验证部分 + real 侧待测登记。
//
// Q10 原文（docs/open-questions.md）：「TfLiteInterpreter 相关 C API 是否覆盖
// 所需算子 / delegate」——只用 CPU、不用 delegate 是本轮假设；最小实验是用
// 目标 .tflite 模型在桌面跑一次 invoke，确认无缺失算子。
//
// 本文件的职责边界（不伪造 real 侧结论）：
// - **可验证（stub 侧）**：TFL3 模型字节的算子表可被独立 flatbuffer 解析器
//   枚举（`q10_scan_tfl3_ops`）；本仓库自产 micro 模型恰含 MUL(18)；stub 只认
//   STF1，喂 TFL3 = 解析期显式失败（不静默「覆盖」算子）；STF1 描述层覆盖
//   矩阵所需 6 种 dtype；未知 dtype / 尾随算子字节一律 fail-closed。
// - **待实测（real 侧）**：目标模型（MoveNet/BlazePose）的真实算子集合、真实
//   库内核注册表是否齐全、缺失算子时的 invoke 行为——全部标 pending_real，
//   矩阵文档 `docs/Q10-OPERATOR-COVERAGE.md` 同步登记 [仍需实测]。
//
// 算子编号来源：TFLite schema `builtin_ops.h` / `schema.fbs` 的
// BuiltinOperator 枚举 [仅据文档]；本文件只断言本仓库实际发射/枚举到的编号，
// 不把候选清单当成已实测结论。

///|
/// 矩阵行：算子名 / TFLite BuiltinOperator 编号 / 来源分层 / stub 侧处理 /
/// real 侧状态（统一 `pending_real` = [仍需实测]）。
struct Q10Row {
  name : String
  code : Int32
  source : String
  stub : String
  real : String
}

///|
/// Q10 覆盖矩阵（文档 `docs/Q10-OPERATOR-COVERAGE.md` 的机器可读镜像）。
/// `source`：`micro_golden` = 本仓库自产 TFL3 黄金模型实际发射的算子；
/// `movenet_candidate` = 目标模型候选算子（公开模型结构描述，**未经真实模型
/// flatbuffer 解析确认**，故 real 侧一律 pending_real）。
fn q10_matrix() -> Array[Q10Row] {
  [
    Q10Row::{
      name: "MUL",
      code: 18,
      source: "micro_golden",
      stub: "scalar_scale_simulation",
      real: "pending_real",
    },
    Q10Row::{
      name: "CONV_2D",
      code: 3,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "DEPTHWISE_CONV_2D",
      code: 4,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "ADD",
      code: 0,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "SUB",
      code: 41,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "RELU6",
      code: 21,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "PAD",
      code: 34,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "MEAN",
      code: 40,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "RESIZE_BILINEAR",
      code: 23,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "TRANSPOSE_CONV",
      code: 67,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "CONCATENATION",
      code: 2,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "SOFTMAX",
      code: 25,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "MAX_POOL_2D",
      code: 17,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "RESHAPE",
      code: 22,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "DEQUANTIZE",
      code: 6,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "QUANTIZE",
      code: 114,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
    Q10Row::{
      name: "LOGISTIC",
      code: 14,
      source: "movenet_candidate",
      stub: "not_expressible",
      real: "pending_real",
    },
  ]
}

///|
/// 按名称查矩阵行；缺席返回 None（不 panic）。
fn q10_row_of(name : String) -> Q10Row? {
  for row in q10_matrix() {
    if row.name == name {
      return Some(row)
    }
  }
  None
}

///|
/// 枚举 TFL3（TFLite flatbuffer）模型的 OperatorCode 内置算子编号。
/// 结构：Model.operator_codes（field 1）→ OperatorCode.builtin_code（field 3，
/// 1.14+ 起取代 deprecated_builtin_code / field 0）；两字段都缺席时记 -1。
fn q10_scan_tfl3_ops(data : Bytes) -> Array[Int32] {
  let out : Array[Int32] = []
  let root = fb_u32(data, 0)
  let codes = fb_field(data, root, 1)
  if codes < 0 {
    return out
  }
  let n = fb_vec_len(data, codes)
  for i = 0; i < n; i = i + 1 {
    let oc = fb_vec_off(data, codes, i)
    let builtin = fb_field(data, oc, 3)
    if builtin >= 0 {
      out.push(fb_u32(data, builtin))
    } else {
      let deprecated = fb_field(data, oc, 0)
      out.push(if deprecated >= 0 { data[deprecated].to_int() } else { -1 })
    }
  }
  out
}

///|
/// dtype 码 → 公开 `TensorDtype` 分支是否一致（stub 描述层矩阵覆盖）。
fn q10_dtype_matches(code : Int32, dtype : @tflite_ffi.TensorDtype) -> Bool {
  match (code, dtype) {
    (0, @tflite_ffi.TensorDtype::Float32) => true
    (1, @tflite_ffi.TensorDtype::Float16) => true
    (2, @tflite_ffi.TensorDtype::Int32) => true
    (3, @tflite_ffi.TensorDtype::UInt8) => true
    (4, @tflite_ffi.TensorDtype::Int8) => true
    (5, @tflite_ffi.TensorDtype::Int64) => true
    _ => false
  }
}

///|
test "q10 scan micro tfl3 operator codes" {
  let ops = q10_scan_tfl3_ops(micro_mul_f32_tflite())
  assert_eq(
    [18],
    ops,
    msg="micro_mul_f32.tflite 的算子表应恰为 [MUL=18]",
  )
  let row = q10_row_of("MUL")
  assert_true(row is Some(_), msg="矩阵必须登记 MUL")
  match row {
    Some(r) => {
      assert_eq(18, r.code)
      assert_eq("micro_golden", r.source)
      assert_eq("pending_real", r.real)
    }
    None => ()
  }
}

///|
test "q10 matrix real-side rows stay explicitly pending" {
  let rows = q10_matrix()
  assert_true(rows.length() >= 17, msg="候选算子矩阵不得少于 17 行")
  for row in rows {
    assert_eq(
      "pending_real",
      row.real,
      msg="real 侧未实测行必须显式 pending_real（不得写成通过）: " +
        row.name,
    )
    assert_true(row.stub != "", msg="stub 侧处理必须登记: " + row.name)
  }
  // micro 黄金实际算子必须都在矩阵内（防矩阵与模型漂移）
  for code in q10_scan_tfl3_ops(micro_mul_f32_tflite()) {
    let mut found = false
    for row in rows {
      if row.code == code {
        found = true
      }
    }
    assert_true(
      found,
      msg="micro 模型算子 " + code.to_string() + " 未登记矩阵",
    )
  }
}

///|
test "q10 stub rejects tfl3 model instead of silently covering ops" {
  assert_true(
    @tflite_ffi.backend_name() == "stub",
    msg="q10 stub 用例要求 stub 后端生效",
  )
  // stub 只认 STF1；喂 TFL3（含 MUL 算子表）必须解析期显式失败，
  // 证明 stub 没有把「可加载」误当成「算子已覆盖」。
  let e = expect_err(() => {
    ignore(@tflite_ffi.Interpreter::from_bytes(micro_mul_f32_tflite(), opts()))
  })
  assert_true(e is @tflite_ffi.TfLiteError::ModelCreateFailed(-1))
}

///|
test "q10 stub dtype descriptor matrix covers all six dtypes" {
  for code = 0; code <= 5; code = code + 1 {
    let model = build_model(
      0x3F800000,
      [
        TensorSpec::{
          name: b"i",
          dtype: code,
          dims: [1, 2],
          qscale_bits: 0,
          qzero: 0,
        },
      ],
      [
        TensorSpec::{
          name: b"o",
          dtype: code,
          dims: [1, 2],
          qscale_bits: 0,
          qzero: 0,
        },
      ],
    )
    let interp = @tflite_ffi.Interpreter::from_bytes(model, @tflite_ffi.InterpreterOptions::{
      thread_count: 1,
      allow_fp16: true,
    })
    let desc = interp.output_desc(0)
    assert_true(
      q10_dtype_matches(code, desc.dtype),
      msg="dtype 码 " +
        code.to_string() +
        " 的公开 TensorDtype 分支不符",
    )
    interp.close()
  }
}

///|
test "q10 stub unknown dtype fails closed" {
  let model = build_model(
    0x3F800000,
    [
      TensorSpec::{
        name: b"i",
        dtype: 6,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
    [
      TensorSpec::{
        name: b"o",
        dtype: 0,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
  )
  let e = expect_err(() => {
    ignore(@tflite_ffi.Interpreter::from_bytes(model, opts()))
  })
  assert_true(e is @tflite_ffi.TfLiteError::ModelCreateFailed(-1))
}

///|
test "q10 stf1 cannot carry an operator table" {
  // STF1 无 OperatorCode 字段：在合法 STF1 末尾追加「MUL=18」小端 4 字节，
  // 必须因尾随字节被拒绝（而不是被当作算子表接受）。
  let base = build_model(
    0x3F800000,
    [
      TensorSpec::{
        name: b"i",
        dtype: 0,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
    [
      TensorSpec::{
        name: b"o",
        dtype: 0,
        dims: [1, 2],
        qscale_bits: 0,
        qzero: 0,
      },
    ],
  )
  let buf : Array[Byte] = []
  for i in 0..<base.length() {
    buf.push(base[i])
  }
  buf.push(b'\x12') // 18 小端
  buf.push(b'\x00')
  buf.push(b'\x00')
  buf.push(b'\x00')
  let e = expect_err(() => {
    ignore(
      @tflite_ffi.Interpreter::from_bytes(Bytes::from_array(buf[:]), opts()),
    )
  })
  assert_true(e is @tflite_ffi.TfLiteError::ModelCreateFailed(-1))
}
