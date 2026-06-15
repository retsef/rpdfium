#!/usr/bin/env python3
"""Benchmark runner for pdfplumber (comparison baseline).

    python3 pdfplumber_runner.py <text|tables> <file.pdf>

Emits a single JSON line on stdout, same shape as rpdfium_runner.rb.
Correctness is scored against pdfs/expected.json, outside the timed section.
"""

import json
import os
import re
import resource
import sys
import time

import pdfplumber


def main() -> None:
    task, path = sys.argv[1], sys.argv[2]

    with open(os.path.join(os.path.dirname(path), "expected.json")) as f:
        expected = json.load(f).get(os.path.basename(path), {})

    t0 = time.perf_counter()
    if task == "text":
        with pdfplumber.open(path) as pdf:
            extracted = "\n".join(page.extract_text() or "" for page in pdf.pages)
    elif task == "tables":
        with pdfplumber.open(path) as pdf:
            cells = [c for page in pdf.pages for table in page.extract_tables()
                     for row in table for c in row if c]
    else:
        sys.exit(f"unknown task: {task}")
    time_ms = round((time.perf_counter() - t0) * 1000, 2)

    if task == "text":
        haystack = re.sub(r"\s+", "", extracted)
        truth = expected.get("text_sentinels", [])
        found = sum(1 for t in truth if t in haystack)
        value = len(extracted)
    else:
        cellset = {re.sub(r"\s+", "", c) for c in cells}
        truth = expected.get("table_cells", [])
        found = sum(1 for t in truth if re.sub(r"\s+", "", t) in cellset)
        value = len(cells)
    correctness = round(found / len(truth), 4) if truth else None

    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":  # darwin reports bytes, linux reports KB
        rss //= 1024

    print(json.dumps({"library": "pdfplumber", "task": task,
                      "time_ms": time_ms, "peak_rss_kb": rss,
                      "correctness": correctness, "value": value}))


if __name__ == "__main__":
    main()
