///|
/// tflite-cli：Tensor Lite 双路径（stub/real）演示/诊断 CLI
/// （hnlyxiaobing/tflite_ffi 公开 API 驱动）。
/// 退出码约定：0=成功 / 1=运行失败（模型解析/推理/real 强制不可用）/
/// 2=用法错误；`--backend` 先经 `@env.set_env_var` 写入 MB_TFLITE_BACKEND 再触发
/// 首次库调用（一次性解析在库层）；后端/回退信息走 `--info` 文本，不用退出码区分。

///|
let tool_name = "tflite-cli"

///|
/// 帮助文本（stdout，exit 0）。
fn usage_text() -> String {
  join_lines([
    "\{tool_name} —— TensorFlow Lite 双路径演示/诊断 CLI（hnlyxiaobing/tflite_ffi）",
    "",
    "用法:",
    "  \{tool_name} --model <path> [--backend stub|real|auto] [--lib <path>] [--threads N] [--info]",
    "  \{tool_name} [--backend stub|real|auto] [--lib <path>] --info",
    "      --model    模型文件（stub 后端=STF1；real 后端=TFLite flatbuffer；不可混用）",
    "      --backend  后端选择：stub（确定性内置）/ real（强制真实库）/ auto（优先 real，失败回退 stub）",
    "                 写入 MB_TFLITE_BACKEND 后再生效（默认 auto；纯库用法缺省 stub）",
    "      --lib      真实库路径，写入 MB_TFLITE_LIB_PATH（支持中文路径；缺省=标准搜索）",
    "      --threads  解释器线程数（正整数，默认 1）",
    "      --info     打印 backend_name=<name> 与 backend_info()（key=value 行：mode/resolved/",
    "                 lib_path/load_status(ok|F0|F1|F2|F3)/reason/tfl_version/schema_version）",
    "",
    "演示链路: from_bytes → 演示喂入 → invoke → 输出描述+数值 → close。",
    "输出: MODEL/INPUTS/OUTPUTS/OUTDESC/INVOKE/OUTDATA/DONE 记录行；错误信息一律 stderr。",
    "退出码: 0=成功 1=运行失败（模型/推理/real 强制不可用） 2=用法错误",
  ])
}

///|
/// 读取模型文件；路径为空或不可读时返回 `ok=false`（退出码 1 由调用方返回）。
async fn read_model(path : String) -> (Bytes, Bool) {
  if path == "" {
    return (b"", false)
  }
  if !@fs.exists(path) {
    eprintln("error: 无法读取文件：\{path}")
    return (b"", false)
  }
  (@fs.read_binary(path), true)
}

///|
/// `Interpreter::from_bytes` 尝试包装（冻结调用形态）：
/// 失败打印 `error: 模型加载失败：…`（real 强制不可用时含 LibraryNotLoaded 原因）
/// 并返回 None，由调用方按退出码 1 收口。
fn try_from_bytes(
  data : Bytes,
  opts : @tflite_ffi.InterpreterOptions,
) -> @tflite_ffi.Interpreter? {
  Some(@tflite_ffi.Interpreter::from_bytes(data, opts)) catch {
    e => {
      eprintln("error: 模型加载失败：\{e.to_repr()}")
      None
    }
  }
}

///|
/// 输入张量字节数探测：以空缓冲 `set_input` 触发冻结错误
/// `BufferSizeMismatch(expected, got)`，取 expected 作为演示喂入长度；
/// 0 字节输入返回 0，其它错误返回 -1（调用方跳过该输入的演示喂入）。
fn probe_input_size(interp : @tflite_ffi.Interpreter, index : Int32) -> Int32 {
  try {
    interp.set_input(index, b"")
    0
  } catch {
    e =>
      match e {
        @tflite_ffi.TfLiteError::BufferSizeMismatch(expected, _) => expected
        _ => -1
      }
  }
}

///|
/// `set_input` 尝试包装；失败打印并返回 false。
fn try_set_input(
  interp : @tflite_ffi.Interpreter,
  index : Int32,
  data : Bytes,
) -> Bool {
  try {
    interp.set_input(index, data)
    true
  } catch {
    e => {
      eprintln("error: 输入写入失败：\{e.to_repr()}")
      false
    }
  }
}

///|
/// `invoke` 尝试包装；失败打印并返回 false。
fn try_invoke(interp : @tflite_ffi.Interpreter) -> Bool {
  try {
    interp.invoke()
    true
  } catch {
    e => {
      eprintln("error: 推理失败：\{e.to_repr()}")
      false
    }
  }
}

///|
/// `output_desc` 尝试包装；失败打印并返回 None。
fn try_output_desc(
  interp : @tflite_ffi.Interpreter,
  index : Int32,
) -> @tflite_ffi.TensorDesc? {
  Some(interp.output_desc(index)) catch {
    e => {
      eprintln("error: 输出描述读取失败：\{e.to_repr()}")
      None
    }
  }
}

///|
/// `output_raw` 尝试包装；失败打印并返回 None。
fn try_output_raw(interp : @tflite_ffi.Interpreter, index : Int32) -> Bytes? {
  Some(interp.output_raw(index)) catch {
    e => {
      eprintln("error: 输出读取失败：\{e.to_repr()}")
      None
    }
  }
}

///|
/// `close` 尝试包装；失败打印并返回 false。
fn try_close(interp : @tflite_ffi.Interpreter) -> Bool {
  try {
    interp.close()
    true
  } catch {
    e => {
      eprintln("error: close 失败：\{e.to_repr()}")
      false
    }
  }
}

