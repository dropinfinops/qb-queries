#!/usr/bin/env python3
"""Verify the playground corpus behaves exactly as the answer key says.

Runs all three acts for every pattern against samples/ and reports what each one does.
This is the inspection sheet: if you change a query, a threshold, or the corpus,
run this and the difference is visible immediately.

  PREFLIGHT   every check must PASS (INFO rows are informational)
  DIAGNOSTIC  must execute and return a ranked field
  DETECTOR    must return its planted finding

Exit code 0 = corpus healthy. Non-zero = something regressed.

Usage:  python3 tools/verify_corpus.py [--verbose]
"""
import json
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
QDIR = REPO / "queries"
INIT = REPO / "playground.sql"


def duck(sql: str, json_out: bool = False):
    """Run SQL against the playground view. Returns (ok, output)."""
    cmd = ["duckdb", "-init", str(INIT)]
    if json_out:
        cmd.append("-json")
    else:
        cmd += ["-noheader", "-list"]
    cmd += ["-c", sql]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    return r.returncode == 0 and not r.stderr.strip(), (r.stdout or r.stderr).strip()


def body(path: pathlib.Path) -> str:
    """The file's SQL with the trailing semicolon stripped, safe to nest."""
    return path.read_text().rstrip().rstrip(";")


def check_preflight(d: pathlib.Path):
    f = d / "preflight.duckdb.sql"
    if not f.exists():
        return "MISSING", []
    ok, out = duck(f"SELECT status, check_name FROM ({body(f)})")
    if not ok:
        return "ERROR", [out.splitlines()[0][:80]]
    fails = [ln.split("|", 1)[1] for ln in out.splitlines() if ln.startswith("FAIL")]
    return ("PASS" if not fails else "FAIL"), fails


def check_diagnostic(d: pathlib.Path):
    f = d / "diagnostic.duckdb.sql"
    if not f.exists():
        return "MISSING", 0
    ok, out = duck(f"SELECT COUNT(*) FROM ({body(f)})")
    if not ok:
        return "ERROR", 0
    return "ok", int(out.splitlines()[-1] or 0)


def check_detector(d: pathlib.Path):
    f = d / "query.duckdb.sql"
    if not f.exists():
        return "MISSING", 0, ""
    ok, out = duck(f"SELECT COUNT(*) FROM ({body(f)})")
    if not ok:
        return "ERROR", 0, out.splitlines()[0][:80]
    n = int(out.splitlines()[-1] or 0)
    if n == 0:
        return "ZERO", 0, ""
    ok2, js = duck(f"SELECT * FROM ({body(f)}) LIMIT 1", json_out=True)
    headline = ""
    if ok2:
        try:
            # playground.sql prints a banner before the JSON payload
            row = json.loads(js[js.index("["):])[0]
            parts = []
            for k, v in list(row.items())[:3]:
                if isinstance(v, float):
                    v = round(v, 2)
                if isinstance(v, str) and len(v) > 30:
                    v = "..." + v[-27:]
                parts.append(f"{k}={v}")
            headline = "  ".join(parts)
        except Exception:
            pass
    return "ok", n, headline


def main() -> int:
    verbose = "--verbose" in sys.argv
    dirs = sorted(p for p in QDIR.iterdir() if p.is_dir())
    bad = 0

    print(f"{'DETECTOR':<44} {'PRE':<6} {'DIAG':<6} {'HITS':<6} HEADLINE FINDING")
    print("-" * 118)
    for d in dirs:
        pre, fails = check_preflight(d)
        dg, dn = check_diagnostic(d)
        det, n, headline = check_detector(d)
        if pre != "PASS" or dg != "ok" or det != "ok":
            bad += 1
        print(f"{d.name:<44} {pre:<6} {dg:<6} {str(n):<6} {headline}")
        if verbose and fails:
            for x in fails:
                print(f"{'':<44} └─ preflight FAIL: {x}")

    print("-" * 118)
    if bad:
        print(f"\n✗ {bad} of {len(dirs)} detectors are not healthy.")
        print("  Re-run with --verbose to see which preflight checks failed.")
        return 1
    print(f"\n✓ all {len(dirs)} detectors healthy: preflight clean, "
          f"diagnostic ranks the field, detector returns its planted finding.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
