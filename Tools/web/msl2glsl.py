#!/usr/bin/env python3
"""Translate the Metal source embedded in MarennFilter.swift into WebGL2 (GLSL ES 3.00).

The filter's Metal code is the single source of truth. This script turns it into one
fragment shader per kernel and writes Tools/web/marenn-shaders.js, so the browser
version can never drift from the app. It handles exactly the MSL subset the filter
uses; if a translation fails, WebGL reports the line when the page compiles it.

What changes on the way:
  * types           float2 -> vec2, uint4 -> uvec4, float3x3 -> mat3 ...
  * constant arrays  constant float3 A[3] = {...}  ->  const vec3 A[3] = vec3[3](...)
  * the uniforms     `constant MarennParams& P` parameters disappear; P is a uniform struct
  * textures         t.sample(smp, uv) -> texture(t, uv), t.read(gid) -> texelFetch,
                     t.get_width() -> textureSize, dst.write(v, gid) -> fragColor = v
  * kernels          kernel void name(...) { body }  ->  void main() { uvec2 gid = ...; body }

usage: msl2glsl.py MarennFilter.swift Tools/web/marenn-shaders.js   (a classic script setting window.MARENN_SHADERS)
"""
import json
import re
import sys
from pathlib import Path

swift_path, out_path = Path(sys.argv[1]), Path(sys.argv[2])
swift = swift_path.read_text()
m = re.search(r'static let source = """\n(.*?)\n\s*"""', swift, re.S)
if not m:
    sys.exit("msl2glsl: embedded Metal source not found")
msl = m.group(1)

TYPES = [("float3x3", "mat3"), ("float2", "vec2"), ("float3", "vec3"), ("float4", "vec4"),
         ("uint2", "uvec2"), ("uint3", "uvec3"), ("uint4", "uvec4"),
         ("int2", "ivec2"), ("int3", "ivec3"), ("int4", "ivec4")]


def types(src):
    for a, b in TYPES:
        src = re.sub(rf"\b{a}\b", b, src)
    return src


