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
#include <iostream>
#include <sstream>
#include <cassert>
#include <set>
#include "inc/basic_block_analysis.h"
#include "time_interval_handler.h"
#include <iomanip>
#include <fstream>
#include <cstdint>
#include <stdexcept>
#include <algorithm>

std::atomic<bool> basic_block_analysis::banner_displayed_ = false;

double calculatePercentile(std::vector<double>& data, double percentile) {
    if (data.empty()) return 0.0;
    size_t n = data.size();

    // Sort the vector
    std::sort(data.begin(), data.end());

    // Calculate index for the percentile
    double index = percentile * (n - 1);
    size_t lower = static_cast<size_t>(index);
    double fraction = index - lower;

    // If index is exact, return the value
    if (fraction == 0.0) {
        return data[lower];
    }

    // Linear interpolation between lower and upper elements
    return data[lower] + fraction * (data[lower + 1] - data[lower]);
}

std::vector<std::string> readFileLines(const std::string& filename, uint32_t startLine, uint32_t endLine) {
    std::vector<std::string> lines;

    // Validate input parameters
    if (startLine == 0 || startLine > endLine) {
        throw std::invalid_argument("Invalid line range: startLine must be >= 1 and <= endLine");
    }

    std::ifstream file(filename);
    if (!file.is_open()) {
        throw std::runtime_error("Unable to open file: " + filename);
    }

    std::string line;
    uint32_t currentLine = 0;

    // Read until we reach startLine or EOF
    while (currentLine < startLine - 1 && std::getline(file, line)) {
        ++currentLine;
    }

    // Read lines from startLine to endLine inclusive
    while (currentLine < endLine && std::getline(file, line)) {
        lines.push_back(line);
        ++currentLine;
    }

    file.close();
    return lines;
}

void printVectorsSideBySide(const std::vector<std::string>& vec1, const std::vector<std::string>& vec2) {
    // Find the longest string in each vector for column width
    size_t maxLen1 = 0, maxLen2 = 0;
    for (const auto& str : vec1) {
        maxLen1 = std::max(maxLen1, str.length());
    }
    for (const auto& str : vec2) {
        maxLen2 = std::max(maxLen2, str.length());
    }

    // Print vectors side by side
    size_t maxRows = std::max(vec1.size(), vec2.size());
    for (size_t i = 0; i < maxRows; ++i) {
        // Print first vector element (or empty if index exceeds size)
        std::cout << std::left << std::setw(maxLen1 + 2);
        if (i < vec1.size()) {
            std::cout << vec1[i];
        } else {
            std::cout << "";
        }

        // Print second vector element (or empty if index exceeds size)
        std::cout << std::left << std::setw(maxLen2 + 2);
        if (i < vec2.size()) {
            std::cout << vec2[i];
        } else {
            std::cout << "";
        }

        std::cout << std::endl;
    }
}

uint32_t countSetBits(uint64_t mask) {
    uint32_t count = 0;
    while (mask) {
        count += mask & 1;
        mask >>= 1;
    }
    return count;
}

basic_block_analysis::basic_block_analysis(const std::string& strKernel, uint64_t dispatch_id, std::string& strLocation, bool verbose)
    : first_start_(0xffffffffffffffff),
      last_stop_(0),
      total_time_(0),
      no_intervals_(0),
      verbose_(verbose),
      strKernel_(strKernel),
      dispatch_id_(dispatch_id),
      current_block_(nullptr),
      start_time_(0),
      location_(strLocation)
{
    message_count_ = 0;
}


basic_block_analysis::~basic_block_analysis()
{
}

std::string wave_identifier_to_string(waveIdentifier_t& wave)
{
    std::stringstream ss;
    ss << "(" << wave.block_x_ << "," << wave.block_y_ << "," << wave.block_z_ << ":" << (uint32_t)wave.wave_id_ << ")";
    return ss.str();
}

