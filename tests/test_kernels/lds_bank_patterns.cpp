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

// Classes added 2026-11-09 (gfx950 model per DS instruction):
// 1- and 2-byte: bytes of one dword never conflict (b8_dword4: four lanes per
// dword, eight dwords on one bank per half-wave).
PATTERN_KERNELS(unsigned char, b8_stride1, l)
PATTERN_KERNELS(unsigned char, b8_stride128, 128 * l)
PATTERN_KERNELS(unsigned char, b8_dword4, (l % 4) + 128 * (l / 4))
PATTERN_KERNELS(unsigned short, b16_stride64, 64 * l)
// 12-byte: ds_read_b96/ds_write_b96 (a 3-vector occupies a 16-byte slot)
typedef float f3 __attribute__((ext_vector_type(3)));
PATTERN_KERNELS(f3, b96_stride1, l)
PATTERN_KERNELS(f3, b96_stride8, 8 * l)
PATTERN_KERNELS(f3, b96_rwsplit, 8 * (l / 4) + 4 * ((l / 16) % 2) + (l % 4))
// Under-aligned wide elements, placed at an odd dword (8 bytes) or an odd
// 8-byte unit (16 bytes) of a float array, so the compiler must split them:
// 8 bytes at 4-byte alignment -> ds_read2_b32/ds_write2_b32, 16 bytes at
// 8-byte alignment -> ds_read2_b64/ds_write2_b64. Element q starts at float
// index (sizeof(T)/4) q + OFF.
#define UNALIGNED_KERNELS(T, NAME, OFF, EXPR)                                  \
  __global__ void read_##NAME(T *out) {                                        \
    __shared__ float s[LDS_DWORDS];                                            \
    for (unsigned i = threadIdx.x; i < LDS_DWORDS; i += 64)                    \
      s[i] = (float)i;                                                         \
    __syncthreads();                                                           \
    unsigned l = threadIdx.x;                                                  \
    unsigned idx = (sizeof(T) / 4) * (EXPR) + OFF;                             \
    T acc = 0;                                                                 \
    for (int k = 0; k < REPS; ++k) {                                           \
      acc += *(T *)&s[idx];                                                    \
      REPEAT_FENCE();                                                          \
    }                                                                          \
    out[blockIdx.x * 64 + l] = acc;                                            \
  }                                                                            \
  __global__ void write_##NAME(T *out) {                                       \
    __shared__ float s[LDS_DWORDS];                                            \
    unsigned l = threadIdx.x;                                                  \
    unsigned idx = (sizeof(T) / 4) * (EXPR) + OFF;                             \
    for (int k = 0; k < REPS; ++k) {                                           \
      *(T *)&s[idx] = (T)(k + l);                                              \
      REPEAT_FENCE();                                                          \
    }                                                                          \
    __syncthreads();                                                           \
    out[blockIdx.x * 64 + l] = (T)s[l];                                        \
  }
typedef double d_a4 __attribute__((aligned(4)));
UNALIGNED_KERNELS(d_a4, r2b32_stride1, 1, l)
UNALIGNED_KERNELS(d_a4, r2b32_stride16, 1, 16 * l)
typedef f4 f4_a8 __attribute__((aligned(8)));
UNALIGNED_KERNELS(f4_a8, r2b64_stride1, 2, l)
UNALIGNED_KERNELS(f4_a8, r2b64_stride8, 2, 8 * l)

// Two adjacent 4-byte accesses per lane, which the compiler may merge into one
// 8-byte instruction: element pair (2 idx, 2 idx + 1).
#define PAIR_KERNELS(NAME, EXPR)                                               \
  __global__ void read_##NAME(float *out) {                                    \
    __shared__ float s[LDS_DWORDS];                                            \
    for (unsigned i = threadIdx.x; i < LDS_DWORDS; i += 64)                    \
      s[i] = (float)i;                                                         \
    __syncthreads();                                                           \
    unsigned l = threadIdx.x;                                                  \
    unsigned idx = 2 * (EXPR);                                                 \
    float acc = 0;                                                             \
    for (int k = 0; k < REPS; ++k) {                                           \
      acc += s[idx] * s[idx + 1];                                              \
      REPEAT_FENCE();                                                          \
    }                                                                          \
    out[blockIdx.x * 64 + l] = acc;                                            \
  }                                                                            \
  __global__ void write_##NAME(float *out) {                                   \
    __shared__ float s[LDS_DWORDS];                                            \
    unsigned l = threadIdx.x;                                                  \
    unsigned idx = 2 * (EXPR);                                                 \
    for (int k = 0; k < REPS; ++k) {                                           \
      s[idx] = (float)(k + l);                                                 \
      s[idx + 1] = (float)(k - l);                                             \
      REPEAT_FENCE();                                                          \
    }                                                                          \
    __syncthreads();                                                           \
    out[blockIdx.x * 64 + l] = s[l];                                           \
  }
