///|
/// W4 T-W4-1/2：`backend_resolved()` 三态字面量与 `backend_info().resolved`
/// 一致；旧 `backend_name()` 二元映射冻结（none → "stub"）。
/// 真实库加载成功的 real 态需仓库外真实库（W5），此处不伪造。
test "w4 backend_resolved three states" {
  assert_eq(0, _tfl_backend_reset(0, b"", 0))
  assert_eq("stub", backend_resolved())
  assert_eq("stub", backend_name())
  assert_eq("stub", cw_info_value(backend_info(), "resolved"))
  // auto 无真实库 → 回退 stub
  assert_eq(0, _tfl_backend_reset(2, b"", 0))
  assert_eq("stub", backend_resolved())
  assert_eq("stub", cw_info_value(backend_info(), "resolved"))
  // real 强制失败 → none（不回退）
  let p = bs_utf8("no_such_library_file")
  assert_eq(2, _tfl_backend_reset(1, p, p.length()))
  assert_eq("none", backend_resolved())
  assert_eq(
    "stub",
    backend_name(),
    msg="旧二元映射冻结：非 real 即 stub",
  )
  assert_eq("none", cw_info_value(backend_info(), "resolved"))
  assert_eq(0, bs_restore())
}
