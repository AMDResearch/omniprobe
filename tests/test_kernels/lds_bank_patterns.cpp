// LDS access patterns with known bank behaviour, for comparing omniprobe's
// bank-conflict counts with the SQ_LDS_BANK_CONFLICT hardware counter
// (tests/test_lds_bank_conflicts.sh). One wave per block; each kernel does REPS
// pattern accesses per lane, reads or writes, 4- or 8-byte. The lane -> element
// maps are chosen so that 32-bank and 64-bank LDS, and 32-lane and 64-lane
// phases, predict different conflict counts; tests/lds_bank_check.py holds the
// same maps and computes the predictions.
//
// Built twice: with the AddressMessages plugin (omniprobe) and without (rocprofv3).

#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>

constexpr int REPS = 16;
constexpr int LDS_DWORDS = 8192; // 32 KiB
constexpr int BLOCKS = 240;

// Keeps every repetition a separate LDS instruction.
#define REPEAT_FENCE() __asm__ volatile("" ::: "memory")

#define PATTERN_KERNELS(T, NAME, EXPR)                                         \
  __global__ void read_##NAME(T *out) {                                        \
    __shared__ T s[LDS_DWORDS * 4 / sizeof(T)];                                \
    for (unsigned i = threadIdx.x; i < LDS_DWORDS * 4 / sizeof(T); i += 64)    \
      s[i] = (T)i;                                                             \
    __syncthreads();                                                           \
    unsigned l = threadIdx.x;                                                  \
    unsigned idx = (EXPR);                                                     \
    T acc = 0;                                                                 \
    for (int k = 0; k < REPS; ++k) {                                           \
      acc += s[idx];                                                           \
      REPEAT_FENCE();                                                          \
    }                                                                          \
    out[blockIdx.x * 64 + l] = acc;                                            \
  }                                                                            \
  __global__ void write_##NAME(T *out) {                                       \
    __shared__ T s[LDS_DWORDS * 4 / sizeof(T)];                                \
    unsigned l = threadIdx.x;                                                  \
    unsigned idx = (EXPR);                                                     \
    for (int k = 0; k < REPS; ++k) {                                           \
      s[idx] = (T)(k + l);                                                     \
      REPEAT_FENCE();                                                          \
    }                                                                          \
    __syncthreads();                                                           \
    out[blockIdx.x * 64 + l] = s[l];                                           \
  }

// 4-byte elements: element index == dword index
PATTERN_KERNELS(float, b32_stride1, l)
PATTERN_KERNELS(float, b32_stride2, 2 * l)
PATTERN_KERNELS(float, b32_split32, (l % 32) + 64 * (l / 32))
PATTERN_KERNELS(float, b32_stride32, 32 * l)
PATTERN_KERNELS(float, b32_stride64, 64 * l)
PATTERN_KERNELS(float, b32_pad33, 33 * l)
PATTERN_KERNELS(float, b32_bcast, 0u)
// 8-byte elements: element q covers dwords 2q and 2q+1
PATTERN_KERNELS(double, b64_stride1, l)
PATTERN_KERNELS(double, b64_stride2, 2 * l)
PATTERN_KERNELS(double, b64_split16, (l % 16) + 32 * (l / 16))
PATTERN_KERNELS(double, b64_split32, (l % 32) + 32 * (l / 32))
PATTERN_KERNELS(double, b64_stride16, 16 * l)
PATTERN_KERNELS(double, b64_pad17, 17 * l)
// 16-byte elements: element q covers dwords 4q..4q+3. b128_rwsplit puts the two
// 4-lane blocks of a 16-byte *write* phase (8 consecutive lanes) on the same
// banks and the two blocks of a *read* phase (e.g. lanes 0-3 and 20-23) on
// different banks: 8 extra passes per write, none per read.
typedef float f4 __attribute__((ext_vector_type(4)));
PATTERN_KERNELS(f4, b128_stride1, l)
PATTERN_KERNELS(f4, b128_stride8, 8 * l)
PATTERN_KERNELS(f4, b128_rwsplit, 8 * (l / 4) + 4 * ((l / 16) % 2) + (l % 4))

template <typename T> static void run(void (*k)(T *), const char *name) {
  T *d;
  if (hipMalloc(&d, BLOCKS * 64 * sizeof(T)) != hipSuccess) {
    fprintf(stderr, "hipMalloc failed\n");
    exit(1);
  }
  k<<<BLOCKS, 64>>>(d);
  if (hipDeviceSynchronize() != hipSuccess) {
    fprintf(stderr, "%s failed\n", name);
    exit(1);
  }
  (void)hipFree(d);
  printf("ran %s\n", name);
}

#define RUN(NAME)                                                              \
  run(read_##NAME, "read_" #NAME);                                             \
  run(write_##NAME, "write_" #NAME);

int main() {
  RUN(b32_stride1) RUN(b32_stride2) RUN(b32_split32) RUN(b32_stride32)
  RUN(b32_stride64) RUN(b32_pad33) RUN(b32_bcast)
  RUN(b64_stride1) RUN(b64_stride2) RUN(b64_split16) RUN(b64_split32)
  RUN(b64_stride16) RUN(b64_pad17)
  RUN(b128_stride1) RUN(b128_stride8) RUN(b128_rwsplit)
  return 0;
}