///|
/// `--model` 演示链路：加载 → 演示喂入 → invoke → 描述+数值输出 → close。
/// 任一环节失败按退出码约定返回 1；成功输出记录行并返回 0。
async fn run_model(path : String, threads : Int32) -> Int32 {
  let (data, ok) = read_model(path)
  if !ok {
    return 1
  }
  let opts = @tflite_ffi.InterpreterOptions::{
    thread_count: threads,
    allow_fp16: true,
  }
  let interp = match try_from_bytes(data, opts) {
    None => return 1
    Some(v) => v
  }
  let n_out = interp.output_count()
  let descs : Array[@tflite_ffi.TensorDesc] = []
  let mut i = 0
  while i < n_out {
    match try_output_desc(interp, i) {
      None => {
        ignore(try_close(interp))
        return 1
      }
      Some(d) => descs.push(d)
    }
    i = i + 1
  }
  // 演示喂入：以 1.0f32 位型平铺（仅演示；数值黄金在 moon test 冻结）
  let mut fi = 0
  while fi < interp.input_count() {
    let n = probe_input_size(interp, fi)
    if n > 0 {
      if !try_set_input(interp, fi, demo_input(n)) {
        ignore(try_close(interp))
        return 1
      }
    }
    fi = fi + 1
  }
  println("MODEL|\{path}")
  println("INPUTS|\{interp.input_count()}")
  println("OUTPUTS|\{n_out}")
  let mut k = 0
  while k < n_out {
    let d = descs[k]
    println(
      "OUTDESC|\{k}|\{d.name}|\{dtype_name(d.dtype)}|\{shape_text(d.shape)}|\{d.byte_size}",
    )
    k = k + 1
  }
  if !try_invoke(interp) {
    ignore(try_close(interp))
    return 1
  }
  println("INVOKE|ok")
  let mut j = 0
  while j < n_out {
    match try_output_raw(interp, j) {
      None => {
        ignore(try_close(interp))
        return 1
      }
      Some(out) => {
        let d = descs[j]
        println(
          "OUTDATA|\{j}|\{output_values_text(out, d.dtype is @tflite_ffi.TensorDtype::Float32)}",
        )
      }
    }
    j = j + 1
  }
  if !try_close(interp) {
    return 1
  }
  println("DONE|\{path}")
  0
}

///|
/// 参数解析与主流程。env 写入必须先于任何库调用（切换约定（`docs/DECISIONS.md` §2）：
/// 切换走 MB_TFLITE_BACKEND/MB_TFLITE_LIB_PATH，`--backend`/`--lib` 是其 CLI 面）。
async fn cmd(rest : ArrayView[String]) -> Int32 {
  let mut model_path = ""
  let mut backend = ""
  let mut lib_path = ""
  let mut threads = 1
  let mut show_info = false
  for xs = rest {
    match xs {
      ["--model", v, .. r] => {
        model_path = v
        continue r
      }
      ["--backend", v, .. r] => {
        backend = v
        continue r
      }
      ["--lib", v, .. r] => {
        lib_path = v
        continue r
      }
      ["--threads", v, .. r] => {
        match parse_pos_int(v) {
          Some(n) => threads = n
          None => {
            eprintln("error: --threads 需要正整数：\{v}")
            return 2
          }
        }
        continue r
      }
      ["--info", .. r] => {
        show_info = true
        continue r
      }
      ["--help", ..] => {
        println(usage_text())
        return 0
      }
      ["-h", ..] => {
        println(usage_text())
        return 0
      }
      [p, ..] => {
        if p == "--model" ||
          p == "--backend" ||
          p == "--lib" ||
          p == "--threads" {
          eprintln("error: \{p} 缺少取值")
          return 2
        }
        if p.has_prefix("-") {
          eprintln("error: 未知选项：\{p}")
        } else {
          eprintln("error: 多余的位置参数：\{p}")
        }
        eprintln("运行 \{tool_name} --help 查看用法")
        return 2
      }
      [] => break
    }
  }
  if backend != "" &&
    backend != "stub" &&
    backend != "real" &&
    backend != "auto" {
    eprintln("error: --backend 取值应为 stub / real / auto：\{backend}")
    return 2
  }
  if model_path == "" && !show_info {
    eprintln("error: 需要 --model <path> 或 --info")
    eprintln("运行 \{tool_name} --help 查看用法")
    return 2
  }
  // 后端解析是进程级一次性；env 写入必须先于 backend_name()/from_bytes 首次调用。
  // 取值优先级：--backend > 合法 MB_TFLITE_BACKEND > CLI 默认 auto。
  let mut backend_eff = "auto"
  if backend != "" {
    backend_eff = backend
  } else {
    match @env.get_env_var("MB_TFLITE_BACKEND") {
      Some(v) =>
        if v == "stub" || v == "real" || v == "auto" {
          backend_eff = v
        }
      None => ()
    }
  }
  @env.set_env_var("MB_TFLITE_BACKEND", backend_eff)
  if lib_path != "" {
    @env.set_env_var("MB_TFLITE_LIB_PATH", lib_path)
  }
  if show_info {
    println("backend_name=\{@tflite_ffi.backend_name()}")
    println(@tflite_ffi.backend_info())
  }
  if model_path == "" {
    0
  } else {
    run_model(model_path, threads)
  }
}

///|
/// 运行入口：返回进程退出码；任何意外抛出按“运行失败”收口为 1。
async fn run(args : Array[String]) -> Int32 {
  if args.length() <= 1 {
    eprintln("error: 缺少参数（需要 --model <path> 或 --info）")
    eprintln("运行 \{tool_name} --help 查看用法")
    return 2
  }
  cmd(args[1:]) catch {
    e => {
      eprintln("error: \{e}")
      1
    }
  }
}

///|
async fn main {
  let code = run(@env.args())
  if code != 0 {
    @env.exit(code)
  }
}
