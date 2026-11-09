################################################################################
# Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
################################################################################
"""Dispatch selection specs (``omniprobe -d``).

Grammar (optionally wrapped in ``[...]``, no whitespace anywhere)::

    spec    := "all" | pattern [ ":" [count] [ ":" [stride] ] ]
    pattern := item { "," item }
    item    := N | N "-" N | N "-"          (inclusive; N >= 1)

Dispatch numbers count per kernel, from 1. The pattern is repeated ``count``
times in total (empty count: without end), copy k shifted by k * stride; the
default stride is max - min + 1 of the pattern. An open range ``N-`` cannot be
repeated. Examples: ``1,3,4:3`` = 1,3,4,5,7,8,9,11,12;
``1,3,4:3:100`` = 1,3,4,101,103,104,201,203,204; ``1::100`` = every 100th.

This module has a C++ twin, src/dispatch_spec.cc, used by the runtime. Both are
checked against tests/dispatch_spec_cases.txt; keep the error reasons identical.
"""

from dataclasses import dataclass, field
from typing import List, Optional, Tuple

MAX_NUMBER = 2**63 - 1

RANDOM_REMOVED = ("-d random was removed; for sampling use e.g. -d 1::100 "
                  "(every 100th dispatch of each kernel)")


class DispatchSpecError(ValueError):
    """A malformed dispatch spec. str() is the full message for the user."""

    def __init__(self, spec: str, reason: str):
        self.spec = spec
        self.reason = reason
        super().__init__(f"invalid dispatch spec '{spec}': {reason}")


@dataclass
class DispatchSpec:
    all: bool = True
    # Inclusive intervals; hi None means open-ended.
    intervals: List[Tuple[int, Optional[int]]] = field(default_factory=list)
    count: Optional[int] = 1        # None: repeat without end
    stride: int = 1

    def contains(self, n: int) -> bool:
        if self.all:
            return True
        if n < 1:
            return False
        s = self.stride
        for lo, hi in self.intervals:
            if n < lo:
                continue
            if hi is None:
                return True
            # Copies k with lo + k*s <= n <= hi + k*s.
            kmin = 0 if n <= hi else -(-(n - hi) // s)
            kmax = (n - lo) // s
            if self.count is not None:
                kmax = min(kmax, self.count - 1)
            if kmin <= kmax:
                return True
        return False


def _number(spec: str, text: str, what: str) -> int:
    if not text.isascii() or not text.isdigit():
        raise DispatchSpecError(spec, f"expected a number{what}; got '{text}'")
    if len(text.lstrip("0")) > 19 or int(text) > MAX_NUMBER:
        raise DispatchSpecError(spec, f"number '{text}' is too large (max {MAX_NUMBER})")
    return int(text)


def _dispatch_number(spec: str, text: str) -> int:
    n = _number(spec, text, ", a range a-b or an open range a-")
    if n == 0:
        raise DispatchSpecError(spec, "dispatch numbers start at 1 (the first dispatch of a kernel is 1)")
    return n


def parse(spec: str) -> DispatchSpec:
    """Parse a dispatch spec; raise DispatchSpecError if it is malformed."""
    if spec == "":
        raise DispatchSpecError(spec, "empty dispatch spec")
    if any(c.isspace() for c in spec):
        raise DispatchSpecError(spec, "whitespace is not allowed in a dispatch spec")
    body = spec
    if body.startswith("["):
        if not body.endswith("]"):
            raise DispatchSpecError(spec, "unbalanced '['")
        body = body[1:-1]
    elif body.endswith("]"):
        raise DispatchSpecError(spec, "unbalanced ']'")
    if "[" in body or "]" in body:
        raise DispatchSpecError(spec, "brackets may only enclose the whole spec")
    if body == "all":
        return DispatchSpec(all=True)
    if body == "random":
        raise DispatchSpecError(spec, RANDOM_REMOVED)

    fields = body.split(":")
    if len(fields) > 3:
        raise DispatchSpecError(spec, "too many ':' fields (expected pattern[:count[:stride]])")

    intervals: List[Tuple[int, Optional[int]]] = []
    for item in fields[0].split(","):
        if item == "":
            raise DispatchSpecError(spec, "empty item in dispatch list")
        lo_text, dash, hi_text = item.partition("-")
        lo = _dispatch_number(spec, lo_text) if lo_text else _dispatch_number(spec, item)
        if not dash:
            intervals.append((lo, lo))
        elif hi_text == "":
            intervals.append((lo, None))
        else:
            hi = _dispatch_number(spec, hi_text)
            if hi < lo:
                raise DispatchSpecError(spec, f"range {lo}-{hi} is empty: the end must be >= the start")
            intervals.append((lo, hi))

    count: Optional[int] = 1
    if len(fields) >= 2:
        if fields[1] == "":
            count = None
        else:
            count = _number(spec, fields[1], " for the repeat count")
            if count == 0:
                raise DispatchSpecError(
                    spec, "repeat count must be >= 1 (leave it empty, as in 1,3::S, for unbounded)")

    lo_min = min(lo for lo, _ in intervals)
    hi_max = max((hi if hi is not None else lo) for lo, hi in intervals)
    stride = hi_max - lo_min + 1
    if len(fields) == 3 and fields[2] != "":
        stride = _number(spec, fields[2], " for the stride")
        if stride == 0:
            raise DispatchSpecError(spec, "stride must be >= 1")

    if count != 1 and any(hi is None for _, hi in intervals):
        raise DispatchSpecError(spec, "an open range a- cannot be repeated")

    return DispatchSpec(all=False, intervals=intervals, count=count, stride=stride)


def normalize(spec: str) -> str:
    """Validate *spec* and return it without enclosing brackets (the env form)."""
    parse(spec)
    return spec[1:-1] if spec.startswith("[") else spec