def split_top_level(src):
    """Split source into top-level items: kernels, functions, structs, declarations."""
    items, i, n = [], 0, len(src)
    while i < n:
        j = i
        depth = 0
        while j < n:
            c = src[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    k = j + 1
                    while k < n and src[k] in " \t":
                        k += 1
                    if k < n and src[k] == ";":
                        j = k
                    items.append(src[i:j + 1])
                    i = j + 1
                    break
            elif c == ";" and depth == 0:
                items.append(src[i:j + 1])
                i = j + 1
                break
            j += 1
        else:
            items.append(src[i:])
            break
    return [s for s in items if s.strip()]


def strip_comments(src):
    return re.sub(r"//[^\n]*", "", src)


body = strip_comments(msl)
body = body.replace("#include <metal_stdlib>", "").replace("using namespace metal;", "")
items = split_top_level(body)

prelude, kernels = [], []
for it in items:
    s = it.strip()
    if s.startswith("constexpr sampler"):
        continue
    if s.startswith("kernel void"):
        kernels.append(s)
        continue
    if s.startswith("struct MarennParams"):
        prelude.append(types(s))
        prelude.append("uniform MarennParams P;")
        continue
    # constant arrays with brace initialisers
    am = re.match(r"constant\s+(\w+)\s+(\w+)\[(\d+)\]\s*=\s*\{(.*)\};", s, re.S)
    if am:
        t, name, count, init = types(am.group(1)), am.group(2), am.group(3), types(am.group(4))
        prelude.append(f"const {t} {name}[{count}] = {t}[{count}]({init.strip()});")
        continue
    s = re.sub(r"^constant\s+", "const ", s)
    s = re.sub(r"^inline\s+", "", s)
    s = re.sub(r",\s*constant MarennParams& P", "", s)
    s = re.sub(r"constant MarennParams& P,?\s*", "", s)
    s = types(s)
    # local arrays with brace initialisers: float digits[6] = {a, b};
    s = re.sub(r"\b(float|int)\s+(\w+)\[(\d+)\]\s*=\s*\{([^}]*)\};", r"\1 \2[\3] = \1[\3](\4);", s)
    # functions called with P as an argument
    s = re.sub(r",\s*P\)", ")", s)
    prelude.append(s)


def translate_kernel(k):
    hm = re.match(r"kernel void (\w+)\((.*?)\)\s*\{(.*)\}\s*$", k, re.S)
    name, params, kbody = hm.group(1), hm.group(2), hm.group(3)
    decls, out_tex, samplers = [], None, []
    for p in [p.strip() for p in params.split(",\n")]:
        p = " ".join(p.split())
        tm = re.match(r"texture2d<float, access::(\w+)> (\w+) \[\[texture\((\d+)\)\]\]", p)
        if tm:
            access, tname, idx = tm.groups()
            if access == "write":
                out_tex = tname
            else:
                samplers.append((int(idx), tname))
            continue
        if p.startswith("constant MarennParams& P"):
            continue
        cm = re.match(r"constant (\w+)& (\w+) \[\[buffer\(\d+\)\]\]", p)
        if cm:
            decls.append(f"uniform {types(cm.group(1))} {cm.group(2)};")
            continue
        if "thread_position_in_grid" in p:
            continue
        raise SystemExit(f"msl2glsl: unhandled kernel parameter in {name}: {p}")
    b = types(kbody)
    b = re.sub(rf"\b{out_tex}\.get_width\(\)", "uOutSize.x", b)
    b = re.sub(rf"\b{out_tex}\.get_height\(\)", "uOutSize.y", b)
    b = re.sub(rf"\b{out_tex}\.write\((.*), gid\);", r"fragColor = \1;", b)
    b = re.sub(r"\b(\w+)\.get_width\(\)", r"uint(textureSize(\1, 0).x)", b)
    b = re.sub(r"\b(\w+)\.get_height\(\)", r"uint(textureSize(\1, 0).y)", b)
    b = re.sub(r"\b(\w+)\.sample\(smp, ", r"texture(\1, ", b)
    b = re.sub(r"\b(\w+)\.read\(gid\)", r"texelFetch(\1, ivec2(gid), 0)", b)
    b = re.sub(r",\s*P\)", ")", b)
    b = re.sub(r"\b(float|int)\s+(\w+)\[(\d+)\]\s*=\s*\{([^}]*)\};", r"\1 \2[\3] = \1[\3](\4);", b)
    uniforms = "\n".join([f"uniform sampler2D {t};" for _, t in sorted(samplers)] + decls)
    src = "\n".join([uniforms, "uniform uvec2 uOutSize;", "out vec4 fragColor;",
                     "void main() {", "    uvec2 gid = uvec2(gl_FragCoord.xy);", b.rstrip(), "}"])
    return name, [t for _, t in sorted(samplers)], src


header = "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"
common = "\n\n".join(prelude)
out = {}
for k in kernels:
    name, samplers, src = translate_kernel(k)
    out[name] = {"samplers": samplers, "source": header + common + "\n\n" + src + "\n"}

fields = re.search(r"struct MarennParams \{(.*?)\};", msl, re.S).group(1)
names = [n.strip() for decl in strip_comments(fields).split(";") if decl.strip()
         for n in decl.strip()[len("float "):].split(",")]

# defaults straight from the Swift struct, like msl2cpp.py
sw = re.search(r"\nstruct MarennParams \{(.*?)\n\}", swift, re.S).group(1)
defaults = {n: float(v) for n, v in re.findall(r"var (\w+): Float = ([-\d.eE+]+)", sw)}
missing = [n for n in names if n not in defaults]
if missing:
    sys.exit(f"msl2glsl: no Swift default for {missing}")

shaders = {"fields": names, "defaults": {n: defaults[n] for n in names}, "kernels": out}
js = ("// generated by Tools/web/msl2glsl.py from MarennFilter.swift, do not edit\n"
      f"window.MARENN_SHADERS = {json.dumps(shaders, indent=1)};\n")
out_path.write_text(js)
print(f"msl2glsl: {len(out)} kernels, {len(names)} params -> {out_path}")