bool basic_block_analysis::handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb)
{
    bool bReturn = true;
    message_count_++;
    auto hdr = message.wave_header();
    waveIdentifier_t wave = {hdr.block_idx_x, hdr.block_idx_y, hdr.block_idx_z, hdr.wave_num};

    try
    {
        uint32_t block_idx = hdr.user_data;
        auto& thisKernel = kdb.getKernel(kernel);
        const auto& blocks = thisKernel.getBasicBlocks();
        //std::cerr << blocks.size() << " for kernel " << kernel << " with block_idx == " << block_idx << std::endl;
        assert(block_idx < blocks.size());
        kernelDB::basicBlock *thisBlock = blocks[block_idx].get();
        auto& instructions = thisBlock->getInstructions();
        if (instructions.size())
        {
            std::set<kernelDB::basicBlock *> blocks;
            for (auto& in : instructions)
                blocks_seen_.insert(in.block_);
            auto biit = block_info_.find(thisBlock);
    //        std::cout << "Message Type: " << hdr.user_type << std::endl;
            if (hdr.user_type == dh_comms::message_type::time_interval)
            {
                assert(false); // Should not be getting here
                dh_comms::time_interval ti = *(const dh_comms::time_interval *)message.data_item(0);
                if (biit != block_info_.end())
                {
                    biit->second.count_++;
                    biit->second.thread_count_ += countSetBits(hdr.exec);
                    biit->second.duration_ += ti.stop - ti.start;
                }
                else
                {
                    //assert(ti.stop - ti.start != 0);
                    block_info_[thisBlock] = {countSetBits(hdr.exec), 1, ti.stop - ti.start, hdr.dwarf_line};
                }
            }
            else
            {
                auto wsit = wave_states_.find(wave);
                // If we have a state cached for this wave, use that data to update the block
                // count and duration
                // Otherwise, just set the wave state
                if (wsit != wave_states_.end())
                {
                    // If we have seen this block already
                    // increment the count and add the current duration 
                    // otherwise, just set the count to 1 and set the duration.
                    biit = block_info_.find(wsit->second.current_block_);
                    if (biit != block_info_.end())
                    {
                        //std::cerr << "Message count: " << message_count_ << " on block update -- " << wave_identifier_to_string(wave) << std::endl;
                        biit->second.count_+= wsit->second.count_;
                        biit->second.thread_count_ += countSetBits(hdr.exec);
                        biit->second.duration_ += hdr.timestamp - wsit->second.start_time_;
                    }
                    else
                    {
                        //std::cerr << "Message count: " << message_count_ << " on block add -- " << wave_identifier_to_string(wave) << std::endl;
                        block_info_[wsit->second.current_block_] = {countSetBits(hdr.exec), 1, hdr.timestamp - wsit->second.start_time_};
                    }
                    
                    // Need to check for s_endpgm and clean up wave state here
                    if (instructions[instructions.size() - 1].inst_ == "s_endpgm")
                    {
                        //std::cerr << "End Wave -- " << wave_identifier_to_string(wave) << std::endl;
                        wave_states_.erase(wsit);
                    }
                    else
                    {
                        wsit->second.current_block_ = thisBlock;
                        wsit->second.start_time_ = hdr.timestamp;
                        wsit->second.count_ = 1;
                    }
                }
                else
                {
                    //std::cerr << "New wave - " << wave_identifier_to_string(wave) << std::endl;
                    wave_states_[wave] = {thisBlock, hdr.timestamp, 1};
                }
            }
        }
        else
            std::cerr << "No instructions for block id " << block_idx << std::endl;
    }
    catch (std::runtime_error e)
    {
        std::cerr << e.what() << std::endl;
        return false;
    }
    return bReturn;
}

bool basic_block_analysis::handle(const dh_comms::message_t &message)
{
    return true;
}

void basic_block_analysis::setupLogger()
{
    if (location_ == "console")
        log_file_ = &std::cout;
    else
        log_file_ = new std::ofstream(location_, std::ios::app);
}

