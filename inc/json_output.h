#pragma once

#include <nlohmann/json.hpp>
#include <string>
#include <chrono>
#include <fstream>
#include <memory>

using json = nlohmann::json;

class JsonOutputManager {
public:
    static JsonOutputManager& getInstance() {
        static JsonOutputManager instance;
        return instance;
    }

    void initializeKernelAnalysis(const std::string& kernel_name, uint64_t dispatch_id) {
        if (!current_analysis_.contains("kernel_analyses")) {
            current_analysis_["kernel_analyses"] = json::array();
        }

        json kernel_analysis;
        kernel_analysis["kernel_info"]["name"] = kernel_name;
        kernel_analysis["kernel_info"]["dispatch_id"] = dispatch_id;
        kernel_analysis["cache_analysis"]["accesses"] = json::array();
        kernel_analysis["bank_conflicts"]["accesses"] = json::array();
        
        current_analysis_["kernel_analyses"].push_back(kernel_analysis);
    }

    void setMetadata(const std::string& gpu_arch, uint32_t cache_line_size, size_t kernels_found) {
        current_analysis_["metadata"] = {
            {"timestamp", std::chrono::system_clock::now().time_since_epoch().count()},
            {"version", "1.0"},
            {"gpu_info", {
                {"architecture", gpu_arch},
                {"cache_line_size", cache_line_size}
            }},
            {"kernels_found", kernels_found}
        };
    }

    void updateKernelsFound(size_t kernels_found) {
        if (current_analysis_.contains("metadata")) {
            current_analysis_["metadata"]["kernels_found"] = kernels_found;
        }
    }

    void addCacheAnalysis(const std::string& file, uint32_t line, uint32_t column,
                         const std::string& code_context, const std::string& access_type,
                         uint16_t ir_bytes, uint16_t isa_bytes, const std::string& isa_instruction,
                         size_t execution_count, size_t cache_lines_needed, size_t cache_lines_used) {
        if (current_analysis_["kernel_analyses"].empty()) return;

        json access;
        access["source_location"] = {
            {"file", file},
            {"line", line},
            {"column", column}
        };
        access["code_context"] = code_context;
        access["access_info"] = {
            {"type", access_type},
            {"ir_bytes", ir_bytes},
            {"isa_bytes", isa_bytes},
            {"isa_instruction", isa_instruction},
            {"execution_count", execution_count},
            {"cache_lines", {
                {"needed", cache_lines_needed},
                {"used", cache_lines_used}
            }}
        };

        auto& current_kernel = current_analysis_["kernel_analyses"].back();
        current_kernel["cache_analysis"]["accesses"].push_back(access);
    }

    void addBankConflict(const std::string& file, uint32_t line, uint32_t column,
                        const std::string& code_context, const std::string& access_type,
                        uint16_t ir_bytes, size_t execution_count, size_t total_conflicts) {
        if (current_analysis_["kernel_analyses"].empty()) return;

        json access;
        access["source_location"] = {
            {"file", file},
            {"line", line},
            {"column", column}
        };
        access["code_context"] = code_context;
        access["access_info"] = {
            {"type", access_type},
            {"ir_bytes", ir_bytes},
            {"execution_count", execution_count},
            {"total_conflicts", total_conflicts}
        };

        auto& current_kernel = current_analysis_["kernel_analyses"].back();
        current_kernel["bank_conflicts"]["accesses"].push_back(access);
    }

    void setExecutionTimes(uint64_t start_ns, uint64_t end_ns, uint64_t complete_ns) {
        if (current_analysis_["kernel_analyses"].empty()) return;

        auto& current_kernel = current_analysis_["kernel_analyses"].back();
        current_kernel["kernel_info"]["execution_time"] = {
            {"start_ns", start_ns},
            {"end_ns", end_ns},
            {"complete_ns", complete_ns}
        };
    }

    void setProcessingStats(size_t bytes_processed, double processing_time_seconds) {
        if (current_analysis_["kernel_analyses"].empty()) return;

        auto& current_kernel = current_analysis_["kernel_analyses"].back();
        current_kernel["kernel_info"]["bytes_processed"] = bytes_processed;
        current_kernel["kernel_info"]["processing_time_seconds"] = processing_time_seconds;
        current_kernel["kernel_info"]["throughput_mib_per_sec"] = 
            (bytes_processed / processing_time_seconds) / 1.0e6;
    }

    void writeToFile(const std::string& filename) {
        std::ofstream out(filename);
        out << current_analysis_.dump(2);
    }

    void clear() {
        current_analysis_.clear();
    }

private:
    JsonOutputManager() = default;
    json current_analysis_;
}; 