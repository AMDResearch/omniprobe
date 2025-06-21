// MIT License
//
// Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include "memory_analysis_handler.h"

#include "hip_utils.h"
#include "utils.h"

#include <cassert>
#include <hip/hip_runtime.h>
#include <set>
#include <string>

namespace {
constexpr size_t no_banks = 32;

constexpr uint8_t L2_cache_line_sizes[] = {
    0,   // unsupported archs
    64,  // gfx906
    64,  // gfx908
    128, // gfx90a
    128, // gfx940
    128, // gfx941
    128  // gfx942
};

} // namespace

namespace dh_comms {

// See memory_analysis_handler.h for an explanation of conflict sets.
conflict_set::conflict_set(const std::vector<std::pair<std::size_t, std::size_t>> &fl_pairs)
    : lanes(),
      banks(std::vector<std::set<uint64_t>>(32)) {
  for (const auto &fl_pair : fl_pairs) {
    assert(fl_pair.first < fl_pair.second);
    for (std::size_t i = fl_pair.first; i != fl_pair.second; ++i) {
      lanes.insert(i);
    }
  }
}
bool conflict_set::register_access(size_t lane, uint64_t address) {
  if (lanes.find(lane) == lanes.end()) { // lane is not in this conflict set
    return false;
  }
  uint64_t dword = address / sizeof(uint32_t);
  size_t bank = dword % no_banks;
  banks[bank].insert(dword);
  return true;
}

size_t conflict_set::bank_conflict_count() const {
  size_t max_different_dwords_per_bank = 1;
  for (const auto &bank : banks) {
    max_different_dwords_per_bank = std::max(max_different_dwords_per_bank, bank.size());
  }
  return max_different_dwords_per_bank - 1;
}

void conflict_set::clear() {
  for (auto &bank : banks) {
    bank.clear();
  }
}

memory_analysis_handler_t::memory_analysis_handler_t(bool verbose)
    : conflict_sets(),
      verbose_(verbose),
      rw2str_map{
          {dh_comms::memory_access::undefined, "unspecified memory operation"},
          {dh_comms::memory_access::read, "read"},
          {dh_comms::memory_access::write, "write"},
          {dh_comms::memory_access::read_write, "read/write"},
      },
      instr_size_map{
          {"global_load_dword", {4, memory_access::read}},      {"global_load_dwordx2", {8, memory_access::read}},
          {"global_load_dwordx3", {12, memory_access::read}},   {"global_load_dwordx4", {16, memory_access::read}},
          {"global_store_dword", {4, memory_access::write}},    {"global_store_dwordx2", {8, memory_access::write}},
          {"global_store_dwordx3", {12, memory_access::write}}, {"global_store_dwordx4", {16, memory_access::write}},
      } {
  conflict_sets.insert({1, std::vector<conflict_set>{
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{0, 32}}},
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{32, 64}}},
                           }});
  conflict_sets.insert({2, std::vector<conflict_set>{
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{0, 32}}},
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{32, 64}}},
                           }});
  conflict_sets.insert({4, std::vector<conflict_set>{
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{0, 32}}},
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{32, 64}}},
                           }});
  conflict_sets.insert({8, std::vector<conflict_set>{
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{0, 16}}},
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{16, 32}}},
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{32, 48}}},
                               conflict_set{std::vector<std::pair<size_t, size_t>>{{48, 64}}},
                           }});
  conflict_sets.insert({16, std::vector<conflict_set>{
                                conflict_set{std::vector<std::pair<size_t, size_t>>{{0, 4}, {20, 24}}},
                                conflict_set{std::vector<std::pair<size_t, size_t>>{{4, 8}, {16, 20}}},
                                conflict_set{std::vector<std::pair<size_t, size_t>>{{8, 12}, {28, 32}}},
                                conflict_set{std::vector<std::pair<size_t, size_t>>{{12, 16}, {24, 28}}},
                                conflict_set{std::vector<std::pair<size_t, size_t>>{{32, 36}, {52, 56}}},
                                conflict_set{std::vector<std::pair<size_t, size_t>>{{36, 40}, {48, 52}}},
                                conflict_set{std::vector<std::pair<size_t, size_t>>{{40, 44}, {60, 64}}},
                                conflict_set{std::vector<std::pair<size_t, size_t>>{{44, 48}, {56, 60}}},
                            }});
}

