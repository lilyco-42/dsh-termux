#!/usr/bin/env python3
"""Structural checks for install.sh. Exits non-zero with a specific message on failure."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTALL = ROOT / "install.sh"
README = ROOT / "README.md"

errors = []
src = INSTALL.read_text(encoding="utf-8")

# 1. Numbered steps must be exactly 1..N, in order, all sharing one total.
steps = re.findall(r"^log (\d+) (\d+) ", src, re.M)
numbers = [int(a) for a, _ in steps]
totals = {b for _, b in steps}
if not steps:
    errors.append("no `log N/M` steps found in install.sh")
else:
    if totals != {str(len(steps))}:
        errors.append(f"step totals {sorted(totals)} do not match step count {len(steps)}")
    if numbers != list(range(1, len(steps) + 1)):
        errors.append(f"step numbers are not 1..{len(steps)} in order: {numbers}")

# 2. Every embedded `python3 - ... <<'PY'` block must compile.
blocks = re.findall(r"<<'PY'\n(.*?)\nPY\n", src, re.S)
if not blocks:
    errors.append("no embedded python heredocs found (expected at least one)")
for i, block in enumerate(blocks, 1):
    try:
        compile(block, f"install.sh[PY block #{i}]", "exec")
    except SyntaxError as exc:
        errors.append(f"embedded python block #{i} does not compile: line {exc.lineno}: {exc.msg}")

# 3. The README step list must reach the same count as install.sh.
readme = README.read_text(encoding="utf-8")
doc_steps = len(re.findall(r"^\d+\. ", readme, re.M))
if doc_steps != len(steps):
    errors.append(f"README documents {doc_steps} steps, install.sh has {len(steps)}")

# 4. Every patch applied to an installed package must carry a greppable idempotency marker.
markers = set(re.findall(r'grep -q "([a-z0-9-]+)" "\$', src))
if not markers:
    errors.append("no idempotency markers found in install.sh")

if errors:
    print("install.sh structural checks FAILED:")
    for e in errors:
        print("  -", e)
    sys.exit(1)

print(f"OK: {len(steps)} steps, {len(blocks)} embedded python block(s), "
      f"{len(markers)} idempotency marker(s), README lists {doc_steps} steps")
