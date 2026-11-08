// Measures LDS conflict sets: which lanes of a wave are served in the same LDS
// phase, so that two of them hitting one bank conflict. For a pair of lanes
// (i, j), only those two lanes access LDS, at addresses STRIDE bytes apart --
// different addresses, same bank when the bank count divides STRIDE/4 -- REPS
// times. Under rocprofv3, SQ_LDS_BANK_CONFLICT for that dispatch is then
// REPS x (extra passes): nonzero iff i and j share a phase (and a bank).
// tests/lds_conflict_sets/run.sh sweeps all pairs and derives the map.
//
// Usage: lds_conflict_sets <4|8|16> <stride bytes> <read|write> all
//        lds_conflict_sets <4|8|16> <stride bytes> <read|write> <i> <j>
// "all" launches one dispatch per pair (i < j), in order (0,1), (0,2), ...

#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

constexpr int REPS = 64;
constexpr int LDS_BYTES = 16384;

template <typename T> __device__ T make(int v);
template <> __device__ float make<float>(int v) { return v; }
template <> __device__ double make<double>(int v) { return v; }
template <> __device__ float4 make<float4>(int v) { return float4{float(v), 0.f, 0.f, 0.f}; }

template <typename T> __device__ void add(T &a, const T &b) { a += b; }
template <> __device__ void add<float4>(float4 &a, const float4 &b) { a.x += b.x; a.y += b.y; a.z += b.z; a.w += b.w; }

template <typename T> __global__ void pair_read(T *out, int i, int j, int stride) {
  __shared__ T s[LDS_BYTES / sizeof(T)];
  unsigned l = threadIdx.x;
  if (l == 0) { // one lane: no conflicts of its own
    s[0] = make<T>(1);
    s[stride / sizeof(T)] = make<T>(2);
  }
  __syncthreads();
  T acc = make<T>(0);
  if (l == unsigned(i) || l == unsigned(j)) {
    unsigned idx = (l == unsigned(i)) ? 0 : stride / sizeof(T);
    for (int r = 0; r < REPS; ++r) {
      add(acc, s[idx]);
      __asm__ volatile("" ::: "memory");
    }
  }
  out[l] = acc;
}

template <typename T> __global__ void pair_write(T *out, int i, int j, int stride) {
  __shared__ T s[LDS_BYTES / sizeof(T)];
  unsigned l = threadIdx.x;
  if (l == unsigned(i) || l == unsigned(j)) {
    unsigned idx = (l == unsigned(i)) ? 0 : stride / sizeof(T);
    for (int r = 0; r < REPS; ++r) {
      s[idx] = make<T>(r + l);
      __asm__ volatile("" ::: "memory");
    }
  }
  __syncthreads();
  out[l] = s[l];
}

template <typename T> static void launch(bool write, int i, int j, int stride, T *d) {
  if (write)
    pair_write<T><<<1, 64>>>(d, i, j, stride);
  else
    pair_read<T><<<1, 64>>>(d, i, j, stride);
  if (hipDeviceSynchronize() != hipSuccess) {
    fprintf(stderr, "dispatch (%d,%d) failed\n", i, j);
    exit(1);
  }
}

template <typename T> static void sweep(bool write, int stride, int argc, char **argv) {
  T *d;
  if (hipMalloc(&d, 64 * sizeof(T)) != hipSuccess)
    exit(1);
  if (argc == 5) {
    for (int i = 0; i < 64; ++i)
      for (int j = i + 1; j < 64; ++j)
        launch<T>(write, i, j, stride, d);
  } else {
    launch<T>(write, atoi(argv[4]), atoi(argv[5]), stride, d);
  }
  (void)hipFree(d);
}

int main(int argc, char **argv) {
  if (argc != 5 && argc != 6) {
    fprintf(stderr, "usage: %s <4|8|16> <stride bytes> <read|write> all|<i> <j>\n", argv[0]);
    return 2;
  }
  int width = atoi(argv[1]), stride = atoi(argv[2]);
  bool write = !strcmp(argv[3], "write");
  if (stride % width || stride + width > LDS_BYTES) {
    fprintf(stderr, "bad stride\n");
    return 2;
  }
  if (width == 4) sweep<float>(write, stride, argc, argv);
  else if (width == 8) sweep<double>(write, stride, argc, argv);
  else if (width == 16) sweep<float4>(write, stride, argc, argv);
  else return 2;
  return 0;
}
