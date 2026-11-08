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
#include "inc/json_output.h"
#include <iomanip>
#include <fstream>
#include <cstdint>
#include <stdexcept>
#include <algorithm>

std::atomic<bool> basic_block_analysis::banner_displayed_ = false;
std::atomic<bool> basic_block_analysis::warned_wrong_type_ = false;

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
    auto hdr = message.wave_header();
    // Only BBStart messages describe basic blocks. Anything else (address
    // messages from an AddressMessages-instrumented binary, time intervals from
    // BBInterval) is ignored, with one warning per process.
    if (hdr.user_type != dh_comms::message_type::basic_block_start) {
        bool expected = false;
        if (warned_wrong_type_.compare_exchange_strong(expected, true))
            std::cerr << "omniprobe basic block analysis: ignoring messages of type " << hdr.user_type
                      << " for " << strKernel_ << "; BasicBlockAnalysis needs a binary instrumented with "
                      << "the BBStart plugin (libAMDGCNSubmitBBStart-*.so)" << std::endl;
        return true;
    }
    message_count_++;
    updateComputeResources(hdr);

    // The block is identified by the BBStart plugin's own number for it
    // (user_data: the IR basic block's position in the kernel), and attributed
    // to the source location the plugin recorded. kernelDB's blocks are built
    // from the ISA with different boundaries and are not used to identify
    // blocks: an IR block number is not an index into them.
    auto& bb = blocks_[hdr.user_data];
    if (bb.wave_visits == 0) {
        bb.fname_hash = hdr.dwarf_fname_hash;
        bb.line = hdr.dwarf_line;
        bb.column = hdr.dwarf_column;
    }
    bb.wave_visits++;
    bb.active_lanes += countSetBits(hdr.exec);
    return true;
}

// Source file names for the hashes BBStart sends (std::hash of the path),
// from the file names kernelDB recorded for this kernel's instructions.
std::map<uint64_t, std::string> basic_block_analysis::resolveFileNames()
{
    std::map<uint64_t, std::string> names;
    names[std::hash<std::string>{}("<unknown source file>")] = "<unknown>";
    if (!kdb_p_)
        return names;
    try {
        std::set<size_t> path_ids;
        for (auto& block : kdb_p_->getKernel(kernel_name_).getBasicBlocks())
            for (auto& inst : block->getInstructions())
                path_ids.insert(inst.path_id_);
        for (auto id : path_ids) {
            if (id == 0 || id == (size_t)-1)
                continue;
            std::string name = kdb_p_->getFileName(kernel_name_, id);
            if (!name.empty())
                names[std::hash<std::string>{}(name)] = name;
        }
    } catch (const std::exception& e) {
        std::cerr << "omniprobe basic block analysis: no source file names for " << strKernel_ << ": " << e.what() << std::endl;
    }
    return names;
}

std::string basic_block_analysis::fileNameFor(const std::map<uint64_t, std::string>& names, uint64_t hash)
{
    auto it = names.find(hash);
    if (it != names.end())
        return it->second;
    std::stringstream ss;
    ss << "<unresolved 0x" << std::hex << hash << ">";
    return ss.str();
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
    const char* logDurLogFormat= std::getenv("LOGDUR_LOG_FORMAT");
    if (logDurLogFormat && std::string(logDurLogFormat) == "json") {
        report_json();
        return;
    }

    setupLogger();
    bool first_time = false, initialized = true;
    if (banner_displayed_.compare_exchange_strong(first_time, initialized))
        std::cerr << "omniprobe basic block analysis for kernel\n";
    auto names = resolveFileNames();
    *log_file_ << "Kernel: " << strKernel_ << std::endl;
    *log_file_ << "Dispatch: " << dispatch_id_ << std::endl;
    *log_file_ << "basic_block_id,source_file,line,column,wave_visits,active_lanes\n";
    for (const auto& [id, bb] : blocks_)
        *log_file_ << id << ",\"" << fileNameFor(names, bb.fname_hash) << "\"," << bb.line << "," << bb.column << ","
                   << bb.wave_visits << "," << bb.active_lanes << "\n";
    log_file_->flush();
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
    std::stringstream json_output;
    if (location_ != "console")
        json_output << json_array_separator(location_);
    setupLogger();

    json_output << "{\n";
    json_output << "  \"kernel\": \"" << bb_json_escape(strKernel_) << "\",\n";
    json_output << "  \"dispatch_id\": " << dispatch_id_ << ",\n";
    json_output << "  \"basic_blocks\": [";

    auto names = resolveFileNames();
    bool first_block = true;
    for (const auto& [id, bb] : blocks_) {
        json_output << (first_block ? "\n" : ",\n");
        first_block = false;
        json_output << "    {\n";
        json_output << "      \"basic_block_id\": " << id << ",\n";
        json_output << "      \"source_file\": \"" << bb_json_escape(fileNameFor(names, bb.fname_hash)) << "\",\n";
        json_output << "      \"line\": " << bb.line << ",\n";
        json_output << "      \"column\": " << bb.column << ",\n";
        json_output << "      \"wave_visits\": " << bb.wave_visits << ",\n";
        json_output << "      \"active_lanes\": " << bb.active_lanes << "\n";
        json_output << "    }";
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
