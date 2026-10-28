#!/usr/bin/env python3
"""Compile exact production error enums without activating audio capture or model stores."""

import pathlib
import sys

root, output = map(pathlib.Path, sys.argv[1:3])
mode = sys.argv[3:]
if mode not in ([], ["--capture-only"], ["--model-only"]):
    raise SystemExit("Expected --capture-only, --model-only, or no mode")
declarations = []
if mode != ["--model-only"]:
    declarations.append(("Sources/WorkLogApp/MeetingAudioCapture.swift", "enum MeetingAudioCaptureError:"))
if mode != ["--capture-only"]:
    declarations += [
        ("Sources/WorkLogApp/MeetingLocalModels.swift", "enum MeetingModelRole:"),
        ("Sources/WorkLogApp/MeetingLocalModels.swift", "enum MeetingLocalModelError:"),
    ]
chunks = ["import Foundation"]
for relative, declaration in declarations:
    source = (root / relative).read_text()
    start = source.index(declaration)
    end = source.index("\n}", start) + 2
    chunks.append(source[start:end])
output.write_text("\n\n".join(chunks) + "\n")
