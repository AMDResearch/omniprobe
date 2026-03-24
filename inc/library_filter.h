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

#include <string>
#include <vector>
#include <regex>
#include <set>

class LibraryFilter {
public:
    LibraryFilter() = default;

    // Load filter configuration from JSON file
    // Returns true on success, false on parse error
    bool loadConfig(const std::string& configPath);

    // Check if a library path should be excluded
    bool isExcluded(const std::string& path) const;

    // Get list of additional files to include (expands globs)
    std::vector<std::string> getIncludedFiles() const;

    // Get list of additional files to include along with their ELF dependencies
    std::vector<std::string> getIncludedFilesWithDeps() const;

    // Check if filter is active (config was loaded)
    bool isActive() const { return active_; }

private:
    // Convert glob pattern to regex
    static std::regex globToRegex(const std::string& pattern);

    // Check if path matches any pattern in the list
    bool matchesAnyPattern(const std::string& path,
                           const std::vector<std::regex>& patterns) const;

    // Check if file is a valid ELF binary
    static bool isValidElf(const std::string& path);

    // Get ELF dependencies using readelf/ldd
    static std::vector<std::string> getElfDependencies(const std::string& path);

    // Expand glob pattern to matching file paths
    static std::vector<std::string> expandGlob(const std::string& pattern);

    bool active_ = false;
    std::vector<std::string> includePatterns_;
    std::vector<std::string> includeWithDepsPatterns_;
    std::vector<std::regex> excludeRegexes_;
};
