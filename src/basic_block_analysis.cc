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
#include <iostream>
#include <sstream>
#include <cassert>
#include <set>
#include "inc/basic_block_analysis.h"
#include "inc/time_interval_handler.h"
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

void basic_block_analysis::updateComputeResources(dh_comms::wave_header_t& hdr)
{
    workgroup_id_t wg = {hdr.block_idx_x, hdr.block_idx_y, hdr.block_idx_z};
    auto it = compute_resources_.find(hdr.xcc_id);
    if (it != compute_resources_.end())
    {
        auto jit = it->second.find(hdr.se_id);
        if (jit == it->second.end())
            it->second[hdr.se_id][hdr.cu_id][wg] = {hdr.wave_num};
        else
        {
            auto kit = jit->second.find(hdr.cu_id);
            if (kit == jit->second.end())
                jit->second[hdr.cu_id][wg] = {hdr.wave_num};
            else
            {
                auto mit = kit->second.find(wg);
                if (mit == kit->second.end())
                    kit->second[wg] = {hdr.wave_num};
                else
                    mit->second.insert(hdr.wave_num);
            }
        }
    }
    else
    {
        compute_resources_[hdr.xcc_id][hdr.se_id][hdr.cu_id][wg] = {hdr.wave_num};
    }
}
    
void basic_block_analysis::printComputeResources(std::ostream& out, const std::string& format)
{
    for (const auto& xccs : compute_resources_)
    {
        out << "XCC[" << xccs.first << "]:\n";
        for (const auto& ses : xccs.second)
        {
            out << "\tSE[" << ses.first << "]:\n";
            for (const auto& cus : ses.second)
            {
                out << "\t\tCU[" << cus.first << "]:\n";
                for (const auto& wgs : cus.second)
                {
                    out << "\t\t\tWG[" << wgs.first.x << "," << wgs.first.y << "," << wgs.first.z << "]:\n";
                    out << "\t\t\t\tWave Count: " << wgs.second.size() << std::endl;
                }
            }
        }
    }
}

void basic_block_analysis::renderComputeResources(std::ostream& out, const std::string& format)
{
    std::stringstream ss;
    std::string tmpss;
    ss << "{\"kernel\": \"" << strKernel_ << "\", " << "\"dispatch\": " << dispatch_id_ << ", "; 
    ss << "\"resources\":[";
    for (const auto& xccs : compute_resources_)
    {
        ss << "{\"xcc_" << xccs.first << "\": [";
        for (const auto& ses : xccs.second)
        {
            ss << "{\"se_" << ses.first << "\": [";
            for (const auto& cus : ses.second)
            {
                size_t total_waves = 0;
                ss << "{\"cu_" << cus.first << "\": [";
                for (const auto& wgs : cus.second)
                {
                    ss << "\"(" << wgs.first.x << "," << wgs.first.y << "," << wgs.first.z << ")\",";
                    total_waves += wgs.second.size();
                }
                tmpss = ss.str();
                tmpss.pop_back();
                ss.str(tmpss);// Remove the last comma
                ss.seekp(0, std::ios::end);//Moving the seek pointer to the end so we keep appending
                ss << "],";
                ss << "\"avg_wave_count\": " << total_waves / cus.second.size() << "},";
            }
            tmpss = ss.str();
            tmpss.pop_back();
            ss.str(tmpss);// Remove the last comma
            ss.seekp(0, std::ios::end);//Moving the seek pointer to the end so we keep appending
            ss << "]},";
        }
        tmpss = ss.str();
        tmpss.pop_back();
        ss.str(tmpss);// Remove the last comma
        ss.seekp(0, std::ios::end);//Moving the seek pointer to the end so we keep appending
        ss << "]},";
    }
    tmpss = ss.str();
    tmpss.pop_back();
    ss.str(tmpss);// Remove the last comma
    ss.seekp(0, std::ios::end);//Moving the seek pointer to the end so we keep appending
    ss << "]}\n";
    out << ss.str();
}

