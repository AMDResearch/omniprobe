/******************************************************************************
Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*******************************************************************************/
#pragma once
// Dispatch selection specs (omniprobe -d). The grammar and semantics are those of
// omniprobe/api/dispatch_spec.py, which documents them; both parsers are checked
// against tests/dispatch_spec_cases.txt, so keep the error reasons identical.
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

class dispatchSpec {
public:
    // Parses spec; on failure returns false and sets error to the full message
    // ("invalid dispatch spec '<spec>': <reason>").
    bool parse(const std::string& spec, std::string& error);
    // Whether the n-th dispatch (1-based) of a kernel is selected.
    bool contains(uint64_t n) const;
    bool isAll() const { return all_; }
private:
    static constexpr uint64_t OPEN = UINT64_MAX;  // hi of an open range a-
    bool all_ = true;
    std::vector<std::pair<uint64_t, uint64_t>> intervals_;  // inclusive
    uint64_t count_ = 1;  // 0: repeat without end
    uint64_t stride_ = 1;
};
