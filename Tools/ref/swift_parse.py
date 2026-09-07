#!/usr/bin/env python3
"""Syntax-only parse of Swift files with tree-sitter, for machines without a
Swift toolchain. Reports ERROR and MISSING nodes with line numbers.

    pip install tree-sitter tree-sitter-swift
    python3 Tools/ref/swift_parse.py MarennFilter.swift Tools/vesper_cli.swift
"""
import sys
from pathlib import Path

try:
    import tree_sitter_swift
    from tree_sitter import Language, Parser
except ImportError:
    print("tree-sitter-swift is not installed; skipping the syntax check")
    sys.exit(0)


def parser():
    lang = Language(tree_sitter_swift.language())
    try:
        return Parser(lang)
    except TypeError:
        p = Parser()
        p.set_language(lang)
        return p


def walk(node, out):
    if node.type == "ERROR" or node.is_missing:
        out.append(node)
    for child in node.children:
        walk(child, out)


def main():
    p = parser()
    failed = False
    for path in sys.argv[1:]:
        src = Path(path).read_bytes()
        tree = p.parse(src)
        bad = []
        walk(tree.root_node, bad)
        if bad:
            failed = True
            for n in bad[:20]:
                line = n.start_point[0] + 1
                snippet = src[n.start_byte:min(n.end_byte, n.start_byte + 60)].decode("utf-8", "replace").split("\n")[0]
                kind = "MISSING" if n.is_missing else "ERROR"
                print(f"{path}:{line}: {kind} near: {snippet}")
            print(f"{path}: {len(bad)} problem node(s)")
        else:
            print(f"{path}: parses clean ({tree.root_node.child_count} top-level nodes)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
