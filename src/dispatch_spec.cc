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
#include "inc/dispatch_spec.h"

#include <algorithm>
#include <cctype>
#include <stdexcept>

namespace {

constexpr uint64_t MAX_NUMBER = 9223372036854775807ULL;  // 2^63 - 1

struct specError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

uint64_t number(const std::string& text, const std::string& what)
{
    if (text.empty() || !std::all_of(text.begin(), text.end(), [](unsigned char c) { return c >= '0' && c <= '9'; }))
        throw specError("expected a number" + what + "; got '" + text + "'");
    size_t first = text.find_first_not_of('0');
    std::string digits = first == std::string::npos ? "0" : text.substr(first);
    if (digits.size() > 19 || (digits.size() == 19 && digits > "9223372036854775807"))
        throw specError("number '" + text + "' is too large (max " + std::to_string(MAX_NUMBER) + ")");
    return std::stoull(digits);
}

uint64_t dispatchNumber(const std::string& text)
{
    uint64_t n = number(text, ", a range a-b or an open range a-");
    if (n == 0)
        throw specError("dispatch numbers start at 1 (the first dispatch of a kernel is 1)");
    return n;
}

std::vector<std::string> split(const std::string& s, char sep)
{
    std::vector<std::string> parts;
    size_t start = 0;
    for (;;) {
        size_t pos = s.find(sep, start);
        parts.push_back(s.substr(start, pos == std::string::npos ? std::string::npos : pos - start));
        if (pos == std::string::npos)
            return parts;
        start = pos + 1;
    }
}

} // namespace

bool dispatchSpec::parse(const std::string& spec, std::string& error)
{
    try {
        if (spec.empty())
            throw specError("empty dispatch spec");
        if (std::any_of(spec.begin(), spec.end(), [](unsigned char c) { return std::isspace(c); }))
            throw specError("whitespace is not allowed in a dispatch spec");
        std::string body = spec;
        if (body.front() == '[') {
            if (body.size() < 2 || body.back() != ']')
                throw specError("unbalanced '['");
            body = body.substr(1, body.size() - 2);
        } else if (body.back() == ']') {
            throw specError("unbalanced ']'");
        }
        if (body.find_first_of("[]") != std::string::npos)
            throw specError("brackets may only enclose the whole spec");
        if (body == "all") {
            all_ = true;
            return true;
        }
        if (body == "random")
            throw specError("-d random was removed; for sampling use e.g. -d 1::100 "
                            "(every 100th dispatch of each kernel)");

        std::vector<std::string> fields = split(body, ':');
        if (fields.size() > 3)
            throw specError("too many ':' fields (expected pattern[:count[:stride]])");

        std::vector<std::pair<uint64_t, uint64_t>> intervals;
        for (const std::string& item : split(fields[0], ',')) {
            if (item.empty())
                throw specError("empty item in dispatch list");
            size_t dash = item.find('-');
            if (dash == std::string::npos) {
                uint64_t n = dispatchNumber(item);
                intervals.emplace_back(n, n);
                continue;
            }
            std::string lo_text = item.substr(0, dash), hi_text = item.substr(dash + 1);
            uint64_t lo = dispatchNumber(lo_text.empty() ? item : lo_text);
            if (hi_text.empty()) {
                intervals.emplace_back(lo, OPEN);
                continue;
            }
            uint64_t hi = dispatchNumber(hi_text);
            if (hi < lo)
                throw specError("range " + std::to_string(lo) + "-" + std::to_string(hi) +
                                " is empty: the end must be >= the start");
            intervals.emplace_back(lo, hi);
        }

        uint64_t count = 1;
        if (fields.size() >= 2) {
            if (fields[1].empty())
                count = 0;
            else {
                count = number(fields[1], " for the repeat count");
                if (count == 0)
                    throw specError("repeat count must be >= 1 (leave it empty, as in 1,3::S, for unbounded)");
            }
        }

        uint64_t lo_min = UINT64_MAX, hi_max = 0;
        bool open = false;
        for (const auto& [lo, hi] : intervals) {
            lo_min = std::min(lo_min, lo);
            hi_max = std::max(hi_max, hi == OPEN ? lo : hi);
            open = open || hi == OPEN;
        }
        uint64_t stride = hi_max - lo_min + 1;
        if (fields.size() == 3 && !fields[2].empty()) {
            stride = number(fields[2], " for the stride");
            if (stride == 0)
                throw specError("stride must be >= 1");
        }

        if (count != 1 && open)
            throw specError("an open range a- cannot be repeated");

        all_ = false;
        intervals_ = std::move(intervals);
        count_ = count;
        stride_ = stride;
        return true;
    } catch (const specError& e) {
        error = "invalid dispatch spec '" + spec + "': " + e.what();
        return false;
    }
}

bool dispatchSpec::contains(uint64_t n) const
{
    if (all_)
        return true;
    if (n < 1)
        return false;
    for (const auto& [lo, hi] : intervals_) {
        if (n < lo)
            continue;
        if (hi == OPEN)
            return true;
        // Copies k with lo + k*stride <= n <= hi + k*stride.
        uint64_t kmin = n <= hi ? 0 : (n - hi) / stride_ + ((n - hi) % stride_ != 0);
        uint64_t kmax = (n - lo) / stride_;
        if (count_ != 0)
            kmax = std::min(kmax, count_ - 1);
        if (kmin <= kmax)
            return true;
    }
    return false;
}
