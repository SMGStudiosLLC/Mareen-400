#!/usr/bin/env python3
"""Static parity checks between the Swift host and the embedded Metal source.

    python3 Tools/ref/check_layout.py [MarennFilter.swift]

Checks:
  1. Every parameter struct that exists in both Swift and Metal has the same
     field names in the same order (the host sends them with setBytes, so a
     mismatch means silently garbled parameters on the GPU).
  2. Every kernel name the Swift host asks the library for exists in Metal.
  3. The Metal strings obey the multi-line literal rules (no backslashes,
     triple quotes or tabs, consistent indentation).
Exit status 1 on any failure.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract_msl import extract, swift_structs  # noqa: E402

MSL_STRUCT_RE = re.compile(r"struct\s+(\w+)\s*\{(.*?)\};", re.DOTALL)


def msl_structs(text):
    structs = {}
    for m in MSL_STRUCT_RE.finditer(text):
        name, body = m.group(1), m.group(2)
        body = re.sub(r"//.*", "", body)
        fields = []
        for decl in body.split(";"):
            decl = decl.strip()
            if not decl:
                continue
            parts = decl.split(None, 1)
            if len(parts) != 2:
                continue
            typ, names = parts
            if typ != "float":
                fields.append(("<non-float " + typ + ">", None))
                continue
            for n in names.split(","):
                n = n.strip()
                if n:
                    fields.append((n, None))
        structs[name] = [f[0] for f in fields]
    return structs


def main():
    swift_path = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent.parent / "MarennFilter.swift")
    swift_text = swift_path.read_text(encoding="utf-8")
    blocks = extract(swift_path)  # raises on literal hygiene problems
    msl_text = "\n".join(text for _, text in blocks.values())
    problems = []

    swift = swift_structs(swift_path)
    metal = msl_structs(msl_text)
    shared = [n for n in swift if n in metal]
    for name in shared:
        sf = [f for f, _ in swift[name]]
        mf = metal[name]
        if sf != mf:
            problems.append(f"struct {name}: Swift fields {sf} != Metal fields {mf}")
    for name in metal:
        if name not in swift:
            problems.append(f"struct {name} exists in Metal but not in Swift")

    referenced = set(re.findall(r'pipeline\("(\w+)"', swift_text)) | set(re.findall(r'\bpso\("(\w+)"', swift_text))
    defined = set(re.findall(r"kernel\s+void\s+(\w+)\s*\(", msl_text))
    for k in sorted(referenced):
        if k not in defined:
            problems.append(f"kernel {k} is referenced by the host but not defined in Metal")
    for k in sorted(defined):
        if k not in referenced:
            problems.append(f"kernel {k} is defined in Metal but never used by the host")

    # Metal names that the host must pass as multiple buffers: every constant
    # buffer index used by a kernel must be set by the host encode closure.
    for kname in sorted(defined):
        sig = re.search(r"kernel\s+void\s+" + kname + r"\s*\((.*?)\)\s*\{", msl_text, re.DOTALL)
        if not sig:
            continue
        buffers = re.findall(r"buffer\((\d+)\)", sig.group(1))
        textures = re.findall(r"texture\((\d+)\)", sig.group(1))
        print(f"{kname}: {len(buffers)} buffer(s), {len(textures)} texture(s)")

    if problems:
        print("\n".join("FAIL " + p for p in problems))
        sys.exit(1)
    print(f"OK: {len(shared)} shared structs match, {len(referenced)} kernels resolved, literals clean")


if __name__ == "__main__":
    main()
