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
// Reads one dispatch spec per line from stdin and prints, per line, either
// "ERR <message>" or "SET <members in 1..LIMIT, comma-separated>" ("SET -" for
// none). Driven by tests/dispatch_spec_table.py against dispatch_spec_cases.txt.
#include <iostream>
#include <string>
#include "inc/dispatch_spec.h"

int main(int argc, char** argv)
{
    uint64_t limit = argc > 1 ? std::stoull(argv[1]) : 300;
    std::string line;
    while (std::getline(std::cin, line)) {
        dispatchSpec spec;
        std::string error;
        if (!spec.parse(line, error)) {
            std::cout << "ERR " << error << "\n";
            continue;
        }
        std::string members;
        for (uint64_t n = 1; n <= limit; n++)
            if (spec.contains(n))
                members += (members.empty() ? "" : ",") + std::to_string(n);
        std::cout << "SET " << (members.empty() ? "-" : members) << "\n";
    }
    return 0;
}
