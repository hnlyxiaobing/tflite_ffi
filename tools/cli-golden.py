#!/usr/bin/env python3
"""L4 CLI 记录行/退出码黄金契约（W2 T-W2-4）。

在仓库根目录运行（CI 第六道门禁）：

    python3 tools/cli-golden.py

做三件事：
1. `moon build cmd/main --target native` 构建 CLI；
2. 由文本 hex 夹具程序化生成 STF1 微型模型与输入（二进制零入库）；
3. 逐场景比对 stdout/stderr/退出码/落盘字节与
   `tests/fixtures/golden/cli_*.txt`（逐字节，路径以 <MODEL>/<OUTDIR> 归一）。

口径：0=成功 / 1=运行失败 / 2=用法错误；错误场景不落输出文件。
缺失工具链或构建失败 → 非 0 退出（fail-closed，不静默跳过）。
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "fixtures" / "golden"


def fail(label: str, detail: str) -> None:
    print(f"FAIL {label}: {detail}", file=sys.stderr)
    raise SystemExit(1)


def read_golden(name: str) -> str:
    return (GOLDEN / name).read_text(encoding="utf-8")


def read_hex(name: str) -> bytes:
    return bytes.fromhex(read_golden(name).strip())


def normalize(text: str) -> str:
    return text.replace("\r\n", "\n")


def run_cli(exe: Path, args: list[str]) -> tuple[int, str, str]:
    env = os.environ.copy()
    for key in ("MB_TFLITE_BACKEND", "MB_TFLITE_LIB_PATH"):
        env.pop(key, None)
    proc = subprocess.run(
        [str(exe), *args],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )
    return proc.returncode, normalize(proc.stdout), normalize(proc.stderr)


def expect_eq(label: str, got: str, want: str) -> None:
    if got != want:
        fail(label, f"stdout/stderr mismatch\n--- got ---\n{got}\n--- want ---\n{want}")


def expect_code(label: str, got: int, want: int) -> None:
    if got != want:
        fail(label, f"exit code {got} != {want}")


def main() -> int:
    build = subprocess.run(
        ["moon", "build", "cmd/main", "--target", "native"],
        cwd=ROOT,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    if build.returncode != 0:
        fail("moon build", build.stdout + build.stderr)

    exe = ROOT / "_build" / "native" / "debug" / "build" / "cmd" / "main" / (
        "main.exe" if os.name == "nt" else "main"
    )
    if not exe.is_file():
        fail("locate cli", f"missing {exe}")

    model_hex = read_hex("cli_model_stf1.hex")
    input_hex = read_hex("cli_input_v1.hex")
    output_hex = read_hex("cli_output_v1.hex")

    with tempfile.TemporaryDirectory(prefix="tfl_cli_golden_") as tmp:
        tmpdir = Path(tmp)
        model = tmpdir / "model.stf1"
        model.write_bytes(model_hex)
        inp = tmpdir / "input.bin"
        inp.write_bytes(input_hex)
        short = tmpdir / "short.bin"
        short.write_bytes(b"\x01\x02")
        outdir = tmpdir / "out"
        outdir_bad = tmpdir / "out_bad"

        model_s = str(model)
        outdir_s = str(outdir)

        code, out, err = run_cli(exe, ["--help"])
        expect_code("help exit", code, 0)
        expect_eq("help stdout", out, read_golden("cli_help.txt"))

        code, out, err = run_cli(exe, [])
        expect_code("noargs exit", code, 2)
        expect_eq("noargs stderr", err, read_golden("cli_noargs_stderr.txt"))

        code, out, err = run_cli(exe, ["--bogus"])
        expect_code("unknown exit", code, 2)
        expect_eq("unknown stderr", err, read_golden("cli_unknown_stderr.txt"))

        code, out, err = run_cli(exe, ["--info", "--backend", "stub"])
        expect_code("info stub exit", code, 0)
        expect_eq("info stub stdout", out, read_golden("cli_info_stub.txt"))

        code, out, err = run_cli(
            exe, ["--model", model_s, "--backend", "stub", "--input", str(inp)]
        )
        expect_code("stub chain exit", code, 0)
        want = read_golden("cli_stub_chain.txt").replace("<MODEL>", model_s)
        expect_eq("stub chain stdout", out, want)

        code, out, err = run_cli(
            exe,
            [
                "--model",
                model_s,
                "--backend",
                "stub",
                "--input",
                str(inp),
                "--out-raw",
                outdir_s,
            ],
        )
        expect_code("out-raw exit", code, 0)
        want = (
            read_golden("cli_stub_out_raw.txt")
            .replace("<MODEL>", model_s)
            .replace("<OUTDIR>", outdir_s)
        )
        expect_eq("out-raw stdout", out, want)
        out0 = outdir / "out0.bin"
        if not out0.is_file():
            fail("out-raw file", f"missing {out0}")
        if out0.read_bytes() != output_hex:
            fail("out-raw bytes", f"{out0} content != {output_hex.hex()}")

        code, out, err = run_cli(
            exe,
            [
                "--model",
                model_s,
                "--backend",
                "auto",
                "--lib",
                "no_such_library_file",
                "--input",
                str(inp),
            ],
        )
        expect_code("auto fallback exit", code, 0)
        want = read_golden("cli_stub_chain.txt").replace("<MODEL>", model_s)
        expect_eq("auto fallback stdout", out, want)

        code, out, err = run_cli(
            exe,
            [
                "--model",
                model_s,
                "--backend",
                "real",
                "--lib",
                "no_such_library_file",
            ],
        )
        expect_code("real forced exit", code, 1)
        if out != "":
            fail("real forced stdout", f"expected empty, got:\n{out}")
        if "LibraryNotLoaded" not in err:
            fail("real forced stderr", f"missing LibraryNotLoaded:\n{err}")

        code, out, err = run_cli(
            exe,
            [
                "--model",
                model_s,
                "--backend",
                "stub",
                "--input",
                str(short),
                "--out-raw",
                str(outdir_bad),
            ],
        )
        expect_code("bad input exit", code, 1)
        if "BufferSizeMismatch(16, 2)" not in err:
            fail("bad input stderr", f"missing BufferSizeMismatch(16, 2):\n{err}")
        if (outdir_bad / "out0.bin").exists():
            fail("bad input no output", "out0.bin must not be written on error")

    print("PASS cli-golden: help/usage/stub/out-raw/auto/real-fail/bad-input (9 scenarios)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
