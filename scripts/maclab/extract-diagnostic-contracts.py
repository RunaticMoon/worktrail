#!/usr/bin/env python3
"""Copy actual small Core error contracts into isolated native check modules."""

import pathlib
import sys

root, output = map(pathlib.Path, sys.argv[1:])
declarations = [
    ("Sources/WorkLogCore/Domain/Models.swift", "public enum AIErrorClass:"),
    ("Sources/WorkLogCore/AI/AIProvider.swift", "public struct AIProviderError:"),
]
chunks = ["import Foundation"]
for relative, declaration in declarations:
    source = (root / relative).read_text()
    start = source.index(declaration)
    end = source.index("\n}", start) + 2
    chunks.append(source[start:end])
output.write_text("\n\n".join(chunks) + "\n")
