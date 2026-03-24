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
#include "dh_comms.h"
#include "message_handlers.h"
#include "kernelDB.h"
#include <set>
#include <atomic>

class JSONHelper
{
public:
    JSONHelper();
    ~JSONHelper();
    template <typename T>
    void addFields(const std::map<std::string, T>& fields, bool quotes = false, bool hex = false);
    template <typename T>
    void addVector(const std::string& name, const std::vector<T>& items, bool quotes = false, bool hex = false);
    template <typename T>
    void addField(const std::string& name, T value, bool quotes = false, bool hex = false);
    void appendString(const std::string& str);
    std::string getJSON();
    void restart();
private:
    std::stringstream ss_;
};

template <typename T>
void renderJSON(std::map<std::string, T>& fields, std::iostream& out, bool omitFinalComma)
{
    if constexpr (std::is_same_v<T, std::string>) {
        auto it = fields.begin();
        while (it != fields.end())
        {
            out << "\"" << it->first << "\": \"" << it->second << "\"";
            it++;
            if (it != fields.end() || !omitFinalComma)
                out << ",";
        }
    }
    else
    {
        auto it = fields.begin();
        while (it != fields.end())
        {
            out << "\"" << it->first << "\": " << it->second;
            it++;
            if (it != fields.end() || !omitFinalComma)
                out << ",";
        }
    }
}

template <typename T>
void renderJSON(std::vector<std::pair<std::string, T>>& fields, std::iostream& out, bool omitFinalComma, bool valueAsString)
{
    if (valueAsString) {
        auto it = fields.begin();
        while (it != fields.end())
        {
            out << "\"" << it->first << "\": \"" << it->second << "\"";
            it++;
            if (it != fields.end() || !omitFinalComma)
                out << ",";
        }
    }
    else
    {
        auto it = fields.begin();
        while (it != fields.end())
        {
            out << "\"" << it->first << "\": " << it->second;
            it++;
            if (it != fields.end() || !omitFinalComma)
                out << ",";
        }
    }
}
