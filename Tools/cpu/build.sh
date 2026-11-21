#!/bin/sh
# Build the CPU reference renderer: ./Tools/cpu/build.sh [out_dir]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build}"
mkdir -p "$out"
python3 "$here/msl2cpp.py" "$here/../../MarennFilter.swift" "$out"
omp="-fopenmp"
echo 'int main(){}' | clang++ -x c++ -fopenmp - -o /dev/null 2>/dev/null || omp=""
clang++ -std=c++17 -O2 $omp -fPIC -shared -Wno-unknown-attributes -Wno-unknown-pragmas \
    -I"$out" -I"$here" "$here/marenn_cpu.cpp" -o "$out/libmarenn.so"
echo "built $out/libmarenn.so"
