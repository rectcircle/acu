#!/usr/bin/env python3
"""Print -1, 0, or 1 when comparing two release versions numerically."""

import re
import sys


def parse(version):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)(?:[-.]([0-9A-Za-z.-]+))?", version)
    if not match:
        raise ValueError(f"Invalid version: {version}")
    major, minor, patch, prerelease = match.groups()
    return (int(major), int(minor), int(patch)), prerelease


def compare(left, right):
    left_core, left_pre = parse(left)
    right_core, right_pre = parse(right)
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre == right_pre:
        return 0
    if left_pre is None:
        return 1
    if right_pre is None:
        return -1
    left_parts, right_parts = left_pre.split("."), right_pre.split(".")
    for left_part, right_part in zip(left_parts, right_parts):
        if left_part == right_part:
            continue
        if left_part.isdigit() and right_part.isdigit():
            left_part, right_part = int(left_part), int(right_part)
        elif left_part.isdigit() != right_part.isdigit():
            return -1 if left_part.isdigit() else 1
        if left_part != right_part:
            return (left_part > right_part) - (left_part < right_part)
    return (len(left_parts) > len(right_parts)) - (len(left_parts) < len(right_parts))


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("Usage: compare-versions.py <left-version> <right-version>")
        print(compare(sys.argv[1], sys.argv[2]))
    except ValueError as error:
        sys.exit(str(error))
