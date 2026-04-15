#include "inc/utils.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

decltype(hsa_executable_symbol_get_info)* hsa_executable_symbol_get_info_fn = nullptr;

namespace {

bool verify_range_equal(const std::vector<unsigned char>& lhs,
                        size_t lhs_offset,
                        const std::vector<unsigned char>& rhs,
                        size_t rhs_offset,
                        size_t size,
                        const std::string& label) {
    if (lhs_offset + size > lhs.size() || rhs_offset + size > rhs.size()) {
        std::cerr << label << " range is out of bounds" << std::endl;
        return false;
    }
    if (std::memcmp(lhs.data() + lhs_offset, rhs.data() + rhs_offset, size) != 0) {
        std::cerr << label << " mismatch at offsets "
                  << lhs_offset << " / " << rhs_offset
                  << " size=" << size << std::endl;
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char* argv[]) {
    if (argc != 4 && argc != 5) {
        std::cerr << "usage: " << argv[0]
                  << " <source-hsaco> <clone-hsaco> <kernel-name> [clone-kernel-name]"
                  << std::endl;
        return 2;
    }

    const std::string source_hsaco = argv[1];
    const std::string clone_hsaco = argv[2];
    const std::string kernel_name = argv[3];
    const std::string clone_kernel_name =
        argc == 5 ? argv[4] : getHiddenAbiInstrumentedName(kernel_name);

    KernelArgHelper source_helper(source_hsaco);
    KernelArgHelper clone_helper(clone_hsaco);

    arg_descriptor_t source_desc = {};
    arg_descriptor_t clone_desc = {};
    if (!source_helper.getArgDescriptor(kernel_name, source_desc)) {
        std::cerr << "failed to load source descriptor for " << kernel_name << std::endl;
        return 1;
    }
    if (!clone_helper.getArgDescriptor(clone_kernel_name, clone_desc)) {
        std::cerr << "failed to load clone descriptor for " << clone_kernel_name << std::endl;
        return 1;
    }

    overlaySourceArgDescriptorLayout(clone_desc, source_desc);

    std::vector<unsigned char> src(source_desc.kernarg_length, 0);
    for (size_t i = 0; i < source_desc.explicit_args_length && i < src.size(); ++i) {
        src[i] = static_cast<unsigned char>((i * 17u + 3u) & 0xffu);
    }
    for (size_t i = 0; i < source_desc.hidden_args.size(); ++i) {
        const auto& arg = source_desc.hidden_args[i];
        const unsigned char pattern = static_cast<unsigned char>(0x40u + (i & 0x3fu));
        for (size_t j = 0; j < arg.size && arg.offset + j < src.size(); ++j) {
            src[arg.offset + j] = pattern;
        }
    }

    std::vector<unsigned char> dst(clone_desc.kernarg_length, 0);
    void* comms = reinterpret_cast<void*>(static_cast<uintptr_t>(0x12345678ABCDEF00ULL));
    repackInstrumentedKernArgs(dst.data(), src.data(), comms, clone_desc);

    if (!verify_range_equal(dst, 0, src, 0, source_desc.explicit_args_length, "explicit args")) {
        return 1;
    }

    for (const auto& source_hidden_arg : source_desc.hidden_args) {
        const auto* clone_hidden_arg = clone_desc.findHiddenArg(source_hidden_arg.value_kind);
        if (clone_hidden_arg == nullptr) {
            std::cerr << "clone is missing hidden arg " << source_hidden_arg.value_kind << std::endl;
            return 1;
        }
        const size_t copy_size = std::min(source_hidden_arg.size, clone_hidden_arg->size);
        if (!verify_range_equal(dst, clone_hidden_arg->offset, src, source_hidden_arg.offset,
                                copy_size, source_hidden_arg.value_kind)) {
            return 1;
        }
    }

    const auto* omniprobe_hidden_arg = clone_desc.findOmniprobeHiddenArg();
    if (omniprobe_hidden_arg == nullptr) {
        std::cerr << "clone descriptor does not contain hidden_omniprobe_ctx" << std::endl;
        return 1;
    }
    if (omniprobe_hidden_arg->offset + sizeof(void*) > dst.size()) {
        std::cerr << "hidden_omniprobe_ctx falls outside destination kernarg buffer" << std::endl;
        return 1;
    }

    void* observed_comms = nullptr;
    std::memcpy(&observed_comms, dst.data() + omniprobe_hidden_arg->offset, sizeof(void*));
    if (observed_comms != comms) {
        std::cerr << "hidden_omniprobe_ctx mismatch: expected " << comms
                  << " got " << observed_comms << std::endl;
        return 1;
    }

    std::cout << "PASS kernel=" << kernel_name
              << " clone=" << clone_kernel_name
              << " hidden_offset=" << omniprobe_hidden_arg->offset
              << " kernarg=" << clone_desc.kernarg_length
              << std::endl;
    return 0;
}