void basic_block_analysis::report(const std::string& kernel_name, kernelDB::kernelDB& kdb)
{
    bool bFormatCsv = true;
    const char* logDurLogFormat= std::getenv("LOGDUR_LOG_FORMAT");
    if (logDurLogFormat)
    {
        std::string strFormat = logDurLogFormat;
        if (strFormat == "json")
            bFormatCsv = false;
    }
    std::map<std::string, uint64_t> inst_counts;
    bool first_time = false, initialized = true;
    setupLogger();
    if (banner_displayed_.compare_exchange_strong(first_time, initialized))
        std::cerr << "omniprobe basic block analysis for kernel\n";
    auto it = block_info_.begin();
    uint64_t duration = 0;
    uint64_t block_exec_count = 0;
    uint64_t thread_exec_count = 0;
    while (it != block_info_.end())
    {
        duration += it->second.duration_;
        block_exec_count += it->second.count_;
        thread_exec_count += it->second.thread_count_;
        it++;
    }
    std::map<std::string, std::string> strings;
    std::map<std::string, uint64_t> bigints;
    std::map<std::string, double> doubles;

    strings["Kernel"] = strKernel_;
    bigints["Dispatch"] = dispatch_id_;
    doubles["Branchiness"] = 1.0 - ( (double) ((double)thread_exec_count / ((double)block_exec_count * 64.0)));
    if (bFormatCsv)
    {
        *log_file_ << "Kernel: " << strKernel_ << std::endl;
        *log_file_ << "Dispatch: " << dispatch_id_ << std::endl;
        *log_file_ << "Branchiness: " << 1.0 - ( (double) ((double)thread_exec_count / ((double)block_exec_count * 64.0))) << std::endl;
        *log_file_  << "Start Line, End Line, Duration, FileName, Branchiness, Overhead, Count\n";
    }
    it = block_info_.begin();
    while (it != block_info_.end())
    {
        std::vector<std::string> isa, files;
        auto instructions = it->first->getInstructions();
        for (auto inst : instructions)
        {
            isa.push_back(inst.disassembly_);
            files.push_back(kdb.getFileName(kernel_name, inst.path_id_));
            auto ic = inst_counts.find(inst.inst_);
            if (ic != inst_counts.end())
            {
                if (inst.inst_.starts_with("v_"))
                    inst_counts[inst.inst_] += it->second.thread_count_;
                else
                    ic->second += it->second.count_;
            }
            else
            {
                if (inst.inst_.starts_with("v_"))
                    inst_counts[inst.inst_] = it->second.thread_count_;
                else
                    inst_counts[inst.inst_] = it->second.count_;
            }
        }
        //std::cerr << "Instruction Counts" << std::endl;
        //for (auto& thisCount : inst_counts)
        //    std::cerr << "\t" << thisCount.first << ":" << thisCount.second << std::endl;
        std::stringstream ss;
        try
        {
            ss << "{";
            strings.clear();
            bigints.clear();
            doubles.clear();
            strings["Kernel"] = strKernel_;
            bigints["Dispatch"] = dispatch_id_;
            doubles["Kernel_Branchiness"] = 1.0 - ( (double) ((double)thread_exec_count / ((double)block_exec_count * 64.0)));
            bigints["Block_Start_Line"] = instructions[0].line_;
            bigints["Block_End_Line"] = instructions[instructions.size() - 1].line_;
            bigints["Kernel_Duration"] = it->second.duration_;
            strings["Kernel_File_Name"] = kdb.getFileName(kernel_name, instructions[0].path_id_);
            doubles["Block_Branchiness"] = 1.0 - ((double) ((double)it->second.thread_count_  / ((double) it->second.count_ * 64.0)));
            doubles["Block_Overhead"] = (double)((double) it->second.duration_ / (double) duration);
            doubles["Block_Count"] = it->second.count_;
            if (bFormatCsv)
            {
                *log_file_ << instructions[0].line_ << "," << instructions[instructions.size() - 1].line_ << "," << it->second.duration_ << "," << 
                    kdb.getFileName(kernel_name, instructions[0].path_id_) << "," <<  1.0 - ((double) ((double)it->second.thread_count_  / ((double) it->second.count_ * 64.0))) << "," << 
                        (double)((double) it->second.duration_ / (double) duration) 
                            << "," << it->second.count_ << std::endl;
            }
            else
            {
                renderJSON(strings, ss, false);
                renderJSON(bigints, ss, false);
                renderJSON(doubles, ss, true);
                ss << "}\n";
                *log_file_ << ss.str();
            }
            ss.str("");
            ss.clear();

        }
        catch (const std::exception& e)
        {
            std::cerr << e.what() << std::endl;
        }

//        printVectorsSideBySide(isa, files);

        it++;
    }
    if (location_ != "console")
        delete log_file_;
}

void basic_block_analysis::report()
{
    std::cerr << "omniprobe time_interval report for kernel " << strKernel_ << " dispatch[" << std::dec << dispatch_id_ << "]\n";

}

void basic_block_analysis::clear()
{
    strKernel_ = "";
    dispatch_id_ = 0;
}
