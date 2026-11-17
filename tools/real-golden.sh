#!/usr/bin/env bash
# tflite_ffi 真实库 golden runner（W5-A，2026-11-17）
#
# 纪律：真实库/模型永不入库；只接受仓库外本地路径 + SHA-256 登记。
# 缺失项一律 SKIPPED(78)，不进 moon test 通过计数；哈希不符为硬失败。
# 本脚本不复制、不修改、不缓存任何二进制，只在进程内设置 env 后运行测试。

set -uo pipefail

LIB=""
REGISTRY="tools/real-libraries.sha256"
COMPAT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lib) LIB="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --compat) COMPAT="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,16p' "$0"
      exit 0 ;;
    *)
      echo "SKIPPED: unknown argument '$1' (exit 78)" >&2
      exit 78 ;;
  esac
done

skip() {
  echo "SKIPPED: $1 (exit 78; not counted as passed)" >&2
  exit 78
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -n "$LIB" ] || skip "no external real library path supplied"
[ -f "$LIB" ] || skip "external real library path does not exist"
[ -f "$REGISTRY" ] || fail "registry file missing: $REGISTRY"

if command -v sha256sum >/dev/null 2>&1; then
  LIB_SHA256="$(sha256sum "$LIB" | awk '{print $1}')"
elif command -v python3 >/dev/null 2>&1; then
  LIB_SHA256="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$LIB")"
else
  skip "no SHA-256 tool available"
fi

if ! grep -Eq "^[[:space:]]*${LIB_SHA256}[[:space:]]+" "$REGISTRY"; then
  fail "library SHA-256 not registered: $LIB_SHA256"
fi

command -v moon >/dev/null 2>&1 || skip "moon toolchain not available"

# 中文/UTF-8 路径由 dispatch 层的 LoadLibraryW 转换处理；此处只传原文。
export MB_TFLITE_BACKEND=real
export MB_TFLITE_LIB_PATH="$LIB"

echo "real-golden: library hash registered ($LIB_SHA256)"
if [ -n "$COMPAT" ]; then
  bash -c "$COMPAT"
  rc=$?
  echo "real-golden: compatibility command exit $rc"
  exit "$rc"
fi

# 默认比较：golden real 两条用例（真实库缺失时它们本身首行断言 real，失败即 FAIL）。
moon test --include-skipped -f "golden real*"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "real-golden: PASS (hash $LIB_SHA256; $(date -u +%Y-%m-%dT%H:%M:%SZ))"
else
  echo "real-golden: FAIL (exit $rc; hash $LIB_SHA256; $(date -u +%Y-%m-%dT%H:%M:%SZ))" >&2
fi
exit "$rc"
