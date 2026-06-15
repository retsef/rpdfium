#!/usr/bin/env python3
"""Benchmark runner for pypdfium2 (the "pure PDFium speed floor").

    python3 pypdfium2_runner.py text <file.pdf>

pypdfium2 is a raw FFI binding without a table pipeline, so only the text
task is supported. Emits a single JSON line on stdout. Correctness is scored
against pdfs/expected.json, outside the timed section.
"""

import json
import os
import re
import resource
import sys
import time

import pypdfium2 as pdfium


def main() -> None:
    task, path = sys.argv[1], sys.argv[2]
    if task != "text":
        sys.exit(f"unsupported task for pypdfium2: {task}")

    with open(os.path.join(os.path.dirname(path), "expected.json")) as f:
        expected = json.load(f).get(os.path.basename(path), {})

    t0 = time.perf_counter()
    pdf = pdfium.PdfDocument(path)
    parts = []
    for page in pdf:
        textpage = page.get_textpage()
        parts.append(textpage.get_text_bounded())
        textpage.close()
        page.close()
    pdf.close()
    extracted = "\n".join(parts)
    time_ms = round((time.perf_counter() - t0) * 1000, 2)

    haystack = re.sub(r"\s+", "", extracted)
    truth = expected.get("text_sentinels", [])
    found = sum(1 for t in truth if t in haystack)
    correctness = round(found / len(truth), 4) if truth else None

    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":  # darwin reports bytes, linux reports KB
        rss //= 1024

    print(json.dumps({"library": "pypdfium2", "task": task,
                      "time_ms": time_ms, "peak_rss_kb": rss,
                      "correctness": correctness, "value": len(extracted)}))


if __name__ == "__main__":
    main()
