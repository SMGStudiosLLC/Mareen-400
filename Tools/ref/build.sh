#!/usr/bin/env bash
# Build the CPU reference renderers from the Metal source embedded in the
# Swift file. Produces build/ref_marenn400 and, when the Swift file carries the
# Vesper kernels, build/ref_vesper800.
#
#   Tools/ref/build.sh [path/to/MarennFilter.swift]
#
# Requires g++ (OpenMP optional but used when available) and python3.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SWIFT="${1:-$HERE/../../MarennFilter.swift}"
BUILD="$HERE/build"
mkdir -p "$BUILD"

python3 "$HERE/extract_msl.py" "$SWIFT" "$BUILD"

CXX="${CXX:-g++}"
FLAGS=(-std=c++17 -O2 -fsingle-precision-constant -Wno-attributes -Wall -Wno-unused-function -Wno-unused-variable -I"$HERE/shim" -I"$HERE")
if [[ "${FASTMATH:-0}" == "1" ]]; then FLAGS+=(-ffast-math); fi
if $CXX -fopenmp -x c++ -c /dev/null -o /dev/null 2>/dev/null; then FLAGS+=(-fopenmp); fi

if [[ -f "$BUILD/source.metal" ]]; then
  # Single-string layout (Marenn 400 as shipped).
  $CXX "${FLAGS[@]}" -DSTOCK_LEGACY -DMSL_A="\"$BUILD/source.metal\"" "$HERE/ref.cpp" -o "$BUILD/ref_marenn400"
  echo "built $BUILD/ref_marenn400"
fi
if [[ -f "$BUILD/prelude.metal" && -f "$BUILD/legacySource.metal" ]]; then
  $CXX "${FLAGS[@]}" -DSTOCK_LEGACY -DMSL_A="\"$BUILD/prelude.metal\"" -DMSL_B="\"$BUILD/legacySource.metal\"" "$HERE/ref.cpp" -o "$BUILD/ref_marenn400"
  echo "built $BUILD/ref_marenn400"
fi
if [[ -f "$BUILD/prelude.metal" && -f "$BUILD/vesperSource.metal" ]]; then
  $CXX "${FLAGS[@]}" -DSTOCK_VESPER -DMSL_A="\"$BUILD/prelude.metal\"" -DMSL_B="\"$BUILD/vesperSource.metal\"" "$HERE/ref.cpp" -o "$BUILD/ref_vesper800"
  echo "built $BUILD/ref_vesper800"
fi