bool memory_analysis_handler_t::handle(const message_t &message) {
  assert(message.data_item_size() == sizeof(uint64_t));
  if (message.wave_header().user_type != message_type::address) {
    if (verbose_) {
      printf("memory_analysis_handler: skipping message with user type 0x%x\n", message.wave_header().user_type);
    }
    return false;
  }

  uint8_t mspace = (message.wave_header().user_data >> 2) & 0xf;
  switch (mspace) {
  case address_space::flat:
    break;
  case address_space::global:
    return handle_cache_line_count_analysis(message);
    break;
  case address_space::gds:
    break;
  case address_space::shared:
    return handle_bank_conflict_analysis(message);
    break;
  case address_space::constant:
    break;
  case address_space::scratch:
    break;
  case address_space::undefined:
    break;
  default:
    break;
  }

  return false;
}

bool memory_analysis_handler_t::handle(const message_t &message, const std::string &kernel_name,
                                       kernelDB::kernelDB &kdb) {
  kdb_p = &kdb;
  this->kernel_name = kernel_name;

  auto result = handle(message);

  this->kernel_name = "";
  kdb_p = nullptr;
  return result;
}

std::string rw2str(uint8_t rw_kind, const std::map<uint8_t, const char *> &rw2str_map) {
  std::string rw_string;
  const auto &rw_s = rw2str_map.find(rw_kind);
  if (rw_s != rw2str_map.end()) {
    rw_string = rw_s->second;
  } else {
    rw_string = "[coding error: invalid encoding of memory operation type]";
  }
  return rw_string;
}

// Returns the size of the load/store for the ISA instruction associated with a source location.
// The source location comes from IR instrumentation, and may be e.g. for a load of an int (dword),
// so based on IR info, we would assume a size of 4 bytes for the load. However, the optimizer may
// have combined four adjacent dword loads into a single dwordx4 load (so 16 bytes). This function uses
// kernelDB to find the load/store size for the actual ISA instruction associated with the source
// location.
// If the pointer to kernelDB is zero, or if kernelDB finds an ISA instruction for the source location
// and we don't know the load/store size for that instruction (because it isn't in our table of known
// instructions), this function returns zero, signalling to the caller not to change the size of the
// load/store.
// If kernelDB doesn't find any instruction for the given source location, it will throw an exception.
// This function catches the exception and returns 0xffffff, signalling to the caller that no ISA instruction
// is associated with the source location; the caller will then drop the message.

struct dwarf_info_t {
  std::string fname;
  std::string isa_instruction;
  uint16_t access_size = 0;
};

dwarf_info_t
get_dwarf_info(const dh_comms::message_t &message, const std::string &kernel_name, kernelDB::kernelDB *kdb,
               const std::map<std::string, dh_comms::memory_analysis_handler_t::access_size_and_type> &instr_size_map,
               bool verbose) {
  dwarf_info_t dwarf_info;
  if (kdb == nullptr) {
    return dwarf_info;
  }
  auto hdr = message.wave_header();
  if (verbose) {
    printf("---\nFrom IR instrumentation: dwarf_fname_hash = 0x%lx, line = %u, column = %u\n", hdr.dwarf_fname_hash,
           hdr.dwarf_line, hdr.dwarf_column);
  }
  uint8_t rw_kind = message.wave_header().user_data & 0b11;
  std::string isa_instruction = "";
  try {
    auto instructions = kdb->getInstructionsForLine(kernel_name, hdr.dwarf_line);
    for (auto inst : instructions) {
      isa_instruction = inst.inst_;
      if (verbose) {
        printf("Checking %s...\n", isa_instruction.c_str());
      }
      auto kdb_dwarf_fname = kdb->getFileName(kernel_name, inst.path_id_);
      size_t kdb_dwarf_fname_hash = std::hash<std::string>{}(kdb_dwarf_fname);
      if (kdb_dwarf_fname_hash == hdr.dwarf_fname_hash and inst.line_ == hdr.dwarf_line and
          inst.column_ == hdr.dwarf_column) {
        if (verbose) {
          printf("\tsource location: %s:%u:%u\n", kdb_dwarf_fname.c_str(), inst.line_, inst.column_);
          printf("\tdwarf_fname_hash = 0x%lx\n", kdb_dwarf_fname_hash);
        }

        // we have a match between the instruction instrumented at the IR level and
        // an ISA instruction for the same file, line and column. Now lookup the
        // data access size for the ISA instruction
        const auto s2u = instr_size_map.find(isa_instruction);
        if (s2u != instr_size_map.end() and s2u->second.access_type == rw_kind) {
          dwarf_info.fname = kdb_dwarf_fname;
          dwarf_info.isa_instruction = isa_instruction;
          dwarf_info.access_size = s2u->second.size;
          return dwarf_info;
        }
      }
    }
  } catch (const std::exception &e) {
    // kernelDB didn't find any instructions for the source line number is the IR.
    // This can happen if e.g. 4 consecutive lines with an int (dword) load or store
    // are combined into a dwordx4 load or store. The line number in the dwarf will point
    // to the last line of the four with the individual instructions.
    // If we catch an exception, we'll assume that precisely this happened, and return all
    // ones. The caller than gets to decide what to do (e.g. just drop the message).
    dwarf_info.access_size = 0xffff;
    return dwarf_info;
  }

  //printf("Memory analysis handler: did not find %s in instr_size_map.\n", isa_instruction.c_str());
  return dwarf_info;
}

