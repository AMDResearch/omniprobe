/******************************************************************************
Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.

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

#include "inc/library_filter.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <glob.h>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

// Simple JSON parsing helpers (no external dependency)
namespace {

std::string trim(const std::string& s) {
    size_t start = s.find_first_not_of(" \t\n\r");
    if (start == std::string::npos) return "";
    size_t end = s.find_last_not_of(" \t\n\r");
    return s.substr(start, end - start + 1);
}

// Parse a JSON array of strings: ["a", "b", "c"]
bool parseStringArray(const std::string& json, size_t& pos,
                      std::vector<std::string>& result) {
    // Skip whitespace
    while (pos < json.size() && std::isspace(json[pos])) pos++;

    if (pos >= json.size() || json[pos] != '[') return false;
    pos++;  // skip '['

    while (pos < json.size()) {
        // Skip whitespace
        while (pos < json.size() && std::isspace(json[pos])) pos++;

        if (json[pos] == ']') {
            pos++;
            return true;
        }

        if (json[pos] == ',') {
            pos++;
            continue;
        }

        if (json[pos] != '"') return false;
        pos++;  // skip opening quote

        std::string value;
        while (pos < json.size() && json[pos] != '"') {
            if (json[pos] == '\\' && pos + 1 < json.size()) {
                pos++;
                value += json[pos];
            } else {
                value += json[pos];
            }
            pos++;
        }
        if (pos >= json.size()) return false;
        pos++;  // skip closing quote

        result.push_back(value);
    }
    return false;
}

// Find key in JSON object and parse its array value
bool findAndParseArray(const std::string& json, const std::string& key,
                       std::vector<std::string>& result) {
    std::string searchKey = "\"" + key + "\"";
    size_t pos = json.find(searchKey);
    if (pos == std::string::npos) return true;  // Key not found is OK

    pos += searchKey.size();

    // Skip to colon
    while (pos < json.size() && json[pos] != ':') pos++;
    if (pos >= json.size()) return false;
    pos++;  // skip ':'

    return parseStringArray(json, pos, result);
}

}  // namespace

bool LibraryFilter::loadConfig(const std::string& configPath) {
    std::ifstream file(configPath);
    if (!file.is_open()) {
        std::cerr << "LibraryFilter: Cannot open config file: " << configPath
                  << std::endl;
        return false;
    }

    std::stringstream buffer;
    buffer << file.rdbuf();
    std::string json = buffer.str();

    // Parse include array
    if (!findAndParseArray(json, "include", includePatterns_)) {
        std::cerr << "LibraryFilter: Failed to parse 'include' array"
                  << std::endl;
        return false;
    }

    // Parse include_with_deps array
    if (!findAndParseArray(json, "include_with_deps", includeWithDepsPatterns_)) {
        std::cerr << "LibraryFilter: Failed to parse 'include_with_deps' array"
                  << std::endl;
        return false;
    }

    // Parse exclude array
    std::vector<std::string> excludePatterns;
    if (!findAndParseArray(json, "exclude", excludePatterns)) {
        std::cerr << "LibraryFilter: Failed to parse 'exclude' array"
                  << std::endl;
        return false;
    }

    // Convert exclude patterns to regexes
    for (const auto& pattern : excludePatterns) {
        try {
            excludeRegexes_.push_back(globToRegex(pattern));
        } catch (const std::regex_error& e) {
            std::cerr << "LibraryFilter: Invalid exclude pattern '" << pattern
                      << "': " << e.what() << std::endl;
            return false;
        }
    }

    active_ = true;
    return true;
}

std::regex LibraryFilter::globToRegex(const std::string& pattern) {
    std::string regex;
    regex.reserve(pattern.size() * 2);

    for (size_t i = 0; i < pattern.size(); i++) {
        char c = pattern[i];
        switch (c) {
            case '*':
                if (i + 1 < pattern.size() && pattern[i + 1] == '*') {
                    // ** matches anything including /
                    regex += ".*";
                    i++;  // skip second *
                } else {
                    // * matches anything except /
                    regex += "[^/]*";
                }
                break;
            case '?':
                regex += "[^/]";
                break;
            case '.':
            case '+':
            case '^':
            case '$':
            case '(':
            case ')':
            case '[':
            case ']':
            case '{':
            case '}':
            case '|':
            case '\\':
                regex += '\\';
                regex += c;
                break;
            default:
                regex += c;
        }
    }

    return std::regex(regex);
}

bool LibraryFilter::matchesAnyPattern(
    const std::string& path, const std::vector<std::regex>& patterns) const {
    for (const auto& pattern : patterns) {
        if (std::regex_match(path, pattern)) {
            return true;
        }
    }
    return false;
}

bool LibraryFilter::isExcluded(const std::string& path) const {
    if (!active_) return false;
    return matchesAnyPattern(path, excludeRegexes_);
}

bool LibraryFilter::isValidElf(const std::string& path) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;

    unsigned char magic[4];
    bool valid = (read(fd, magic, 4) == 4 &&
                  magic[0] == 0x7f && magic[1] == 'E' &&
                  magic[2] == 'L' && magic[3] == 'F');
    close(fd);
    return valid;
}

std::vector<std::string> LibraryFilter::expandGlob(const std::string& pattern) {
    std::vector<std::string> result;
    glob_t globResult;

    int flags = GLOB_TILDE | GLOB_NOCHECK;
    if (glob(pattern.c_str(), flags, nullptr, &globResult) == 0) {
        for (size_t i = 0; i < globResult.gl_pathc; i++) {
            result.push_back(globResult.gl_pathv[i]);
        }
    }
    globfree(&globResult);
    return result;
}

std::vector<std::string> LibraryFilter::getIncludedFiles() const {
    std::vector<std::string> result;
    for (const auto& pattern : includePatterns_) {
        auto expanded = expandGlob(pattern);
        for (const auto& path : expanded) {
            if (isValidElf(path)) {
                result.push_back(path);
            }
        }
    }
    return result;
}

std::vector<std::string> LibraryFilter::getElfDependencies(
    const std::string& path) {
    // TODO: Implement ELF dependency resolution
    // For now, return empty - will implement in Phase 4
    return {};
}

std::vector<std::string> LibraryFilter::getIncludedFilesWithDeps() const {
    std::set<std::string> result;

    for (const auto& pattern : includeWithDepsPatterns_) {
        auto expanded = expandGlob(pattern);
        for (const auto& path : expanded) {
            if (isValidElf(path)) {
                result.insert(path);
                auto deps = getElfDependencies(path);
                result.insert(deps.begin(), deps.end());
            }
        }
    }

    return std::vector<std::string>(result.begin(), result.end());
}
