// MIT License
//
// Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.
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

#include "inc/memory_analysis_handler.h"
#include "inc/kernel_dispatch.h"

#include "gpu_arch_constants.h"
#include "utils.h"
#include "inc/json_output.h"

#include <atomic>
#include <regex>
#include <cassert>
#include <set>
#include <string>
#include <sstream>
#include <ctime>
#include <iomanip>
#include <fstream>

namespace {
using lane_ranges_t = std::vector<std::pair<std::size_t, std::size_t>>;

// LDS geometry assumed by the bank-conflict analysis, per access class: the
// bank count (bank = dword index mod banks) and the groups of lanes served in
// the same cycle (see memory_analysis_handler.h). Measured with dh_comms
// tools/lds_bank_probe (one DS instruction, per-lane addresses, per-dispatch
// SQ_LDS_BANK_CONFLICT); suite 26 compares the resulting counts with the
// hardware counter. Classes are named after the instruction whose behaviour
// they describe:
//   narrow       reads and writes of 1, 2 or 4 bytes; each address of
//                ds_read2_b32/ds_write2_b32
//   read_b64, read_b96, read_b128, write_b64, write_b96, write_b128
//                also each address of ds_read2_b64/ds_write2_b64 (write_b64:
//                on gfx950 the read2 form is served like the b64 write)
//   read_b64_tr, read_b96_tr   gfx950 transpose loads
struct lds_phases_t {
  std::size_t banks;
  std::vector<lane_ranges_t> groups;
};
using lds_model_t = std::map<std::string, lds_phases_t>;

const lane_ranges_t lanes_0_31{{0, 32}}, lanes_32_63{{32, 64}};
std::vector<lane_ranges_t> consecutive_lanes(std::size_t n) {
  std::vector<lane_ranges_t> groups;
  for (std::size_t a = 0; a < 64; a += n)
    groups.push_back({{a, a + n}});
  return groups;
}
// {0..3,20..23}, {4..7,16..19}, {8..11,28..31}, {12..15,24..27}, and +32
const std::vector<lane_ranges_t> cdna_read_b128_groups{
    {{0, 4}, {20, 24}},   {{4, 8}, {16, 20}},   {{8, 12}, {28, 32}},  {{12, 16}, {24, 28}},
    {{32, 36}, {52, 56}}, {{36, 40}, {48, 52}}, {{40, 44}, {60, 64}}, {{44, 48}, {56, 60}}};

// Allocated once and never destroyed: the handler of the last dispatch can
// still be running on its own thread while exit() runs static destructors.
// Function-local statics would also race on first use, since this library is
// built with -fno-threadsafe-statics.
//
// CDNA1-3 (measured on gfx90a/MI210, 2026-11-09, every DS access class; the
// model reproduces SQ_LDS_BANK_CONFLICT for all 140257 measured aligned
// patterns): 32 banks for every access. Unlike gfx950, ds_read_b64 is served
// 16 consecutive lanes at a time and ds_read_b128 in the 8-lane groups of
// ds_read_b96. gfx908 and gfx942 are not measured; they use this model with
// the access class from the IR size.
const lds_model_t &cdna_lds = *new lds_model_t{
    {"narrow", {32, {lanes_0_31, lanes_32_63}}},
    {"read_b64", {32, consecutive_lanes(16)}},
    {"read_b96", {32, cdna_read_b128_groups}},
    {"read_b128", {32, cdna_read_b128_groups}},
    {"write_b64", {32, consecutive_lanes(16)}},
    {"write_b96", {32, consecutive_lanes(8)}},
    {"write_b128", {32, consecutive_lanes(8)}},
    // Atomics as on gfx950 (below).
    {"atomic_b32", {32, {lanes_0_31, lanes_32_63}}},
    {"atomic_b64", {32, consecutive_lanes(16)}},
    {"atomic_cmpst_b32", {16, consecutive_lanes(16)}},
    {"atomic_cmpst_b64", {16, consecutive_lanes(8)}},
};

// CDNA4 (measured on gfx950/MI350X, 2026-11-09, every DS access class; the
// model reproduces SQ_LDS_BANK_CONFLICT for all 109122 measured aligned
// patterns). The LDS behaves as 64 banks of 4 bytes for ds_read_b64,
// ds_read_b128 and the transpose loads, and as 32 banks (banks b and b+32 never
// both in one cycle) for every other access.
const lds_model_t &cdna4_lds = *new lds_model_t{
    {"narrow", {32, {lanes_0_31, lanes_32_63}}},
    {"read_b64", {64, {lanes_0_31, lanes_32_63}}},
    {"read_b96", {32, cdna_read_b128_groups}},
    {"read_b128",
     {64,
      {{{0, 4}, {12, 16}, {20, 28}},
       {{4, 12}, {16, 20}, {28, 32}},
       {{32, 36}, {44, 48}, {52, 60}},
       {{36, 44}, {48, 52}, {60, 64}}}}},
    {"write_b64", {32, consecutive_lanes(16)}},
    {"write_b96", {32, consecutive_lanes(8)}},
    {"write_b128", {32, consecutive_lanes(8)}},
    {"read_b64_tr", {64, {lanes_0_31, lanes_32_63}}},
    {"read_b96_tr", {64, consecutive_lanes(16)}},
    // Atomics serialize lanes even on one address (no broadcast).
    {"atomic_b32", {32, {lanes_0_31, lanes_32_63}}},
    {"atomic_b64", {32, consecutive_lanes(16)}},
    // compare-swap carries two data dwords per lane: behaves as 16 banks
    {"atomic_cmpst_b32", {16, consecutive_lanes(16)}},
    {"atomic_cmpst_b64", {16, consecutive_lanes(8)}},
};

const lds_model_t &lds_model(uint8_t arch) {
  return arch == dh_comms::gcnarch::gfx950 ? cdna4_lds : cdna_lds;
}

// Whether the access class of an LDS access is taken from the DS instruction
// kernelDB finds at its source location. Only where every class is measured
// (gfx90a, gfx950); elsewhere the class follows from the IR access size alone.
bool lds_classes_from_isa(uint8_t arch) {
  return arch == dh_comms::gcnarch::gfx90a || arch == dh_comms::gcnarch::gfx950;
}

// Class for an IR access of <bytes> without ISA information.
std::string lds_class_for_size(bool write, uint16_t bytes) {
  if (bytes <= 4)
    return "narrow";
  return std::string(write ? "write_b" : "read_b") + std::to_string(8 * bytes);
}

// What a DS instruction does to the banks: its class and the bytes behind each
// of its addresses. Returns false for instructions that are not LDS data
// accesses this analysis models (atomics are not instrumented).
// Class of a DS atomic, as measured on gfx950 with lds_bank_probe:
//   integer RMW and float min/max: atomic_b32 / atomic_b64 by width (f64
//     add/max too; min_f64 by analogy with min_f32, not measured)
//   ds_cmpst_b32, ds_mskor_b32 (two data dwords): atomic_cmpst_b32
//   ds_cmpst_b64: atomic_cmpst_b64
//   float add (add_f32, pk_add_f16, pk_add_bf16, with or without return):
//     atomic_float -- lanes are served one at a time (3 cycles per active
//     lane) and the hardware never counts that as a bank conflict.
const std::regex &ds_atomic = *new std::regex(
    R"(^ds_(add|sub|rsub|inc|dec|min|max|and|or|xor|wrxchg|cmpst|mskor|pk_add)(_rtn)?_(u32|i32|b32|f32|f16|bf16|u64|i64|b64|f64)$)");
bool lds_atomic_class(const std::string &mnemonic, std::string &cls, uint16_t &bytes) {
  std::smatch m;
  if (!std::regex_match(mnemonic, m, ds_atomic))
    return false;
  std::string op = m[1], type = m[3];
  bytes = type.back() == '4' ? 8 : 4;
  if (op == "pk_add" || (op == "add" && type == "f32"))
    cls = "atomic_float";
  else if (op == "cmpst" || op == "mskor")
    cls = bytes == 4 ? "atomic_cmpst_b32" : "atomic_cmpst_b64";
  else
    cls = bytes == 4 ? "atomic_b32" : "atomic_b64";
  return true;
}

// Never destroyed, like the models above.
const std::regex &ds_data_access =
    *new std::regex(R"(^ds_(read|write)(2st64|2)?_([biu])(8|16|32|64|96|128)(_tr_b[0-9]+)?(_d16(_hi)?)?$)");
bool lds_class_for_isa(const std::string &mnemonic, std::string &cls, uint16_t &bytes) {
  const std::regex &ds = ds_data_access;
  std::smatch m;
  if (!std::regex_match(mnemonic, m, ds))
    return false;
  bool write = m[1] == "write";
  bytes = std::stoi(m[4]) / 8;
  if (m[5].matched)
    cls = bytes == 12 ? "read_b96_tr" : "read_b64_tr";
  else if (bytes <= 4)
    cls = "narrow";
  else if (m[2].matched) // each address of read2/write2_b64 behaves like a b64 write
    cls = "write_b64";
  else
    cls = lds_class_for_size(write, bytes);
  return true;
}
} // namespace