bool memory_analysis_handler_t::handle_cache_line_count_analysis(const message_t &message) {
  uint8_t L2_cache_line_size = L2_cache_line_sizes[message.wave_header().arch];
  if (L2_cache_line_size == 0) {
    if (verbose_) {
      printf("Memory analysis handler: message from unsupported GPU hardware, skipping.\n");
    }
    return false;
  }

  uint8_t rw_kind = message.wave_header().user_data & 0b11;
  uint16_t ir_data_size = (message.wave_header().user_data >> 6) & 0xffff;
  uint16_t data_size = ir_data_size;
  dwarf_info_t dwarf_info = get_dwarf_info(message, kernel_name, kdb_p, instr_size_map, verbose_);
  if (dwarf_info.access_size ==
      0xffff) { // no instruction found in ISA for source line in IR, may have been combined with other instructions.
    return true;
  }
  bool data_size_corrected = false;
  if (dwarf_info.access_size != 0 && dwarf_info.access_size != data_size) {
    if (verbose_) {
      printf("Corrected data size from %hu to %hu using DWARF information\n", data_size, dwarf_info.access_size);
    }
    data_size = dwarf_info.access_size;
    data_size_corrected = true;
  }
  size_t min_cache_lines_needed = (message.no_data_items() * data_size + L2_cache_line_size - 1) / L2_cache_line_size;
  std::set<uint64_t> cache_lines;
  for (size_t i = 0; i != message.no_data_items(); ++i) {
    // take into account that in odd cases, the memory access may stride more than a single cache line
    uint64_t first_byte_of_address = *(const uint64_t *)message.data_item(i);
    uint64_t last_byte_of_address = first_byte_of_address + data_size - 1;
    uint64_t first_cache_line_of_address = first_byte_of_address / L2_cache_line_size;
    uint64_t last_cache_line_of_address = last_byte_of_address / L2_cache_line_size;
    for (uint64_t cache_line = first_cache_line_of_address; cache_line <= last_cache_line_of_address; ++cache_line) {
      cache_lines.insert(cache_line);
    }
  }
  uint64_t cache_lines_used = cache_lines.size();

  // heuristic: if the data size changed from IR to ISA, we may get accesses that seem to
  // need one more cache line than needed. This happens for address messages emitted at the
  // instrumentation level that are combined into larger units at the ISA level. If we encounter
  // this, we drop the message. There may be pathetic memory access cases that are missed
  // by this heuristic.
  if (data_size_corrected and cache_lines_used == min_cache_lines_needed + 1) {
    return true;
  }

  if (verbose_ and (cache_lines_used != min_cache_lines_needed)) {
    std::string rw_string = rw2str(rw_kind, rw2str_map);
    printf("line %u: global memory access by %zu lanes:\n"
           "\t%s of %u bytes/lane, minimum L2 cache lines required %zu, cache lines used %zu\n"
           "\texecution mask = %s\n",
           message.wave_header().dwarf_line, message.no_data_items(), rw_string.c_str(), data_size,
           min_cache_lines_needed, cache_lines_used, exec2binstr(message.wave_header().exec).c_str());
    auto lane_ids_of_active_lanes = get_lane_ids_of_active_lanes(message.wave_header());
    printf("\n\tAddresses accessed (lane: address)");
    constexpr size_t addresses_per_line = 4;
    size_t addresses_printed = 0;
    for (size_t i = 0; i != lane_ids_of_active_lanes.size(); ++i) {
      if (addresses_printed % addresses_per_line == 0) {
        printf("\n\t");
      }
      ++addresses_printed;
      size_t lane = lane_ids_of_active_lanes[i];
      uint64_t address = *(const uint64_t *)message.data_item(i);
      printf("%2zu: 0x%lx   ", lane, address);
    }
    printf("\n\n\tCache line size = 0x%hhx. Lowest addresses on cache lines used:", L2_cache_line_size);
    addresses_printed = 0;
    for (const auto cl : cache_lines) {
      if (addresses_printed % addresses_per_line == 0) {
        printf("\n\t");
      }
      printf("%2zu: 0x%lx   ", addresses_printed, cl * L2_cache_line_size);
      ++addresses_printed;
    }
    printf("\n");
  }

  auto line = message.wave_header().dwarf_line;
  auto column = message.wave_header().dwarf_column;
  const auto &fname = dwarf_info.fname;
  auto &accesses = global_accesses[fname][line][column]; // reference to std::vector of global_accesses_t

  size_t no_accesses = 1;
  auto isa_access_size = dwarf_info.access_size;
  const auto &isa_instruction = dwarf_info.isa_instruction;
  global_accesses_t current_access{
      {no_accesses, ir_data_size, isa_access_size, rw_kind, isa_instruction}, min_cache_lines_needed, cache_lines_used};
  auto it = std::find_if(accesses.begin(), accesses.end(), [&current_access](const memory_accesses_t &access) {
    return access.ir_access_size == current_access.ir_access_size &&
           access.isa_access_size == current_access.isa_access_size && access.rw_kind == current_access.rw_kind;
  });

  if (it != accesses.end()) {
    ++(it->no_accesses);
    it->min_cache_lines_needed += min_cache_lines_needed;
    it->no_cache_lines_used += cache_lines_used;
  } else {
    accesses.push_back(current_access);
  }

  // kernelDB currently doesn't save info for ds_read and ds_write instructions,
  // so to be able to figure out the source file name for theses instructions,
  // we save a mapping while processing global loads and stores.
  fname_hash_to_fname[message.wave_header().dwarf_fname_hash] = fname;

  return true;
}

