#!/usr/bin/env python3
"""Extract embedded Python patch blocks from install.sh and exercise them.

These blocks are the actual runtime fixes applied to installed npm packages on
Termux. Running them against synthetic package files verifies that the patches
still match the expected source shapes and that they are idempotent -- without
needing a real Termux device in CI.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTALL = ROOT / "install.sh"

src = INSTALL.read_text(encoding="utf-8")
blocks = re.findall(r"<<'PY'\n(.*?)\nPY\n", src, re.S)
if len(blocks) < 4:
    sys.exit(f"expected >=4 embedded python patch blocks, found {len(blocks)}")

# Blocks are ordered in install.sh as:
#   0: common.gypi patch
#   1: session-persistence-jsonl link->rename
#   2: attachment-local link->rename
#   3: flock fallback
#   4: rename-import completion
# Locate them by their distinctive anchors rather than by index so that adding
# a new heredoc earlier does not silently break the test.
def find_block(needle):
    hits = [b for b in blocks if needle in b]
    if len(hits) != 1:
        sys.exit(f"expected 1 python block containing {needle!r}, found {len(hits)}")
    return hits[0]

session = find_block("await link(tmp, finalPath)")
attachment = find_block("await link(temporary, target)")
flock = find_block("android-flock-fallback")
rename_import = find_block("added rename to")

errors = []

def run_block(code, path):
    return subprocess.run([sys.executable, "-", str(path)], input=code,
                          text=True, capture_output=True)

def check_node_syntax(path):
    if not pathlib.Path(shutil.which("node") or "/usr/bin/node").exists():
        return
    r = subprocess.run(["node", "--check", str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        errors.append(f"node --check failed for {path.name}: {r.stderr.strip()}")

import shutil

with tempfile.TemporaryDirectory() as td:
    root = pathlib.Path(td)

    # --- session-persistence-jsonl link -> rename -------------------------
    p = root / "session.js"
    p.write_text(
        'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";\n'
        'await link(tmp, finalPath);\n', encoding="utf-8")
    r = run_block(session, p)
    if r.returncode != 0:
        errors.append(f"session patch crashed: {r.stderr.strip()}")
    s = p.read_text(encoding="utf-8")
    if "await rename(tmp, finalPath)" not in s or "rename," not in s:
        errors.append("session patch did not replace link()/import rename")
    after_first = s
    run_block(session, p)
    if p.read_text(encoding="utf-8") != after_first:
        errors.append("session patch is not idempotent")
    check_node_syntax(p)

    # --- attachment-local link -> rename + unlink ENOENT tolerance --------
    p = root / "attachment.js"
    p.write_text(
        'import { chmod, link, mkdir, open, readFile, unlink } from "node:fs/promises";\n'
        'await link(temporary, target);\n'
        'await unlink(temporary);\n', encoding="utf-8")
    r = run_block(attachment, p)
    if r.returncode != 0:
        errors.append(f"attachment patch crashed: {r.stderr.strip()}")
    s = p.read_text(encoding="utf-8")
    if "await rename(temporary, target)" not in s or "rename," not in s:
        errors.append("attachment patch did not replace link()/import rename")
    if "ENOENT" not in s:
        errors.append("attachment patch did not add ENOENT tolerance to unlink")
    after_first = s
    run_block(attachment, p)
    if p.read_text(encoding="utf-8") != after_first:
        errors.append("attachment patch is not idempotent")
    check_node_syntax(p)

    # --- flock android fallback ------------------------------------------
    p = root / "flock.js"
    p.write_text(
        "import { getSystemErrorName } from 'node:util';\n"
        "export async function tryLockExclusive(fd) {\n"
        "  return getSystemErrorName(fd);\n"
        "}\n", encoding="utf-8")
    r = run_block(flock, p)
    if r.returncode != 0:
        errors.append(f"flock patch crashed: {r.stderr.strip()}")
    s = p.read_text(encoding="utf-8")
    if "android-flock-fallback" not in s or "androidTryLock" not in s:
        errors.append("flock patch did not install the android fallback")
    after_first = s
    run_block(flock, p)
    if p.read_text(encoding="utf-8") != after_first:
        errors.append("flock patch is not idempotent")
    check_node_syntax(p)

    # --- rename import completion ----------------------------------------
    p = root / "fs-local.js"
    p.write_text(
        'import { link, mkdir, open } from "node:fs/promises";\n'
        'await rename(tmp, finalPath);\n', encoding="utf-8")
    r = run_block(rename_import, p)
    if r.returncode != 0:
        errors.append(f"rename-import patch crashed: {r.stderr.strip()}")
    s = p.read_text(encoding="utf-8")
    if not re.search(r"import \{[^}]*\brename\b[^}]*\} from \"node:fs/promises\"", s):
        errors.append("rename-import patch did not add rename to the import list")
    after_first = s
    run_block(rename_import, p)
    if p.read_text(encoding="utf-8") != after_first:
        errors.append("rename-import patch is not idempotent")
    check_node_syntax(p)

if errors:
    print("patch simulation FAILED:")
    for e in errors:
        print("  -", e)
    sys.exit(1)

print(f"OK: {len(blocks)} embedded python blocks, 4 patch simulations passed "
      "(correctness + idempotency + JS syntax)")