bool basic_block_analysis::handle(const dh_comms::message_t &message)
{
    if (!kdb_p_)
        return true;

    bool bReturn = true;
    message_count_++;
    auto hdr = message.wave_header();
    waveIdentifier_t wave = {hdr.block_idx_x, hdr.block_idx_y, hdr.block_idx_z, hdr.wave_num};
    updateComputeResources(hdr);

    try
    {
        uint32_t block_idx = hdr.user_data;
        auto& thisKernel = kdb_p_->getKernel(kernel_name_);
        const auto& blocks = thisKernel.getBasicBlocks();
        assert(block_idx < blocks.size());
        kernelDB::basicBlock *thisBlock = blocks[block_idx].get();
        auto& instructions = thisBlock->getInstructions();
        if (instructions.size())
        {
            std::set<kernelDB::basicBlock *> blocks;
            for (auto& in : instructions)
                blocks_seen_.insert(in.block_);
            auto biit = block_info_.find(thisBlock);
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
                    block_info_[thisBlock] = {countSetBits(hdr.exec), 1, ti.stop - ti.start, hdr.dwarf_line};
                }
            }
            else
            {
                auto wsit = wave_states_.find(wave);
                if (wsit != wave_states_.end())
                {
                    biit = block_info_.find(wsit->second.current_block_);
                    double sample_duration = static_cast<double>(hdr.timestamp - wsit->second.start_time_);
                    if (biit != block_info_.end())
                    {
                        biit->second.count_+= wsit->second.count_;
                        biit->second.thread_count_ += countSetBits(hdr.exec);
                        biit->second.duration_ += hdr.timestamp - wsit->second.start_time_;
                        biit->second.duration_samples_.push_back(sample_duration);
                    }
                    else
                    {
                        block_info_[wsit->second.current_block_] = {countSetBits(hdr.exec), 1, hdr.timestamp - wsit->second.start_time_, 0, {sample_duration}};
                    }

                    if (instructions[instructions.size() - 1].inst_ == "s_endpgm")
                    {
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
                    wave_states_[wave] = {thisBlock, hdr.timestamp, 1};
                }
            }
        }
    }
    catch (std::runtime_error e)
    {
        std::cerr << e.what() << std::endl;
        return false;
    }
    return bReturn;
}

void basic_block_analysis::setupLogger()
{
    if (location_ == "console")
        log_file_ = &std::cout;
    else
        log_file_ = new std::ofstream(location_, std::ios::app);
}

