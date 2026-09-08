// Reproducer for bf_hip-duplicate-code-object-load.
//
// A HIP kernel with two __constant__ globals set via hipMemcpyToSymbol, plus a
// scalar and a pointer passed as kernargs. Prints whether each class of state
// arrived intact inside the dispatched kernel.
//
// Under `omniprobe -i` the clone is dispatched out of Omniprobe's own private
// copy of the code object, whose __constant__ segment is never initialised, so
// the __constant__ values read as zero while the kernargs stay correct.
//
// Provenance: written 2026-09-01 during PENNANT profiling on MI350X/gfx950 as
// argprobe_g.hip; body copied here unmodified.
// Variant G: report BOTH what the clone sees in kernargs (scale) and in __constant__ globals.
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstring>
__constant__ double *cdata;
__constant__ int cscalar;
__global__ void probe_g(double scale, const int *idx, double *out, unsigned long long *seen) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= 64) return;
  if (i == 0) { seen[0]=(unsigned long long)cdata; seen[1]=(unsigned long long)cscalar;
                seen[2]=__double_as_longlong(scale); seen[3]=(unsigned long long)idx; }
  out[i] = (cdata==nullptr) ? -1.0 : scale*cdata[idx[i]];
}
int main() {
  const int N=64; double *d_data,*d_out,h_data[N],h_out[N]; int *d_idx,h_idx[N];
  unsigned long long *d_seen,h_seen[4]={0,0,0,0};
  for(int i=0;i<N;i++){h_data[i]=i+1;h_idx[i]=N-1-i;}
  (void)hipMalloc(&d_data,N*sizeof(double)); (void)hipMalloc(&d_out,N*sizeof(double));
  (void)hipMalloc(&d_idx,N*sizeof(int)); (void)hipMalloc(&d_seen,4*sizeof(unsigned long long));
  (void)hipMemcpy(d_data,h_data,N*sizeof(double),hipMemcpyHostToDevice);
  (void)hipMemcpy(d_idx,h_idx,N*sizeof(int),hipMemcpyHostToDevice);
  int hs=12345;
  (void)hipMemcpyToSymbol(HIP_SYMBOL(cdata),&d_data,sizeof(double*));
  (void)hipMemcpyToSymbol(HIP_SYMBOL(cscalar),&hs,sizeof(int));
  hipLaunchKernelGGL(probe_g,dim3(1),dim3(N),0,0,2.5,d_idx,d_out,d_seen);
  (void)hipDeviceSynchronize();
  (void)hipMemcpy(h_out,d_out,N*sizeof(double),hipMemcpyDeviceToHost);
  (void)hipMemcpy(h_seen,d_seen,4*sizeof(unsigned long long),hipMemcpyDeviceToHost);
  double seen_scale; memcpy(&seen_scale,&h_seen[2],8);
  printf("ARGPROBE_G host: cdata=%p cscalar=%d scale=2.5 idx=%p\n",(void*)d_data,hs,(void*)d_idx);
  printf("ARGPROBE_G clone saw: cdata=0x%llx cscalar=%llu scale=%g idx=0x%llx\n",
         h_seen[0],h_seen[1],seen_scale,h_seen[3]);
  printf("ARGPROBE_G kernargs %s, __constant__ %s\n",
         (seen_scale==2.5 && h_seen[3]==(unsigned long long)d_idx)?"OK":"CORRUPT",
         (h_seen[0]==(unsigned long long)d_data && h_seen[1]==12345)?"OK":"CORRUPT");
  return 0;
}