namespace dh_comms {

// See memory_analysis_handler.h for an explanation of conflict sets.
conflict_set::conflict_set(const std::vector<std::pair<std::size_t, std::size_t>> &fl_pairs, std::size_t no_banks)
    : lanes(),
      banks(std::vector<std::set<uint64_t>>(no_banks)) {
  for (const auto &fl_pair : fl_pairs) {
    assert(fl_pair.first < fl_pair.second);
    for (std::size_t i = fl_pair.first; i != fl_pair.second; ++i) {
      lanes.insert(i);
    }
  }
}
bool conflict_set::register_access(size_t lane, uint64_t address, std::size_t bytes, bool per_lane) {
  if (lanes.find(lane) == lanes.end()) { // lane is not in this conflict set
    return false;
  }
  // Every dword the access touches; bytes of one dword never conflict, except
  // for atomics (per_lane), where every lane is served separately.
  for (uint64_t dword = address / sizeof(uint32_t); dword <= (address + bytes - 1) / sizeof(uint32_t); ++dword)
    banks[dword % banks.size()].insert(per_lane ? dword * 64 + lane : dword);
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

memory_analysis_handler_t::memory_analysis_handler_t(const std::string& kernel, uint64_t dispatch_id, const std::string& location,  bool verbose) : conflict_sets(), verbose_(verbose), kernel_(kernel), dispatch_id_(dispatch_id), kernel_dispatch_(kernelDispatchOrdinal(dispatch_id)), location_(location),
    rw2str_map{
          {dh_comms::memory_access::undefined, "unspecified memory operation"},
          {dh_comms::memory_access::read, "read"},
          {dh_comms::memory_access::write, "write"},
          {dh_comms::memory_access::read_write, "read/write"},
      },
      instr_size_map{
          {"global_load_ubyte", {1, memory_access::read}},      {"global_load_sbyte", {1, memory_access::read}},
          {"global_load_ubyte_d16", {1, memory_access::read}},  {"global_load_ubyte_d16_hi", {1, memory_access::read}},
          {"global_load_sbyte_d16", {1, memory_access::read}},  {"global_load_sbyte_d16_hi", {1, memory_access::read}},
          {"global_load_ushort", {2, memory_access::read}},     {"global_load_sshort", {2, memory_access::read}},
          {"global_load_short_d16", {2, memory_access::read}},  {"global_load_short_d16_hi", {2, memory_access::read}},
          {"global_load_dword", {4, memory_access::read}},      {"global_load_dwordx2", {8, memory_access::read}},
          {"global_load_dwordx3", {12, memory_access::read}},   {"global_load_dwordx4", {16, memory_access::read}},

          {"global_store_byte", {1, memory_access::write}},     {"global_store_byte_d16_hi", {1, memory_access::write}},
          {"global_store_short", {2, memory_access::write}},    {"global_store_short_d16_hi", {2, memory_access::write}},
          {"global_store_dword", {4, memory_access::write}},    {"global_store_dwordx2", {8, memory_access::write}},
          {"global_store_dwordx3", {12, memory_access::write}}, {"global_store_dwordx4", {16, memory_access::write}},

          // Flat accesses whose address space the plugin classified at run time.
          {"flat_load_ubyte", {1, memory_access::read}},        {"flat_load_sbyte", {1, memory_access::read}},
          {"flat_load_ubyte_d16", {1, memory_access::read}},    {"flat_load_ubyte_d16_hi", {1, memory_access::read}},
          {"flat_load_sbyte_d16", {1, memory_access::read}},    {"flat_load_sbyte_d16_hi", {1, memory_access::read}},
          {"flat_load_ushort", {2, memory_access::read}},       {"flat_load_sshort", {2, memory_access::read}},
          {"flat_load_short_d16", {2, memory_access::read}},    {"flat_load_short_d16_hi", {2, memory_access::read}},
          {"flat_load_dword", {4, memory_access::read}},        {"flat_load_dwordx2", {8, memory_access::read}},
          {"flat_load_dwordx3", {12, memory_access::read}},     {"flat_load_dwordx4", {16, memory_access::read}},

          {"flat_store_byte", {1, memory_access::write}},       {"flat_store_byte_d16_hi", {1, memory_access::write}},
          {"flat_store_short", {2, memory_access::write}},      {"flat_store_short_d16_hi", {2, memory_access::write}},
          {"flat_store_dword", {4, memory_access::write}},      {"flat_store_dwordx2", {8, memory_access::write}},
          {"flat_store_dwordx3", {12, memory_access::write}},   {"flat_store_dwordx4", {16, memory_access::write}},

          {"global_load_lds_ubyte", {1, memory_access::read}},  {"global_load_lds_sbyte", {1, memory_access::read}},
          {"global_load_lds_ushort", {2, memory_access::read}}, {"global_load_lds_sshort", {2, memory_access::read}},
          {"global_load_lds_dword", {4, memory_access::read}},

          {"buffer_load_ubyte", {1, memory_access::read}},      {"buffer_load_sbyte", {1, memory_access::read}},
          {"buffer_load_ubyte_d16", {1, memory_access::read}},  {"buffer_load_ubyte_d16_hi", {1, memory_access::read}},
          {"buffer_load_sbyte_d16", {1, memory_access::read}},  {"buffer_load_sbyte_d16_hi", {1, memory_access::read}},
          {"buffer_load_ushort", {2, memory_access::read}},     {"buffer_load_sshort", {2, memory_access::read}},
          {"buffer_load_short_d16", {2, memory_access::read}},  {"buffer_load_short_d16_hi", {2, memory_access::read}},
          {"buffer_load_dword", {4, memory_access::read}},      {"buffer_load_dwordx2", {8, memory_access::read}},
          {"buffer_load_dwordx3", {12, memory_access::read}},   {"buffer_load_dwordx4", {16, memory_access::read}},

          {"buffer_store_byte", {1, memory_access::write}},     {"buffer_store_byte_d16_hi", {1, memory_access::write}},
          {"buffer_store_short", {2, memory_access::write}},    {"buffer_store_short_d16_hi", {2, memory_access::write}},
          {"buffer_store_dword", {4, memory_access::write}},    {"buffer_store_dwordx2", {8, memory_access::write}},
          {"buffer_store_dwordx3", {12, memory_access::write}}, {"buffer_store_dwordx4", {16, memory_access::write}}
      }
{}

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
          {"global_load_ubyte", {1, memory_access::read}},      {"global_load_sbyte", {1, memory_access::read}},
          {"global_load_ubyte_d16", {1, memory_access::read}},  {"global_load_ubyte_d16_hi", {1, memory_access::read}},
          {"global_load_sbyte_d16", {1, memory_access::read}},  {"global_load_sbyte_d16_hi", {1, memory_access::read}},
          {"global_load_ushort", {2, memory_access::read}},     {"global_load_sshort", {2, memory_access::read}},
          {"global_load_short_d16", {2, memory_access::read}},  {"global_load_short_d16_hi", {2, memory_access::read}},
          {"global_load_dword", {4, memory_access::read}},      {"global_load_dwordx2", {8, memory_access::read}},
          {"global_load_dwordx3", {12, memory_access::read}},   {"global_load_dwordx4", {16, memory_access::read}},

          {"global_store_byte", {1, memory_access::write}},     {"global_store_byte_d16_hi", {1, memory_access::write}},
          {"global_store_short", {2, memory_access::write}},    {"global_store_short_d16_hi", {2, memory_access::write}},
          {"global_store_dword", {4, memory_access::write}},    {"global_store_dwordx2", {8, memory_access::write}},
          {"global_store_dwordx3", {12, memory_access::write}}, {"global_store_dwordx4", {16, memory_access::write}},

          // Flat accesses whose address space the plugin classified at run time.
          {"flat_load_ubyte", {1, memory_access::read}},        {"flat_load_sbyte", {1, memory_access::read}},
          {"flat_load_ubyte_d16", {1, memory_access::read}},    {"flat_load_ubyte_d16_hi", {1, memory_access::read}},
          {"flat_load_sbyte_d16", {1, memory_access::read}},    {"flat_load_sbyte_d16_hi", {1, memory_access::read}},
          {"flat_load_ushort", {2, memory_access::read}},       {"flat_load_sshort", {2, memory_access::read}},
          {"flat_load_short_d16", {2, memory_access::read}},    {"flat_load_short_d16_hi", {2, memory_access::read}},
          {"flat_load_dword", {4, memory_access::read}},        {"flat_load_dwordx2", {8, memory_access::read}},
          {"flat_load_dwordx3", {12, memory_access::read}},     {"flat_load_dwordx4", {16, memory_access::read}},

          {"flat_store_byte", {1, memory_access::write}},       {"flat_store_byte_d16_hi", {1, memory_access::write}},
          {"flat_store_short", {2, memory_access::write}},      {"flat_store_short_d16_hi", {2, memory_access::write}},
          {"flat_store_dword", {4, memory_access::write}},      {"flat_store_dwordx2", {8, memory_access::write}},
          {"flat_store_dwordx3", {12, memory_access::write}},   {"flat_store_dwordx4", {16, memory_access::write}},

          {"global_load_lds_ubyte", {1, memory_access::read}},  {"global_load_lds_sbyte", {1, memory_access::read}},
          {"global_load_lds_ushort", {2, memory_access::read}}, {"global_load_lds_sshort", {2, memory_access::read}},
          {"global_load_lds_dword", {4, memory_access::read}},

          {"buffer_load_ubyte", {1, memory_access::read}},      {"buffer_load_sbyte", {1, memory_access::read}},
          {"buffer_load_ubyte_d16", {1, memory_access::read}},  {"buffer_load_ubyte_d16_hi", {1, memory_access::read}},
          {"buffer_load_sbyte_d16", {1, memory_access::read}},  {"buffer_load_sbyte_d16_hi", {1, memory_access::read}},
          {"buffer_load_ushort", {2, memory_access::read}},     {"buffer_load_sshort", {2, memory_access::read}},
          {"buffer_load_short_d16", {2, memory_access::read}},  {"buffer_load_short_d16_hi", {2, memory_access::read}},
          {"buffer_load_dword", {4, memory_access::read}},      {"buffer_load_dwordx2", {8, memory_access::read}},
          {"buffer_load_dwordx3", {12, memory_access::read}},   {"buffer_load_dwordx4", {16, memory_access::read}},

          {"buffer_store_byte", {1, memory_access::write}},     {"buffer_store_byte_d16_hi", {1, memory_access::write}},
          {"buffer_store_short", {2, memory_access::write}},    {"buffer_store_short_d16_hi", {2, memory_access::write}},
          {"buffer_store_dword", {4, memory_access::write}},    {"buffer_store_dwordx2", {8, memory_access::write}},
          {"buffer_store_dwordx3", {12, memory_access::write}}, {"buffer_store_dwordx4", {16, memory_access::write}}
      }
{}

bool memory_analysis_handler_t::handle(const message_t &message) {
  if (message.wave_header().user_type != message_type::address) {
    // Once per process, not per message: a binary built with another
    // instrumentation plugin (BBStart, BBInterval) gives this analyzer nothing.
    static std::atomic<bool> warned{false};
    bool expected = false;
    if (warned.compare_exchange_strong(expected, true)) {
      fprintf(stderr, "omniprobe MemoryAnalysis: ignoring messages of type %u; MemoryAnalysis needs a binary instrumented with "
              "the AddressMessages plugin (libAMDGCNSubmitAddressMessages-*.so)\n", message.wave_header().user_type);
    }
    if (verbose_) {
      printf("memory_analysis_handler: skipping message with user type 0x%x\n", message.wave_header().user_type);
    }
    return false;
  }

  assert(message.data_item_size() == sizeof(uint64_t));

  uint8_t mspace = (message.wave_header().user_data >> 2) & 0xf;
  switch (mspace) {
  case address_space::flat:
    // A flat pointer's real address space is only known at run time; these
    // accesses are not analyzed. Counted so the report can say so.
    unanalyzed_flat_++;
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
  uint16_t ir_data_size = (message.wave_header().user_data >> 6) & 0xffff;
  dwarf_info_t first;
  bool have_first = false;
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
          printf("\tisa instruction = %s\n", isa_instruction.c_str());
        }

        // we have a match between the instruction instrumented at the IR level and
        // an ISA instruction for the same file, line and column. Now lookup the
        // data access size for the ISA instruction
        const auto s2u = instr_size_map.find(isa_instruction);
        if (s2u != instr_size_map.end() and s2u->second.access_type == rw_kind) {
          // Several instructions can share a source location (at -O0 the load of
          // the pointer variable sits at the same line and column as the access
          // through it). Prefer the one as wide as the IR access; otherwise the
          // first, which may be a wider, combined access.
          if (s2u->second.size == ir_data_size) {
            dwarf_info.fname = kdb_dwarf_fname;
            dwarf_info.isa_instruction = isa_instruction;
            dwarf_info.access_size = s2u->second.size;
            return dwarf_info;
          }
          if (!have_first) {
            have_first = true;
            first.fname = kdb_dwarf_fname;
            first.isa_instruction = isa_instruction;
            first.access_size = s2u->second.size;
          }
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

  if (have_first)
    return first;
  //printf("Memory analysis handler: did not find %s in instr_size_map.\n", isa_instruction.c_str());
  return dwarf_info;
}

bool memory_analysis_handler_t::handle_cache_line_count_analysis(const message_t &message) {
  uint8_t arch = message.wave_header().arch;
  uint8_t L2_cache_line_size = gpu_arch_constants::get_l2_cache_line_size(arch);
  if (L2_cache_line_size == 0) {
    if (verbose_) {
      printf("Memory analysis handler: message from unsupported GPU hardware, skipping.\n");
    }
    return false;
  }
  if (observed_arch_ == 0) {
    observed_arch_ = arch;
  }

  uint8_t rw_kind = message.wave_header().user_data & 0b11;
  uint16_t ir_data_size = (message.wave_header().user_data >> 6) & 0xffff;
  uint16_t data_size = ir_data_size;
  dwarf_info_t dwarf_info = get_dwarf_info(message, kernel_name_, kdb_p_, instr_size_map, verbose_);
  if (dwarf_info.access_size ==
      0xffff) { // no instruction found in ISA for source line in IR, may have been combined with other instructions.
    if (verbose_) {
      printf("No instruction found in ISA for source line in IR, may have been combined with other instructions.\n");
    }
    // Dropped, but counted: without debug info (-g) this is every message,
    // and the report would otherwise just look empty.
    unattributed_++;
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
  // No exact file/line/column match in the ISA (e.g. the column moved): the
  // access is still counted at the location the plugin recorded, so take the
  // file from its hash instead of leaving it empty.
  if (dwarf_info.fname.empty()) {
    dwarf_info.fname = sourceFileForHash(message.wave_header().dwarf_fname_hash);
    if (dwarf_info.fname.rfind("<unresolved", 0) == 0 || dwarf_info.fname == "<unknown>")
      dwarf_info.fname = "<unknown source file>";
  }
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

// The DS instruction at the source location of an LDS access, from kernelDB:
// same file, line and column, same direction. Prefers one whose bytes per
// address equal the IR access size. Empty if there is none (or no kernelDB).
// flat is set if a flat_* instruction is at that location: a flat access that
// reached LDS (classified at run time, e.g. at -O0) has no DS instruction.
// wave_reduced is set if a v_mbcnt_* is there: the compiler's atomic optimizer
// turned an atomic on a uniform address into one lane's atomic on the wave's
// combined value, while the IR-level instrumentation still reports every lane.
static std::string lds_isa_instruction(const message_t &message, const std::string &kernel_name,
                                       kernelDB::kernelDB *kdb, bool write, bool atomic, uint16_t ir_size,
                                       bool &flat, bool &wave_reduced) {
  flat = false;
  wave_reduced = false;
  if (kdb == nullptr)
    return "";
  auto hdr = message.wave_header();
  std::string first;
  try {
    for (const auto &inst : kdb->getInstructionsForLine(kernel_name, hdr.dwarf_line)) {
      std::string cls;
      uint16_t bytes;
      if (inst.column_ != hdr.dwarf_column ||
          std::hash<std::string>{}(kdb->getFileName(kernel_name, inst.path_id_)) != hdr.dwarf_fname_hash)
        continue;
      if (inst.inst_.rfind("flat_", 0) == 0)
        flat = true;
      if (inst.inst_.rfind("v_mbcnt_", 0) == 0)
        wave_reduced = true;
      if (atomic ? !lds_atomic_class(inst.inst_, cls, bytes)
                 : (!lds_class_for_isa(inst.inst_, cls, bytes) || (inst.inst_.rfind("ds_write", 0) == 0) != write))
        continue;
      if (bytes == ir_size)
        return inst.inst_;
      if (first.empty())
        first = inst.inst_;
    }
  } catch (const std::exception &) {
    // no instructions for this line
  }
  return first;
}

bool memory_analysis_handler_t::handle_bank_conflict_analysis(const message_t &message) {
  auto lane_ids_of_active_lanes = get_lane_ids_of_active_lanes(message.wave_header());
  assert(message.no_data_items() == lane_ids_of_active_lanes.size());
  uint8_t rw_kind = message.wave_header().user_data & 0b11;
  uint16_t data_size = (message.wave_header().user_data >> 6) & 0xffff;
  uint8_t arch = message.wave_header().arch;
  bool write = rw_kind == memory_access::write;

  // Access class: from the DS instruction where it is known and the model
  // covers every class, else from the IR size. The instruction can differ from
  // the IR access: a wide IR access may be split into the two addresses of a
  // read2/write2 (pieces of isa_size bytes, each an access of the class), and
  // several IR accesses may be merged into one wider instruction (then only
  // the IR access at the start of the instruction's data counts it, so a
  // merged instruction is counted once).
  bool atomic = rw_kind == memory_access::read_write;
  bool flat = false, wave_reduced = false;
  std::string isa_instruction =
      lds_isa_instruction(message, kernel_name_, kdb_p_, write, atomic, data_size, flat, wave_reduced);
  wave_reduced = wave_reduced && atomic;
  // Atomics are modelled only from their instruction, where it is measured.
  if (atomic && (!lds_classes_from_isa(arch) || isa_instruction.empty()))
    return true;
  std::string cls = lds_class_for_size(write, data_size);
  uint16_t isa_size = 0;
  if (!isa_instruction.empty()) {
    std::string isa_cls;
    if (atomic)
      lds_atomic_class(isa_instruction, isa_cls, isa_size);
    else
      lds_class_for_isa(isa_instruction, isa_cls, isa_size);
    if (lds_classes_from_isa(arch))
      cls = isa_cls;
  }
  // Float atomics are served lane by lane: not bank conflicts, but reported
  // as serialized lanes.
  size_t serialized_lanes = cls == "atomic_float" ? (wave_reduced ? 1 : message.no_data_items()) : 0;
  uint16_t piece = data_size;
  if (lds_classes_from_isa(arch) && isa_size != 0)
    piece = isa_size;
  // With line info but no DS (or flat) instruction at this location, the
  // access was merged into an instruction that carries another access's
  // location (two loads on lines 11 and 12 become one ds_read_b64 at line 11);
  // that access counts the instruction. Recorded with no conflicts. Flat
  // accesses to LDS keep the size-based class (not measured per instruction).
  bool merged_away = lds_classes_from_isa(arch) && kdb_p_ != nullptr && message.wave_header().dwarf_line != 0 &&
                     isa_instruction.empty() && !flat;
  if (merged_away)
    ++merged_lds_;

  const lds_model_t &model = lds_model(arch);
  auto phases = model.find(cls == "atomic_float" ? "narrow" : cls);
  if (phases == model.end()) {
    printf("bank conflict handling of %u-byte LDS %s (%s) not supported on this architecture\n", data_size,
           write ? "writes" : "reads", isa_instruction.empty() ? "no ISA match" : isa_instruction.c_str());
    return false;
  }
  auto arch_sets = conflict_sets.find({arch, cls});
  if (arch_sets == conflict_sets.end()) {
    std::vector<conflict_set> sets;
    for (const auto &lanes : phases->second.groups)
      sets.emplace_back(lanes, phases->second.banks);
    arch_sets = conflict_sets.emplace(std::make_pair(arch, cls), std::move(sets)).first;
  }
  auto &sets = arch_sets->second;

  size_t bank_conflict_count = 0;
  bool merged_tail = piece > data_size && message.no_data_items() != 0 &&
                     *(const uint64_t *)message.data_item(0) % piece != 0;
  if (!merged_tail && !merged_away && !wave_reduced && cls != "atomic_float") {
    // One pass over the lanes per piece; a merged access covers the
    // instruction's whole data.
    uint16_t pieces = piece < data_size ? data_size / piece : 1;
    for (uint16_t p = 0; p != pieces; ++p) {
      for (size_t i = 0; i != message.no_data_items(); ++i) {
        auto lane = lane_ids_of_active_lanes[i];
        uint64_t address = *(const uint64_t *)message.data_item(i) + p * piece;
        for (auto &cs : sets) {
          if (cs.register_access(lane, address, piece, atomic)) {
            break;
          }
        }
      }
      for (auto &cs : sets) {
        bank_conflict_count += cs.bank_conflict_count();
        cs.clear();
      }
    }
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
  // File name for the hash: from global accesses already seen in this
  // dispatch, else from kernelDB's file names for the kernel. The map alone
  // depended on message order: LDS messages handled before the first global
  // access from the same file got "<unknown source file>", splitting one
  // source location into two entries.
  auto hash = message.wave_header().dwarf_fname_hash;
  std::string fname;
  auto known = fname_hash_to_fname.find(hash);
  if (known != fname_hash_to_fname.end()) {
    fname = known->second;
  } else {
    fname = sourceFileForHash(hash);
    if (fname.empty() || fname.rfind("<unresolved", 0) == 0 || fname == "<unknown>")
      fname = "<unknown source file>";
    else
      fname_hash_to_fname[hash] = fname;
  }
  auto &accesses = lds_accesses[fname][line][column]; // reference to std::vector of lds_accesses_t

  size_t no_accesses = 1;
  uint16_t isa_access_size = isa_size;
  lds_accesses_t current_access{{no_accesses, data_size, isa_access_size, rw_kind, isa_instruction},
                                bank_conflict_count, serialized_lanes};
  auto it = std::find_if(accesses.begin(), accesses.end(), [&current_access](const memory_accesses_t &access) {
    return access.ir_access_size == current_access.ir_access_size &&
           access.isa_access_size == current_access.isa_access_size && access.rw_kind == current_access.rw_kind;
  });
  if (it != accesses.end()) {
    ++(it->no_accesses);
    it->no_bank_conflicts += bank_conflict_count;
    it->no_serialized_lanes += serialized_lanes;
  } else {
    accesses.push_back(current_access);
  }

  return true;
}

// The last source file read by show_line and by getCodeContext. Allocated once
// and never destroyed, like cdna_lds: the last dispatch can report on
// comms_runner while exit() runs exit handlers. As function-local statics,
// whose destructors exit() runs, rocBLAS GEMM under MemoryAnalysis aborted in
// show_line at exit in most runs (bf_report-during-exit).
struct source_cache_t {
  std::string fname;
  std::vector<std::string> lines;
};
static source_cache_t &show_line_cache = *new source_cache_t;
static source_cache_t &code_context_cache = *new source_cache_t;

void show_line(const std::string &fname, uint16_t line, uint16_t column) {
  std::string &cached_fname = show_line_cache.fname;
  std::vector<std::string> &cached_lines = show_line_cache.lines;

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

void memory_analysis_handler_t::setupLogger()
{
    if (location_ == "console")
        log_file_ = &std::cout;
    else
        log_file_ = new std::ofstream(location_, std::ios::app);
}


void memory_analysis_handler_t::report() {
  setupLogger();

  // Check log format
  bool bFormatJson = false;
  const char* logDurLogFormat = std::getenv("LOGDUR_LOG_FORMAT");
  if (logDurLogFormat) {
    std::string strFormat = logDurLogFormat;
    if (strFormat == "json") {
      bFormatJson = true;
    }
  }

  // Flat accesses are typical of -O0 builds and of pointers loaded from
  // memory; without this line such a kernel just looks access-free.
  if (unanalyzed_flat_)
    fprintf(stderr, "omniprobe MemoryAnalysis: %s dispatch %lu: %lu flat-address access(es) not analyzed "
            "(address space unknown at compile time; typical of -O0 builds and of pointers loaded from memory)\n",
            kernel_.c_str(), (unsigned long)dispatch_id_, (unsigned long)unanalyzed_flat_);

  if (unattributed_)
    fprintf(stderr, "omniprobe MemoryAnalysis: %s dispatch %lu: %lu access(es) not analyzed: no ISA instruction "
            "found for their source line (no debug info? compile with -g)\n",
            kernel_.c_str(), (unsigned long)dispatch_id_, (unsigned long)unattributed_);

  if (bFormatJson) {
    report_json();
  } else {
    report_cache_line_use();
    report_bank_conflicts();
  }
}

void memory_analysis_handler_t::clear() {
  global_accesses.clear();
  lds_accesses.clear();
}

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

template <typename T>
void renderJSON(std::vector<std::pair<std::string, T>>& fields, std::iostream& out, bool omitFinalComma, bool valueAsString)
{
    if (valueAsString) {
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

// Function to get code context line for JSON output
std::string getCodeContext(const std::string &fname, uint16_t line) {
  std::string &cached_fname = code_context_cache.fname;
  std::vector<std::string> &cached_lines = code_context_cache.lines;

  // If accessing a new file, clear the old cache and read new file
  if (fname != cached_fname) {
    cached_fname = fname;
    cached_lines.clear();

    std::ifstream file(fname);
    if (!file) {
      return ""; // Return empty if file cannot be opened
    }

    std::string line_content;
    while (std::getline(file, line_content)) {
      cached_lines.push_back(line_content);
    }
  }

  // Check if the requested line is out of bounds
  if (line == 0 || line > cached_lines.size()) {
    return "";
  }

  // Retrieve and process the requested line: replace each tab by 8 spaces
  std::string processed_line = cached_lines[line - 1];

  // Replace tabs with spaces
  size_t pos = 0;
  while ((pos = processed_line.find('\t', pos)) != std::string::npos) {
    processed_line.replace(pos, 1, "        "); // Replace '\t' with 8 spaces
    pos += 8;
  }

  // Trim leading and trailing whitespace
  size_t start = processed_line.find_first_not_of(" ");
  if (start == std::string::npos) {
    return "";
  }
  size_t end = processed_line.find_last_not_of(" ");
  return processed_line.substr(start, end - start + 1);
}

// Escape a string for use as a JSON string value.
// Handles backslash, double-quote, and control characters.
static std::string json_escape(const std::string &s) {
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

void memory_analysis_handler_t::report_json() {
  std::stringstream json_output;

  if (location_ != "console") {
    json_output << json_array_separator(location_);
  } else if (dispatch_id_ > 1) {
    json_output << ",\n";
  }

  json_output << "{\n";
  json_output << "  \"kernel\": \"" << json_escape(kernel_) << "\",\n";
  json_output << "  \"dispatch_id\": " << dispatch_id_ << ",\n";
  json_output << "  \"kernel_dispatch\": " << kernel_dispatch_ << ",\n";

  // Flat accesses array combining cache line and bank conflict data per source location
  json_output << "  \"accesses\": [\n";

  bool first_access = true;

  // Emit global memory accesses (cache line analysis)
  for (const auto &[fname, line_col] : global_accesses) {
    for (const auto &[line, col_accesses] : line_col) {
      for (const auto &[col, accesses] : col_accesses) {
        for (const auto &access : accesses) {
          if (!first_access) {
            json_output << ",\n";
          }
          first_access = false;

          size_t excess = (access.no_cache_lines_used > access.min_cache_lines_needed)
                              ? (access.no_cache_lines_used - access.min_cache_lines_needed)
                              : 0;

          json_output << "    {\n";
          json_output << "      \"source_file\": \"" << json_escape(fname) << "\",\n";
          json_output << "      \"line\": " << line << ",\n";
          json_output << "      \"column\": " << col << ",\n";
          json_output << "      \"memory_space\": \"global\",\n";
          json_output << "      \"access_type\": \"" << rw2str(access.rw_kind, rw2str_map) << "\",\n";
          json_output << "      \"execution_count\": " << access.no_accesses << ",\n";
          json_output << "      \"ir_bytes\": " << access.ir_access_size << ",\n";
          json_output << "      \"isa_bytes\": " << access.isa_access_size << ",\n";
          json_output << "      \"isa_instruction\": \"" << json_escape(access.isa_instruction) << "\",\n";
          json_output << "      \"cache_lines_needed\": " << access.min_cache_lines_needed << ",\n";
          json_output << "      \"cache_lines_used\": " << access.no_cache_lines_used << ",\n";
          json_output << "      \"excess_cache_lines\": " << excess << ",\n";
          json_output << "      \"bank_conflicts\": 0\n";
          json_output << "    }";
        }
      }
    }
  }

  // Emit LDS accesses (bank conflict analysis)
  for (const auto &[fname, line_col] : lds_accesses) {
    for (const auto &[line, col_accesses] : line_col) {
      for (const auto &[col, accesses] : col_accesses) {
        for (const auto &access : accesses) {
          if (!first_access) {
            json_output << ",\n";
          }
          first_access = false;

          json_output << "    {\n";
          json_output << "      \"source_file\": \"" << json_escape(fname) << "\",\n";
          json_output << "      \"line\": " << line << ",\n";
          json_output << "      \"column\": " << col << ",\n";
          json_output << "      \"memory_space\": \"lds\",\n";
          json_output << "      \"access_type\": \"" << rw2str(access.rw_kind, rw2str_map) << "\",\n";
          json_output << "      \"execution_count\": " << access.no_accesses << ",\n";
          json_output << "      \"ir_bytes\": " << access.ir_access_size << ",\n";
          json_output << "      \"isa_bytes\": " << access.isa_access_size << ",\n";
          json_output << "      \"isa_instruction\": \"" << json_escape(access.isa_instruction) << "\",\n";
          json_output << "      \"excess_cache_lines\": 0,\n";
          json_output << "      \"bank_conflicts\": " << access.no_bank_conflicts << ",\n";
          json_output << "      \"serialized_lanes\": " << access.no_serialized_lanes << "\n";
          json_output << "    }";
        }
      }
    }
  }

  json_output << "\n  ],\n";
  json_output << "  \"unanalyzed_flat_accesses\": " << unanalyzed_flat_ << ",\n";
  json_output << "  \"unattributed_accesses\": " << unattributed_ << ",\n";
  json_output << "  \"merged_lds_accesses\": " << merged_lds_ << ",\n";

  // Metadata section
  json_output << "  \"metadata\": {\n";

  std::string version = "null"; // Default
  std::ifstream version_file("VERSION");
  if (version_file.good()) {
    std::string version_from_file;
    std::getline(version_file, version_from_file);
    if (!version_from_file.empty()) {
      // Trim whitespace and newline
      size_t first = version_from_file.find_first_not_of(" \t\n\r");
      if (std::string::npos != first) {
        size_t last = version_from_file.find_last_not_of(" \t\n\r");
        version = version_from_file.substr(first, (last - first + 1));
      }
    }
  }

  json_output << "    \"version\": \"" << version << "\",\n";

  // Add timestamp
  auto now = std::time(nullptr);
  auto tm = *std::localtime(&now);
  json_output << "    \"timestamp\": \"" << std::put_time(&tm, "%Y-%m-%d %H:%M:%S") << "\",\n";

  std::string arch = gpu_arch_constants::arch_enum_to_string(observed_arch_);
  int cache_line_size = gpu_arch_constants::get_l2_cache_line_size(observed_arch_);
  if (cache_line_size == 0) {
    cache_line_size = 128; // fallback to default
  }

  json_output << "    \"gpu_info\": {\n";
  json_output << "      \"architecture\": \"" << arch << "\",\n";
  json_output << "      \"cache_line_size\": " << cache_line_size << "\n";
  json_output << "    }\n";
  json_output << "  }\n";
  json_output << "}";

  // Add newline for console output (for readability)
  if (location_ == "console") {
    json_output << "\n";
  }

  // Write to the log file
  *log_file_ << json_output.str();

  if (location_ != "console")
  {
      delete log_file_;
      log_file_ = nullptr;
  }
}

} // namespace dh_comms
