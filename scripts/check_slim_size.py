#!/usr/bin/env python3
"""Enforce the slim CLI's uncompressed size budget."""

import pathlib
import sys

binary = pathlib.Path(sys.argv[1])
size = binary.stat().st_size
limit = 2_000_000
print(f"{binary}: {size:,} bytes (limit: < {limit:,})")
if size >= limit:
    sys.exit("slim binary exceeds its size budget")
