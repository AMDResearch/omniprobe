
/******************************************************************************
Copyright (c) 2024 Advanced Micro Devices, Inc. All rights reserved.

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

typedef struct {
    uint64_t thread_count_;
    uint64_t count_;
    uint64_t duration_;
    uint32_t dwarf_line_;
}blockInfo_t;

typedef struct {
    uint32_t block_x_;
    uint32_t block_y_;
    uint32_t block_z_;
    uint8_t wave_id_;
}waveIdentifier_t;

template<typename T>
struct wave_cmp
{
    bool operator() (const T& first, const T& second) const
    {
        return memcmp(&first, &second, sizeof(T)) < 0;
    }
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

typedef struct {
    kernelDB::basicBlock *current_block_;
    uint64_t start_time_;
    uint64_t count_;
}wave_state_t;


class basic_block_analysis : public dh_comms::message_handler_base
{
public:
    basic_block_analysis(const std::string& strKernel, uint64_t dispatch_id, std::string& strLocation, bool verbose = false);
    basic_block_analysis(const basic_block_analysis &) = default;
    void setupLogger();
    virtual ~basic_block_analysis();
    virtual bool handle(const dh_comms::message_t &message) override;
    virtual bool handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb) override;
    virtual void report(const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
    virtual void report() override;
    virtual void clear() override;

private:
    uint64_t first_start_;
    uint64_t last_stop_;
    uint64_t total_time_;
    size_t no_intervals_;
    bool verbose_;
    std::string strKernel_;
    uint64_t message_count_;
    uint64_t dispatch_id_;
    kernelDB::basicBlock *current_block_;
    uint64_t start_time_;
    std::map<waveIdentifier_t,wave_state_t, wave_cmp<waveIdentifier_t>> wave_states_;
    std::map<kernelDB::basicBlock *, blockInfo_t> block_info_;
    std::map<kernelDB::basicBlock *, uint64_t> block_timings_;
    std::set<kernelDB::basicBlock *> blocks_seen_;
    std::string location_;
    std::ostream *log_file_;
    static std::atomic<bool> banner_displayed_;

};
