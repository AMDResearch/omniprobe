"""Triton host for tests/test_python_host.sh: back-to-back launches with no
sync in between, so the host thread holds the GIL in Triton's launcher while
earlier dispatches complete.

    triton_host.py <launches> <elements>
"""
import builtins
import os
import sys
import torch
import triton
import triton.language as tl

@triton.jit
def add_kernel(x_ptr, y_ptr, out_ptr, n, BLOCK: tl.constexpr):
    pid = tl.program_id(0)
    offs = pid * BLOCK + tl.arange(0, BLOCK)
    m = offs < n
    tl.store(out_ptr + offs, tl.load(x_ptr + offs, mask=m) + tl.load(y_ptr + offs, mask=m), mask=m)

launches, size = int(sys.argv[1]), int(sys.argv[2])
builtins.PYHOST_MARKER = f"host-{os.getpid()}"
dev = triton.runtime.driver.active.get_active_torch_device()
x = torch.rand(size, device=dev); y = torch.rand(size, device=dev); out = torch.empty_like(x)
grid = (triton.cdiv(size, 1024),)
for i in range(launches):
    add_kernel[grid](x, y, out, size, BLOCK=1024)
torch.cuda.synchronize()
ok = torch.allclose(out, x + y)
print(f"PYHOST_RC={0 if ok else 1}", flush=True)
sys.exit(0 if ok else 1)
