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
#include <string>
#include <sys/stat.h>

// Separator to write before a JSON object appended to the array in a -t json
// output file: "[" if the file is still empty, "," otherwise. The closing "]"
// is written by the omniprobe CLI after the run (finalize_json_output).
//
// Decided by the file, not by dispatch id or per-handler state: dispatch ids
// count dispatches that -k, -d or a missing instrumented clone kept away from
// the handler, and each dispatch gets fresh handler objects. The CLI truncates
// the file before the run, and reports are written one at a time under the
// comms manager's lock, so "empty" means "nothing written yet in this run".
inline const char* json_array_separator(const std::string& location)
{
    struct stat st;
    if (stat(location.c_str(), &st) != 0 || st.st_size == 0)
        return "[\n";
    return ",\n";
}