bool memory_analysis_handler_t::handle_bank_conflict_analysis(const message_t &message) {
  auto lane_ids_of_active_lanes = get_lane_ids_of_active_lanes(message.wave_header());
  assert(message.no_data_items() == lane_ids_of_active_lanes.size());
  uint8_t rw_kind = message.wave_header().user_data & 0b11;
  uint16_t data_size = (message.wave_header().user_data >> 6) & 0xffff;
  if (conflict_sets.find(data_size) == conflict_sets.end()) {
    printf("bank conflict handling of %u-byte accesses not supported\n", data_size);
    return false;
  }

  for (size_t i = 0; i != message.no_data_items(); ++i) {
    auto lane = lane_ids_of_active_lanes[i];
    uint64_t address = *(const uint64_t *)message.data_item(i);
    assert(address % data_size == 0); // we only handle naturally-aligned data
    for (auto &cs : conflict_sets[data_size]) {
      if (cs.register_access(lane, address)) {
        break;
      }
    }
  }

  size_t bank_conflict_count = 0;
  for (auto &cs : conflict_sets[data_size]) {
    bank_conflict_count += cs.bank_conflict_count();
    cs.clear();
  }

  if (verbose_) {
    std::string rw_string = rw2str(rw_kind, rw2str_map);
    printf("line %u: LDS access\n"
           "\t%s of %u bytes/lane, %zu bank conflicts\n"
           "\texecution mask = %s\n",
           message.wave_header().dwarf_line, rw_string.c_str(), data_size, bank_conflict_count,
           exec2binstr(message.wave_header().exec).c_str());
  }

  auto line = message.wave_header().dwarf_line;
  auto column = message.wave_header().dwarf_column;
  auto fname = fname_hash_to_fname[message.wave_header().dwarf_fname_hash];
  if (fname == "") {
    fname = "<unknown source file>";
  }
  auto &accesses = lds_accesses[fname][line][column]; // reference to std::vector of lds_accesses_t

  size_t no_accesses = 1;
  uint16_t isa_access_size = 0; // kernelDB currently doesn't handle LDS instructions yet.
  std::string isa_instruction = "";
  lds_accesses_t current_access{{no_accesses, data_size, isa_access_size, rw_kind, isa_instruction},
                                bank_conflict_count};
  auto it = std::find_if(accesses.begin(), accesses.end(), [&current_access](const memory_accesses_t &access) {
    return access.ir_access_size == current_access.ir_access_size &&
           access.isa_access_size == current_access.isa_access_size && access.rw_kind == current_access.rw_kind;
  });
  if (it != accesses.end()) {
    ++(it->no_accesses);
    it->no_bank_conflicts += bank_conflict_count;
  } else {
    accesses.push_back(current_access);
  }

  return true;
}

