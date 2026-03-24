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

#include "inc/json_helpers.h"


JSONHelper::JSONHelper()
{
    ss_ << "{";
}

JSONHelper::~JSONHelper()
{
}

template <typename T>
void JSONHelper::addFields(const std::map<std::string, T>& fields, bool quotes, bool hex)
{
    for (const auto& field : fields)
        addField(field.first, field.second);
}

template <typename T>
void JSONHelper::addVector(const std::string& name, const std::vector<T>& items, bool quotes, bool hex)
{
    ss_ << "\"" << name << "\": [";
    std::stringstream tmp;
    for (const auto& item : items)
    {
        if (quotes)
            tmp << "\"";
        if (hex)
            tmp << "0x" << std::hex;
        tmp << item;
        if (quotes)
            tmp << "\"";
        tmp << ",";
        tmp << std::dec;
    }
    std::string result = tmp.str();
    result.pop_back();
    ss_ << result << "],";
}

template <typename T>
void JSONHelper::addField(const std::string& name, T value, bool quotes, bool hex)
{
    ss_ << "\"" << name << "\": "; 
    if (quotes)
        ss_ << "\"";
    if (hex)
        ss_ << std::hex << "0x";
    ss_ << value;
    if (quotes)
        ss_ << "\"";
    ss_ << ",";
    ss_ << std::dec;
}

void JSONHelper::appendString(const std::string& str)
{
    ss_ << str;
}

std::string JSONHelper::getJSON()
{
    std::string json = ss_.str();
    if (json.ends_with(","))
        json.pop_back();
    json += "}";
    return json;
}

void JSONHelper::restart()
{
    ss_.str("");
    ss_.clear();
    ss_ << "{";
}

template void JSONHelper::addField<uint64_t>(const std::string&, uint64_t, bool, bool);
template void JSONHelper::addField<uint32_t>(const std::string&, uint32_t, bool, bool);
template void JSONHelper::addField<uint16_t>(const std::string&, uint16_t, bool, bool);
template void JSONHelper::addField<uint8_t>(const std::string&, uint8_t, bool, bool);
template void JSONHelper::addField<std::string>(const std::string&, std::string, bool, bool);
template void JSONHelper::addField<const char *>(const std::string&, const char *, bool, bool);
template void JSONHelper::addVector<uint64_t>(const std::string&, const std::vector<uint64_t>&, bool, bool);
template void JSONHelper::addVector<std::string>(const std::string&, const std::vector<std::string>&, bool, bool);
