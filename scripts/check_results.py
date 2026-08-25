#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fail loudly on a cocotb results.xml that contains failures or errors.

cocotb's Makefile flow exits zero even when tests fail unless COCOTB_ANSI or
the results file is inspected, so CI checks the XML explicitly.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check_results.py <results.xml>", file=sys.stderr)
        return 2

    path = argv[1]
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as exc:
        print(f"check_results: cannot read {path}: {exc}", file=sys.stderr)
        return 2

    total = failures = errors = skipped = 0
    for case in root.iter("testcase"):
        total += 1
        for child in case:
            if child.tag == "failure":
                failures += 1
                print(f"FAIL {case.get('classname')}.{case.get('name')}: {child.get('message')}")
            elif child.tag == "error":
                errors += 1
                print(f"ERROR {case.get('classname')}.{case.get('name')}: {child.get('message')}")
            elif child.tag == "skipped":
                skipped += 1

    if total == 0:
        print("check_results: no test cases found -- did the simulation run?", file=sys.stderr)
        return 1

    bad = failures + errors
    status = "SUCCESS" if bad == 0 else "FAILURE"
    print(f"{status}: {total - bad}/{total} passed ({skipped} skipped)")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
