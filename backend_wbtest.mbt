// WP-1 双路径后端白盒场景测试（契约 §1「三场景可测」+ §2 白盒钩子；
// 主控 2026-11-08 裁决：三场景与 real 强制断言一律双断言）。
//
// 用例名统一 "backend scenario ..." 前缀（WP-4 harness 约定）。
// 三场景（无真实库也全绿）：①路径不存在 ②损坏映像（@fs.tmpdir() 程序生成
// 垃圾字节，不入库）③加载失败走白盒故障注入 force_fail(1|2|3)。
// auto 下断言：进程存活、backend_name()=="stub"、STF1 可用、backend_info()
// 含分类原因；real 下双断言：LibraryNotLoaded 显式抛出 + backend_info()
// 含 F 分类原因（不能只看 mismatch 文案）。
// reset 守卫：live_handles()>0 时 _tfl_backend_reset 拒绝（返回 1）。
// env 契约：MB_TFLITE_BACKEND=stub|real|auto（默认 stub，非法值=视为未设置
// 并记 env_invalid）、MB_TFLITE_LIB_PATH（UTF-8，中文路径往返）；测试收尾
// 一律还原 env 与解析状态。

///|
/// UTF-8 路径字节（_tfl_backend_reset 的 path 契约为 UTF-8）。
fn bs_utf8(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// 断言 info 文本包含 needle（失败时打印全文便于定位）。
fn bs_assert_contains(
  info : String,
  needle : String,
  label : String,
) -> Unit raise {
  assert_true(
    info.contains(needle),
    msg=label +
      "：backend_info() 应包含 [" +
      needle +
      "]，实为:\n" +
      info,
  )
}

///|
/// STF1 可用性烟测（stub 语义确定性路径）。
fn bs_stf1_works() -> Unit raise TfLiteError {
  let interp = Interpreter::from_bytes(wb_model(), wb_opts())
  interp.invoke()
  interp.close()
}

///|
/// 收尾还原：按 env 重新解析（默认 stub 态）。
fn bs_restore() -> Int32 {
  _tfl_backend_reset(-1, b"", 0)
}

///|
/// env 还原（保存值为 None 时移除）。
fn bs_env_restore(key : String, saved : String?) -> Unit {
  match saved {
    Some(v) => @env.set_env_var(key, v)
    None => @env.unset_env_var(key)
  }
}

///|
/// 场景①：路径不存在（auto → F1 自动回退 stub）。
test "backend scenario 1 missing path auto falls back to stub" {
  let path = bs_utf8("D:\\no_such_wp1\\tensorflowlite_c.dll")
  assert_eq(
    0,
    _tfl_backend_reset(2, path, path.length()),
    msg="auto 回退后重解析成功",
  )
  assert_true(_tfl_backend_live_handles() == 0, msg="场景① 无残留句柄")
  assert_eq("stub", backend_name())
  let info = backend_info()
  bs_assert_contains(info, "mode=auto", "场景①")
  bs_assert_contains(info, "resolved=stub", "场景①")
  bs_assert_contains(info, "load_status=F1", "场景①")
  bs_assert_contains(info, "reason=F1 path_probe_failed", "场景①")
  bs_stf1_works() // 进程存活 + STF1 可用
  assert_eq(0, bs_restore(), msg="收尾还原")
}

///|
/// 场景②：损坏映像（测试期 @fs.tmpdir() 生成垃圾字节，不入库；auto → F2）。
async test "backend scenario 2 corrupt image auto falls back to stub" {
  let dir = @fs.tmpdir(prefix="tfl_wp1")
  let p = dir + "\\corrupt_wp1.bin"
  let garbage : Array[Byte] = []
  for i in 0..<256 {
    garbage.push(((i * 37 + 11) & 0xFF).to_byte())
  }
  @fs.write_binary(p, Bytes::from_array(garbage[:]))
  let path = bs_utf8(p)
  assert_eq(
    0,
    _tfl_backend_reset(2, path, path.length()),
    msg="auto 回退后重解析成功",
  )
  assert_eq("stub", backend_name())
  let info = backend_info()
  bs_assert_contains(info, "mode=auto", "场景②")
  bs_assert_contains(info, "load_status=F2", "场景②")
  bs_assert_contains(info, "reason=F2 image_invalid", "场景②")
  bs_stf1_works()
  assert_eq(0, bs_restore(), msg="收尾还原")
  @fs.remove(p, allow_missing=true) // 损坏样本只写 tmp，用后即删
}

///|
/// 场景③：加载失败走白盒故障注入（force_fail 1|2|3 → F1|F2|F3）。
test "backend scenario 3 injected failure classes auto falls back to stub" {
  for code = 1; code <= 3; code = code + 1 {
    assert_eq(0, _tfl_backend_force_fail(code), msg="注入成功")
    assert_eq(
      0,
      _tfl_backend_reset(2, b"", 0),
      msg="auto 注入回退后重解析成功",
    )
    assert_eq("stub", backend_name())
    let info = backend_info()
    bs_assert_contains(
      info,
      "load_status=F" + code.to_string(),
      "场景③ 注入",
    )
    bs_assert_contains(
      info,
      "reason=F" + code.to_string() + " ",
      "场景③ 注入",
    )
    bs_assert_contains(info, "injected_failure", "场景③ 注入")
    bs_assert_contains(info, "auto_fallback_stub", "场景③ 注入")
    bs_stf1_works()
  }
  assert_eq(0, _tfl_backend_force_fail(0), msg="清除注入")
  assert_eq(0, bs_restore(), msg="收尾还原")
}

///|
/// real 强制 + F1（路径不存在）双断言：LibraryNotLoaded + F 分类原因。
test "backend scenario 4 real forced missing path dual assert" {
  let path = bs_utf8("D:\\no_such_wp1\\tensorflowlite_c.dll")
  assert_eq(
    2,
    _tfl_backend_reset(1, path, path.length()),
    msg="real 强制失败返回 2",
  )
  let e = expect_err(() => {
    ignore(Interpreter::from_bytes(wb_model(), wb_opts()))
  })
  assert_true(
    e is TfLiteError::LibraryNotLoaded(_),
    msg="real 强制失败 from_bytes 显式 LibraryNotLoaded（不回退）",
  )
  let info = backend_info()
  bs_assert_contains(info, "mode=real", "场景④")
  bs_assert_contains(info, "resolved=none", "场景④")
  bs_assert_contains(info, "load_status=F1", "场景④")
  bs_assert_contains(info, "reason=F1 path_probe_failed", "场景④")
  assert_eq(0, bs_restore(), msg="收尾还原")
}

///|
/// real 强制 + F2（损坏映像）双断言：LibraryNotLoaded + F 分类原因。
async test "backend scenario 5 real forced corrupt image dual assert" {
  let dir = @fs.tmpdir(prefix="tfl_wp1")
  let p = dir + "\\corrupt_wp1_real.bin"
  let garbage : Array[Byte] = []
  for i in 0..<64 {
    garbage.push(((i * 53 + 7) & 0xFF).to_byte())
  }
  @fs.write_binary(p, Bytes::from_array(garbage[:]))
  let path = bs_utf8(p)
  assert_eq(
    2,
    _tfl_backend_reset(1, path, path.length()),
    msg="real 强制失败返回 2",
  )
  let e = expect_err(() => {
    ignore(Interpreter::from_bytes(wb_model(), wb_opts()))
  })
  assert_true(
    e is TfLiteError::LibraryNotLoaded(_),
    msg="显式 LibraryNotLoaded",
  )
  let info = backend_info()
  bs_assert_contains(info, "load_status=F2", "场景⑤")
  bs_assert_contains(info, "reason=F2 image_invalid", "场景⑤")
  assert_eq(0, bs_restore(), msg="收尾还原")
  @fs.remove(p, allow_missing=true)
}

///|
/// real 强制 + F3（注入加载失败）双断言：LibraryNotLoaded + F 分类原因。
test "backend scenario 6 real forced injected load failure dual assert" {
  assert_eq(0, _tfl_backend_force_fail(3), msg="注入 F3")
  assert_eq(2, _tfl_backend_reset(1, b"", 0), msg="real 强制失败返回 2")
  let e = expect_err(() => {
    ignore(Interpreter::from_bytes(wb_model(), wb_opts()))
  })
  assert_true(
    e is TfLiteError::LibraryNotLoaded(_),
    msg="显式 LibraryNotLoaded",
  )
  let info = backend_info()
  bs_assert_contains(info, "load_status=F3", "场景⑥")
  bs_assert_contains(info, "reason=F3 load_failed", "场景⑥")
  assert_eq(0, _tfl_backend_force_fail(0), msg="清除注入")
  assert_eq(0, bs_restore(), msg="收尾还原")
}

///|
/// reset 守卫：活跃句柄存在时拒绝重解析（返回 1），清零后恢复。
test "backend scenario 7 reset guard refuses while handles live" {
  assert_eq(0, _tfl_backend_live_handles(), msg="入口无残留句柄")
  let interp = Interpreter::from_bytes(wb_model(), wb_opts())
  assert_true(_tfl_backend_live_handles() >= 1, msg="创建后有活跃句柄")
  assert_eq(1, _tfl_backend_reset(0, b"", 0), msg="活跃句柄拒绝重解析")
  assert_eq(1, _tfl_backend_reset(2, b"", 0), msg="任何模式都被拒绝")
  interp.close()
  assert_eq(0, _tfl_backend_live_handles(), msg="close 后句柄清零")
  assert_eq(
    0,
    _tfl_backend_reset(0, b"", 0),
    msg="句柄清零后允许重解析",
  )
  assert_eq(0, bs_restore(), msg="收尾还原")
}

///|
/// env 契约：MB_TFLITE_BACKEND=real + MB_TFLITE_LIB_PATH 强制真实路径（双断言）。
test "backend scenario 8 env mode real forces real path" {
  let saved_mode = @env.get_env_var("MB_TFLITE_BACKEND")
  let saved_path = @env.get_env_var("MB_TFLITE_LIB_PATH")
  @env.set_env_var("MB_TFLITE_BACKEND", "real")
  @env.set_env_var(
    "MB_TFLITE_LIB_PATH", "D:\\no_such_wp1\\tensorflowlite_c.dll",
  )
  assert_eq(
    2,
    _tfl_backend_reset(-1, b"", 0),
    msg="env real 强制失败返回 2",
  )
  let e = expect_err(() => {
    ignore(Interpreter::from_bytes(wb_model(), wb_opts()))
  })
  assert_true(
    e is TfLiteError::LibraryNotLoaded(_),
    msg="显式 LibraryNotLoaded",
  )
  let info = backend_info()
  bs_assert_contains(info, "mode=real", "场景⑧")
  bs_assert_contains(
    info, "lib_path=D:\\no_such_wp1\\tensorflowlite_c.dll", "场景⑧",
  )
  bs_assert_contains(info, "load_status=F1", "场景⑧")
  bs_env_restore("MB_TFLITE_BACKEND", saved_mode)
  bs_env_restore("MB_TFLITE_LIB_PATH", saved_path)
  assert_eq(0, bs_restore(), msg="收尾还原")
}

///|
/// env 契约：非法 MB_TFLITE_BACKEND 值 = 视为未设置并记 env_invalid。
test "backend scenario 9 env invalid value records env_invalid" {
  let saved_mode = @env.get_env_var("MB_TFLITE_BACKEND")
  @env.set_env_var("MB_TFLITE_BACKEND", "banana")
  assert_eq(
    0,
    _tfl_backend_reset(-1, b"", 0),
    msg="非法值按未设置处理",
  )
  assert_eq("stub", backend_name())
  let info = backend_info()
  bs_assert_contains(info, "mode=stub", "场景⑨")
  bs_assert_contains(info, "env_invalid", "场景⑨")
  bs_assert_contains(info, "load_status=F0", "场景⑨")
  bs_env_restore("MB_TFLITE_BACKEND", saved_mode)
  assert_eq(0, bs_restore(), msg="收尾还原")
}

///|
/// env 契约：MB_TFLITE_LIB_PATH 中文路径 UTF-8 往返（C 侧 GetEnvironmentVariableW
/// -> UTF-8 -> LoadLibraryW 全链路；lib_path 原文回显证明编码保真）。
test "backend scenario 10 env lib path chinese round trip" {
  let saved_mode = @env.get_env_var("MB_TFLITE_BACKEND")
  let saved_path = @env.get_env_var("MB_TFLITE_LIB_PATH")
  let zh = "D:\\不存在的目录_wp1\\tensorflowlite_c.dll"
  @env.set_env_var("MB_TFLITE_BACKEND", "real")
  @env.set_env_var("MB_TFLITE_LIB_PATH", zh)
  assert_eq(
    2,
    _tfl_backend_reset(-1, b"", 0),
    msg="中文路径 real 强制失败返回 2",
  )
  let e = expect_err(() => {
    ignore(Interpreter::from_bytes(wb_model(), wb_opts()))
  })
  assert_true(
    e is TfLiteError::LibraryNotLoaded(_),
    msg="显式 LibraryNotLoaded",
  )
  let info = backend_info()
  bs_assert_contains(
    info,
    "lib_path=" + zh,
    "场景⑩ 中文路径 UTF-8 往返",
  )
  bs_assert_contains(info, "load_status=F1", "场景⑩")
  bs_env_restore("MB_TFLITE_BACKEND", saved_mode)
  bs_env_restore("MB_TFLITE_LIB_PATH", saved_path)
  assert_eq(0, bs_restore(), msg="收尾还原")
}
