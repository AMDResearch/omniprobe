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

#include <cstdint>

#if defined(__HIPCC__) || defined(__HIP_DEVICE_COMPILE__) || defined(__HIP__)
#define OMNIPROBE_PROBE_ABI_HD __host__ __device__
#else
#define OMNIPROBE_PROBE_ABI_HD
#endif

namespace dh_comms {
struct dh_comms_descriptor;
struct builtin_snapshot_t;
}

namespace omniprobe::probe_abi_v1 {

enum class event_kind : uint16_t {
    kernel_entry = 1,
    kernel_exit = 2,
    memory_load = 3,
    memory_store = 4,
    call_before = 5,
    call_after = 6,
    basic_block = 7,
};

enum class emission_mode : uint8_t {
    auto_mode = 0,
    scalar = 1,
    vector = 2,
};

enum class helper_contract : uint16_t {
    kernel_lifecycle = 1,
    memory_op = 2,
    call = 3,
    basic_block = 4,
};

enum class message_kind : uint16_t {
    custom = 0,
    address = 1,
    time_interval = 2,
    wave_header = 3,
};

enum class memory_access_kind : uint8_t {
    unknown = 0,
    read = 1,
    write = 2,
    read_write = 3,
};

enum class address_space_kind : uint8_t {
    flat = 0,
    global = 1,
    gds = 2,
    shared = 3,
    constant = 4,
    scratch = 5,
    unknown = 0xff,
};

inline constexpr uint32_t runtime_ctx_abi_version = 2;

inline constexpr uint64_t dispatch_uniform_valid_dispatch_ptr = 1ull << 0;
inline constexpr uint64_t dispatch_uniform_valid_kernarg_segment_ptr = 1ull << 1;
inline constexpr uint64_t dispatch_uniform_valid_dispatch_id = 1ull << 2;
inline constexpr uint64_t dispatch_uniform_valid_grid_dim = 1ull << 3;
inline constexpr uint64_t dispatch_uniform_valid_block_dim = 1ull << 4;
inline constexpr uint64_t dispatch_uniform_valid_hidden_block_count = 1ull << 5;
inline constexpr uint64_t dispatch_uniform_valid_hidden_group_size = 1ull << 6;

struct entry_snapshot_v1 {
    uint32_t workgroup_x = 0;
    uint32_t workgroup_y = 0;
    uint32_t workgroup_z = 0;
    uint32_t thread_x = 0;
    uint32_t thread_y = 0;
    uint32_t thread_z = 0;
    uint32_t block_dim_x = 0;
    uint32_t block_dim_y = 0;
    uint32_t block_dim_z = 0;
    uint32_t lane_id = 0;
    uint32_t wave_id = 0;
    uint32_t wavefront_size = 0;
    uint32_t hw_id = 0;
    uint32_t reserved0 = 0;
    uint32_t reserved1 = 0;
    uint64_t exec_mask = 0;
    uint64_t timestamp = 0;
};

struct dispatch_uniform_snapshot_v1 {
    uint64_t valid_mask = 0;
    uint64_t dispatch_ptr = 0;
    uint64_t kernarg_segment_ptr = 0;
    uint64_t dispatch_id = 0;
    uint32_t grid_dim_x = 0;
    uint32_t grid_dim_y = 0;
    uint32_t grid_dim_z = 0;
    uint32_t block_dim_x = 0;
    uint32_t block_dim_y = 0;
    uint32_t block_dim_z = 0;
    uint32_t hidden_block_count_x = 0;
    uint32_t hidden_block_count_y = 0;
    uint32_t hidden_block_count_z = 0;
    uint32_t hidden_group_size_x = 0;
    uint32_t hidden_group_size_y = 0;
    uint32_t hidden_group_size_z = 0;
};

struct runtime_storage_v2 {
    dh_comms::dh_comms_descriptor *dh = nullptr;
    const void *config_blob = nullptr;
    void *state_blob = nullptr;
    uint64_t dispatch_id = 0;
    entry_snapshot_v1 entry_snapshot{};
    dispatch_uniform_snapshot_v1 dispatch_uniform{};
    const void *dispatch_private = nullptr;
    uint32_t abi_version = runtime_ctx_abi_version;
    uint32_t flags = 0;
};

struct runtime_ctx {
    dh_comms::dh_comms_descriptor *dh = nullptr;
    const void *config_blob = nullptr;
    void *state_blob = nullptr;
    uint64_t dispatch_id = 0;
    const void *raw_hidden_ctx = nullptr;
    const entry_snapshot_v1 *entry_snapshot = nullptr;
    const dispatch_uniform_snapshot_v1 *dispatch_uniform = nullptr;
    const dh_comms::builtin_snapshot_t *dh_builtins = nullptr;
    const void *dispatch_private = nullptr;
    uint32_t abi_version = runtime_ctx_abi_version;
    uint32_t flags = 0;
};

struct site_info {
    uint32_t probe_id = 0;
    event_kind event = event_kind::kernel_entry;
    helper_contract contract = helper_contract::kernel_lifecycle;
    emission_mode emission = emission_mode::auto_mode;
    message_kind message = message_kind::custom;
    uint8_t has_lane_headers = 0;
    uint8_t reserved0 = 0;
    uint16_t reserved1 = 0;
    uint32_t user_type = 0;
    uint32_t user_data = 0;
};

struct empty_captures {
};

template <typename CapturesT, typename EventT>
struct helper_args {
    const runtime_ctx *runtime = nullptr;
    const site_info *site = nullptr;
    const CapturesT *captures = nullptr;
    const EventT *event = nullptr;
};

struct kernel_lifecycle_event {
    uint64_t timestamp = 0;
    uint32_t workgroup_x = 0;
    uint32_t workgroup_y = 0;
    uint32_t workgroup_z = 0;
    uint32_t thread_x = 0;
    uint32_t thread_y = 0;
    uint32_t thread_z = 0;
    uint32_t block_dim_x = 0;
    uint32_t block_dim_y = 0;
    uint32_t block_dim_z = 0;
    uint32_t lane_id = 0;
    uint32_t wave_id = 0;
    uint32_t wavefront_size = 0;
    uint32_t hw_id = 0;
    uint64_t exec_mask = 0;
};

OMNIPROBE_PROBE_ABI_HD inline bool entry_snapshot_is_dispatch_origin(const entry_snapshot_v1 &snapshot) {
    return snapshot.workgroup_x == 0 && snapshot.workgroup_y == 0 &&
           snapshot.workgroup_z == 0 && snapshot.thread_x == 0 &&
           snapshot.thread_y == 0 && snapshot.thread_z == 0 &&
           snapshot.lane_id == 0 && snapshot.wave_id == 0;
}

OMNIPROBE_PROBE_ABI_HD inline bool lifecycle_event_is_dispatch_origin(const kernel_lifecycle_event &event) {
    return event.workgroup_x == 0 && event.workgroup_y == 0 &&
           event.workgroup_z == 0 && event.thread_x == 0 &&
           event.thread_y == 0 && event.thread_z == 0 &&
           event.lane_id == 0 && event.wave_id == 0;
}

struct memory_op_event {
    uint64_t address = 0;
    uint32_t bytes = 0;
    memory_access_kind access = memory_access_kind::unknown;
    address_space_kind address_space = address_space_kind::unknown;
};

struct call_event {
    uint64_t timestamp = 0;
    uint32_t callee_id = 0;
};

struct basic_block_event {
    uint64_t timestamp = 0;
    uint32_t block_id = 0;
};

} // namespace omniprobe::probe_abi_v1

#undef OMNIPROBE_PROBE_ABI_HD
