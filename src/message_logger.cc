
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
#include <cstdio>
#include <iostream>
#include <iomanip>
#include <vector>
#include <cassert>
#include "inc/message_logger.h"
#include "data_headers.h"
#include "message.h"

message_logger_t::message_logger_t(const std::string& strKernel, uint64_t dispatch_id, std::string& location, bool verbose)
    : strKernel_(strKernel),
      dispatch_id_(dispatch_id),
      location_(location),
      verbose_(verbose),
      format_csv_(true)
{
    location_ = location;
    if (location == "console")
        log_file_ = &std::cout;
    else
        log_file_ = new std::ofstream(location, std::ios::app);
    
    const char* logDurLogFormat= std::getenv("LOGDUR_LOG_FORMAT");
    if (logDurLogFormat)
    {
        std::string strFormat = logDurLogFormat;
        if (strFormat == "json")
            format_csv_ = false;
    }

    if (format_csv_)
        *log_file_ << "ADDRESS_MESSAGE,timestamp,kernel,src_line,dispatch,exec_mask,xcc_id,se_id,cu_id,kind,address" << std::endl;
}

message_logger_t::~message_logger_t()
{
    if(location_ != "console")
        delete log_file_;
}
bool message_logger_t::handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb)
{
    JSONHelper json;
    dh_comms::wave_header_t hdr = message.wave_header();
    switch(hdr.user_type)
    {
        case dh_comms::message_type::address:
            handle_header(message, json);
            handle_address_message(message, json);
            *log_file_ << json.getJSON() << std::endl;
            break;
        case dh_comms::message_type::time_interval:
            break;
        default:
            handle_header(message, json);
            *log_file_ << json.getJSON() << std::endl;
            break;
    }
    return true;
}

bool message_logger_t::handle(const dh_comms::message_t &message)
{
    auto hdr = message.wave_header();
    if (message.wave_header().user_type != dh_comms::message_type::address)
    {
        if (verbose_)
        {
            printf("message_logger: skipping message with user type 0x%x\n", message.wave_header().user_type);
        }
        return false;
    }
    assert(message.data_item_size() == sizeof(uint64_t));


    *log_file_ << "ADDRESS_MESSAGE," << std::dec << hdr.timestamp << ",\"" << strKernel_ << "\"," << hdr.dwarf_line << "," << dispatch_id_ << ",";


    *log_file_ << "0x" << std::hex << std::setw(sizeof(void*) * 2) << std::setfill('0') << hdr.exec << "," << std::dec << hdr.xcc_id << "," << hdr.se_id << "," << hdr.cu_id << ",";
    *log_file_ << (hdr.user_data & 0b11) << ",";
    for (size_t i = 0; i != message.no_data_items(); ++i)
    {
        uint64_t address = *(const uint64_t *)message.data_item(i);
        if (verbose_)
        {
            //printf("memory_heatmap: added address 0x%lx to map\n", address);
        }

        *log_file_ << "0x" << std::hex << std::setw(sizeof(void*) * 2) << std::setfill('0') << address;
        if (i < message.no_data_items() - 1)
            *log_file_ << ",";
        else
            *log_file_ << std::endl;
    }
    return true;
}
    
bool message_logger_t::handle_address_message(const dh_comms::message_t& message, JSONHelper& json)
{
    auto hdr = message.wave_header();
    if (message.wave_header().user_type != dh_comms::message_type::address)
    {
        if (verbose_)
        {
            printf("message_logger: skipping message with user type 0x%x\n", message.wave_header().user_type);
        }
        return false;
    }
    assert(message.data_item_size() == sizeof(uint64_t));

    if (format_csv_)
    {
        *log_file_ << "ADDRESS_MESSAGE," << std::dec << hdr.timestamp << ",\"" << strKernel_ << "\"," << hdr.dwarf_line << "," << dispatch_id_ << ",";


        *log_file_ << "0x" << std::hex << std::setw(sizeof(void*) * 2) << std::setfill('0') << hdr.exec << "," << std::dec << hdr.xcc_id << "," << hdr.se_id << "," << hdr.cu_id << ",";
        *log_file_ << (hdr.user_data & 0b11) << ",";
        for (size_t i = 0; i != message.no_data_items(); ++i)
        {
            uint64_t address = *(const uint64_t *)message.data_item(i);
            if (verbose_)
            {
                //printf("memory_heatmap: added address 0x%lx to map\n", address);
            }

            *log_file_ << "0x" << std::hex << std::setw(sizeof(void*) * 2) << std::setfill('0') << address;
            if (i < message.no_data_items() - 1)
                *log_file_ << ",";
            else
                *log_file_ << std::endl;
        }
    }
    else
    {
        std::vector<uint64_t> addrs;
        for (size_t i = 0; i != message.no_data_items(); ++i)
            addrs.push_back( *(const uint64_t *)message.data_item(i));
        if (addrs.size())
            json.addVector("addresses", addrs, false, false);

    }
    return true;
}

bool message_logger_t::handle_timeinterval_message(const dh_comms::message_t& message, JSONHelper& json)
{
    return true;
}

void message_logger_t::handle_header(const dh_comms::message_t& message, JSONHelper& json)
{
    auto hdr = message.wave_header();
    json.addField("kernel_name", strKernel_, true);
    json.addField("dispatch_id", dispatch_id_);
    json.addField("exec", hdr.exec, false, false);
    json.addField("timestamp", hdr.timestamp);
    json.addField("dwarf_line", hdr.dwarf_line);
    json.addField("dwarf_column", hdr.dwarf_column);
    json.addField("block_idx_x", hdr.block_idx_x);
    json.addField("block_idx_y", hdr.block_idx_y);
    json.addField("block_idx_z", hdr.block_idx_z);
    json.addField("wave_num", ((uint16_t)hdr.wave_num));
    json.addField("xcc_id", ((uint16_t)hdr.xcc_id));
    json.addField("se_id", ((uint16_t)hdr.se_id));
    json.addField("cu_id", ((uint16_t)hdr.cu_id));
    json.addField("active_lane_count", (uint16_t)hdr.active_lane_count);
    json.addField("user_type", (uint16_t) hdr.user_type);

    if(hdr.user_type == dh_comms::message_type::address)
    {
        switch(hdr.user_data & 0b11)
        {
            case dh_comms::memory_access::undefined:
                json.addField("op_type", "\"undefined\"");
                break;
            case dh_comms::memory_access::read:
                json.addField("op_type", "\"read\"");
                break;
            case dh_comms::memory_access::write:
                json.addField("op_type", "\"write\"");
                break;
            case dh_comms::memory_access::read_write:
                json.addField("op_type", "\"readwrite\"");
                break;
        }
    }
    else
        json.addField("user_data", (uint16_t)hdr.user_data);
    return;
}

void message_logger_t::report(const std::string& kernel_name, kernelDB::kernelDB& kdb)
{
    if (kernel_name.length() == 0)
    {
        std::vector<uint32_t> lines;
        kdb.getKernelLines(kernel_name, lines);
    }
    report();
}

void message_logger_t::report()
{
    printf("Omniprobe Message Logger complete.\n");
}

void message_logger_t::clear()
{
}