PAIR_KERNELS(pair_stride1, l)
PAIR_KERNELS(pair_stride16, 16 * l)

// The same as pair_*, but written out (not through a macro) with the two
// accesses on separate lines: the merged instruction carries only the first
// line, and the access on the second line must not be counted again.
template <unsigned STRIDE> __device__ inline void read_pairlines(float *out) {
  __shared__ float s[LDS_DWORDS];
  for (unsigned i = threadIdx.x; i < LDS_DWORDS; i += 64)
    s[i] = (float)i;
  __syncthreads();
  unsigned idx = 2 * STRIDE * threadIdx.x;
  float acc = 0;
  for (int k = 0; k < REPS; ++k) {
    float a = s[idx];
    float b = s[idx + 1];
    acc += a * b;
    REPEAT_FENCE();
  }
  out[blockIdx.x * 64 + threadIdx.x] = acc;
}
template <unsigned STRIDE> __device__ inline void write_pairlines(float *out) {
  __shared__ float s[LDS_DWORDS];
  unsigned idx = 2 * STRIDE * threadIdx.x;
  for (int k = 0; k < REPS; ++k) {
    s[idx] = (float)(k + threadIdx.x);
    s[idx + 1] = (float)(k - threadIdx.x);
    REPEAT_FENCE();
  }
  __syncthreads();
  out[blockIdx.x * 64 + threadIdx.x] = s[threadIdx.x];
}
__global__ void read_pairlines_stride1(float *out) { read_pairlines<1>(out); }
__global__ void write_pairlines_stride1(float *out) { write_pairlines<1>(out); }
__global__ void read_pairlines_stride16(float *out) { read_pairlines<16>(out); }
__global__ void write_pairlines_stride16(float *out) { write_pairlines<16>(out); }

// LDS atomics (instrumented since 2026-11-09): a lane-serial cost even on one
// address. Results unused: the no-return form.
#define ATOMIC_KERNEL(T, NAME, EXPR, OP)                                       \
  __global__ void atomic_##NAME(T *out) {                                      \
    __shared__ T s[LDS_DWORDS * 4 / sizeof(T)];                                \
    for (unsigned i = threadIdx.x; i < LDS_DWORDS * 4 / sizeof(T); i += 64)    \
      s[i] = (T)i;                                                             \
    __syncthreads();                                                           \
    unsigned l = threadIdx.x;                                                  \
    unsigned idx = (EXPR);                                                     \
    for (int k = 0; k < REPS; ++k) {                                           \
      OP;                                                                      \
      REPEAT_FENCE();                                                          \
    }                                                                          \
    __syncthreads();                                                           \
    out[blockIdx.x * 64 + l] = s[l];                                           \
  }
ATOMIC_KERNEL(unsigned, u32_stride1, l, atomicAdd(&s[idx], 1u))
ATOMIC_KERNEL(unsigned, u32_bcast, 0u, atomicAdd(&s[idx], 1u))
ATOMIC_KERNEL(unsigned, u32_stride32, 32 * l, atomicMax(&s[idx], l))
ATOMIC_KERNEL(unsigned long long, u64_stride1, l, atomicAdd(&s[idx], 1ull))
ATOMIC_KERNEL(unsigned long long, u64_stride16, 16 * l, atomicAdd(&s[idx], 1ull))
ATOMIC_KERNEL(unsigned, cas_stride1, l, atomicCAS(&s[idx], k, l))
ATOMIC_KERNEL(unsigned, cas_stride16, 16 * l, atomicCAS(&s[idx], k, l))
ATOMIC_KERNEL(float, f32_stride1, l, atomicAdd(&s[idx], 1.0f))
ATOMIC_KERNEL(float, f32_bcast, 0u, atomicAdd(&s[idx], 1.0f))

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
  RUN(b8_stride1) RUN(b8_stride128) RUN(b8_dword4) RUN(b16_stride64)
  RUN(b96_stride1) RUN(b96_stride8) RUN(b96_rwsplit)
  RUN(r2b32_stride1) RUN(r2b32_stride16) RUN(r2b64_stride1) RUN(r2b64_stride8)
  RUN(pair_stride1) RUN(pair_stride16) RUN(pairlines_stride1) RUN(pairlines_stride16)
  run(atomic_u32_stride1, "atomic_u32_stride1");
  run(atomic_u32_bcast, "atomic_u32_bcast");
  run(atomic_u32_stride32, "atomic_u32_stride32");
  run(atomic_u64_stride1, "atomic_u64_stride1");
  run(atomic_u64_stride16, "atomic_u64_stride16");
  run(atomic_cas_stride1, "atomic_cas_stride1");
  run(atomic_cas_stride16, "atomic_cas_stride16");
  run(atomic_f32_stride1, "atomic_f32_stride1");
  run(atomic_f32_bcast, "atomic_f32_bcast");
  return 0;
}