void basic_block_analysis::report()
{
    if (!kdb_p_) {
        std::cerr << "omniprobe basic block analysis for kernel " << strKernel_ << " dispatch[" << std::dec << dispatch_id_ << "]\n";
        return;
    }

    const char* logDurLogFormat= std::getenv("LOGDUR_LOG_FORMAT");
    if (logDurLogFormat && std::string(logDurLogFormat) == "json") {
        report_json();
        return;
    }

    std::map<std::string, uint64_t> inst_counts;
    bool first_time = false, initialized = true;
    setupLogger();
    renderComputeResources(*log_file_, "json");
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

    *log_file_ << "Kernel: " << strKernel_ << std::endl;
    *log_file_ << "Dispatch: " << dispatch_id_ << std::endl;
    *log_file_ << "Branchiness: " << 1.0 - ( (double) ((double)thread_exec_count / ((double)block_exec_count * 64.0))) << std::endl;
    *log_file_  << "Start Line, End Line, Duration, FileName, Branchiness, Overhead, Count\n";

    it = block_info_.begin();
    while (it != block_info_.end())
    {
        auto instructions = it->first->getInstructions();
        for (auto inst : instructions)
        {
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

        try
        {
            *log_file_ << instructions[0].line_ << "," << instructions[instructions.size() - 1].line_ << "," << it->second.duration_ << "," <<
                kdb_p_->getFileName(kernel_name_, instructions[0].path_id_) << "," <<  1.0 - ((double) ((double)it->second.thread_count_  / ((double) it->second.count_ * 64.0))) << "," <<
                    (double)((double) it->second.duration_ / (double) duration)
                        << "," << it->second.count_ << std::endl;
        }
        catch (const std::exception& e)
        {
            std::cerr << e.what() << std::endl;
        }

        it++;
    }
    if (location_ != "console")
    {
        delete log_file_;
        log_file_ = nullptr;
    }
}

// Escape a string for use as a JSON string value.
static std::string bb_json_escape(const std::string &s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (char c : s) {
    switch (c) {
    case '"':  out += "\\\""; break;
    case '\\': out += "\\\\"; break;
    case '\b': out += "\\b";  break;
    case '\f': out += "\\f";  break;
    case '\n': out += "\\n";  break;
    case '\r': out += "\\r";  break;
    case '\t': out += "\\t";  break;
    default:
      if (static_cast<unsigned char>(c) < 0x20) {
        char buf[8];
        snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
        out += buf;
      } else {
        out += c;
      }
    }
  }
  return out;
}

void basic_block_analysis::report_json()
{
    setupLogger();
    std::stringstream json_output;

    json_output << "{\n";
    json_output << "  \"kernel\": \"" << bb_json_escape(strKernel_) << "\",\n";
    json_output << "  \"dispatch_id\": " << dispatch_id_ << ",\n";
    json_output << "  \"basic_blocks\": [\n";

    bool first_block = true;
    uint32_t block_index = 0;

    for (auto &bi : block_info_) {
        auto instructions = bi.first->getInstructions();
        if (instructions.empty())
            continue;

        if (!first_block) {
            json_output << ",\n";
        }
        first_block = false;

        std::string source_file;
        try {
            source_file = kdb_p_->getFileName(kernel_name_, instructions[0].path_id_);
        } catch (...) {
            source_file = "<unknown>";
        }

        // Calculate percentiles from duration_samples_
        double min_cycles = 0, max_cycles = 0;
        double p25 = 0, p50 = 0, p75 = 0, p95 = 0, p99 = 0;
        if (!bi.second.duration_samples_.empty()) {
            std::vector<double> samples = bi.second.duration_samples_;
            std::sort(samples.begin(), samples.end());
            min_cycles = samples.front();
            max_cycles = samples.back();
            p25 = calculatePercentile(samples, 0.25);
            p50 = calculatePercentile(samples, 0.50);
            p75 = calculatePercentile(samples, 0.75);
            p95 = calculatePercentile(samples, 0.95);
            p99 = calculatePercentile(samples, 0.99);
        } else if (bi.second.count_ > 0) {
            // Fallback: use average if no samples were collected
            double avg = static_cast<double>(bi.second.duration_) / bi.second.count_;
            min_cycles = max_cycles = p25 = p50 = p75 = p95 = p99 = avg;
        }

        json_output << "    {\n";
        json_output << "      \"basic_block_id\": " << block_index << ",\n";
        json_output << "      \"source_file\": \"" << bb_json_escape(source_file) << "\",\n";
        json_output << "      \"line\": " << instructions[0].line_ << ",\n";
        json_output << "      \"end_line\": " << instructions[instructions.size() - 1].line_ << ",\n";
        json_output << "      \"min_cycles\": " << std::fixed << std::setprecision(1) << min_cycles << ",\n";
        json_output << "      \"max_cycles\": " << max_cycles << ",\n";
        json_output << "      \"p25\": " << p25 << ",\n";
        json_output << "      \"p50\": " << p50 << ",\n";
        json_output << "      \"p75\": " << p75 << ",\n";
        json_output << "      \"p95\": " << p95 << ",\n";
        json_output << "      \"p99\": " << p99 << ",\n";
        json_output << "      \"wave_count\": " << bi.second.count_ << "\n";
        json_output << "    }";

        block_index++;
    }

    json_output << "\n  ]\n";
    json_output << "}\n";

    *log_file_ << json_output.str();

    if (location_ != "console")
    {
        delete log_file_;
        log_file_ = nullptr;
    }
}

void basic_block_analysis::clear()
{
    strKernel_ = "";
    dispatch_id_ = 0;
}