void show_line(const std::string &fname, uint16_t line, uint16_t column) {
  static std::string cached_fname;
  static std::vector<std::string> cached_lines;

  // If accessing a new file, clear the old cache and read new file
  if (fname != cached_fname) {
    cached_fname = fname;
    cached_lines.clear();

    std::ifstream file(fname);
    if (!file)
      return; // Return silently if file cannot be opened

    std::string line_content;
    while (std::getline(file, line_content)) {
      cached_lines.push_back(line_content);
    }
  }

  // Check if the requested line is out of bounds
  if (line == 0 || line > cached_lines.size())
    return;

  // Retrieve and process the requested line: replace each tab by 8 spaces
  std::string processed_line = cached_lines[line - 1];

  // Precompute required space
  size_t tab_count = std::count(processed_line.begin(), processed_line.end(), '\t');
  size_t final_size = processed_line.size() + tab_count * 7; // Each tab adds 7 extra spaces

  // Reserve space to prevent multiple reallocations
  processed_line.reserve(final_size);

  // Replace tabs
  size_t pos = 0;
  while ((pos = processed_line.find('\t', pos)) != std::string::npos) {
    processed_line.replace(pos, 1, "        "); // Replace '\t' with 8 spaces
    pos += 8;                                   // Move past the replacement
  }

  // Print the processed line
  printf("%s\n", processed_line.c_str());

  // Print the caret marker at the specified column (c-1 spaces + '^')
  if (column > 0) {
    printf("%*s^\n", column - 1, ""); // Print (column-1) spaces before caret
  }
}

void memory_analysis_handler_t::report_bank_conflicts() {
  printf("\n=== Bank conflicts report =========================\n");
  bool found_bank_conflict = false;
  for (const auto &[fname, line_col] : lds_accesses) {
    for (const auto &[line, col_accesses] : line_col) {
      for (const auto &[col, accesses] : col_accesses) {
        for (const auto &access : accesses) {
          if (not verbose_ and access.no_bank_conflicts == 0) {
            continue;
          }
          found_bank_conflict = true;
          printf("%s:%u:%u\n", fname.c_str(), line, col);
          show_line(fname, line, col);
          std::string rw_string = rw2str(access.rw_kind, rw2str_map);
          printf("\t%s of %u bytes at IR level\n", rw_string.c_str(), access.ir_access_size);
          printf("\texecuted %lu times, %lu bank conflicts in total\n", access.no_accesses, access.no_bank_conflicts);
        }
      }
    }
  }
  if (!found_bank_conflict) {
    printf("No bank conflicts found\n");
  }
  printf("=== End of bank conflicts report ====================\n");
}

void memory_analysis_handler_t::report_cache_line_use() {
  printf("\n=== L2 cache line use report ======================\n");
  bool found_excess = false;
  for (const auto &[fname, line_col] : global_accesses) {
    for (const auto &[line, col_accesses] : line_col) {
      for (const auto &[col, accesses] : col_accesses) {
        for (const auto &access : accesses) {
          if (not verbose_ and access.no_cache_lines_used == access.min_cache_lines_needed) {
            continue;
          }
          found_excess = true;
          printf("%s:%u:%u\n", fname.c_str(), line, col);
          show_line(fname, line, col);
          std::string rw_string = rw2str(access.rw_kind, rw2str_map);
          printf("\t%s of %u bytes at IR level (%u bytes at ISA level: \"%s\")\n", rw_string.c_str(),
                 access.ir_access_size, access.isa_access_size, access.isa_instruction.c_str());
          printf("\texecuted %lu times, %lu cache lines needed, %lu cache lines used\n", access.no_accesses,
                 access.min_cache_lines_needed, access.no_cache_lines_used);
        }
      }
    }
  }
  if (!found_excess) {
    printf("No excess cache lines used for global memory accesses\n");
  }
  printf("=== End of L2 cache line use report ===============\n");
}

void memory_analysis_handler_t::report(const std::string &kernel_name, kernelDB::kernelDB &kdb) {
  if (kernel_name.length() == 0) {
    std::vector<uint32_t> lines;
    kdb.getKernelLines(kernel_name, lines);
  }
  report();
}
void memory_analysis_handler_t::report() {
  report_cache_line_use();
  report_bank_conflicts();
}

void memory_analysis_handler_t::clear() {
  global_accesses.clear();
  lds_accesses.clear();
}
} // namespace dh_comms
