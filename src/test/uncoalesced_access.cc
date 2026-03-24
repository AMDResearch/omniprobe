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

#include <hip/hip_runtime.h>
#include <unistd.h>

__global__ void sxpy_strided(int* a, int* b, size_t size){
    size_t idx = 4 * threadIdx.x;
    if(idx >= size){ return; }
    a[idx] += b[idx];
}

int main(){
    printf("starting main\n");
    constexpr size_t blocksize = 64;
    constexpr size_t no_blocks = 1;
    constexpr size_t vec_size = 4 * blocksize;

    int *a, *b;
    auto err = hipHostMalloc(&a, vec_size, hipHostMallocNonCoherent);
    err = hipHostMalloc(&b, vec_size, hipHostMallocNonCoherent);

    sxpy_strided<<<no_blocks, blocksize>>>(a, b, vec_size);

    err = hipDeviceSynchronize();

    err = hipFree(b);
    err = hipFree(a);
    printf("main thread done\n");
}