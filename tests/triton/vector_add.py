"""
Minimal Triton vector-add for omniprobe integration testing.
Based on Triton's 01-vector-add.py tutorial, stripped down to run
only a handful of kernel dispatches (no benchmarking).
"""

import torch
import triton
import triton.language as tl

DEVICE = triton.runtime.driver.active.get_active_torch_device()


@triton.jit
def add_kernel(
    x_ptr,
    y_ptr,
    output_ptr,
    n_elements,
    BLOCK_SIZE: tl.constexpr,
):
    pid = tl.program_id(axis=0)
    block_start = pid * BLOCK_SIZE
    offsets = block_start + tl.arange(0, BLOCK_SIZE)
    mask = offsets < n_elements
    x = tl.load(x_ptr + offsets, mask=mask)
    y = tl.load(y_ptr + offsets, mask=mask)
    output = x + y
    tl.store(output_ptr + offsets, output, mask=mask)


def add(x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
    output = torch.empty_like(x)
    n_elements = output.numel()
    grid = lambda meta: (triton.cdiv(n_elements, meta["BLOCK_SIZE"]),)
    add_kernel[grid](x, y, output, n_elements, BLOCK_SIZE=1024)
    return output


def main():
    torch.manual_seed(0)
    size = 4096  # small — just a few work-groups
    x = torch.rand(size, device=DEVICE)
    y = torch.rand(size, device=DEVICE)

    # Run the kernel a handful of times
    for i in range(3):
        output_triton = add(x, y)

    output_torch = x + y
    max_diff = torch.max(torch.abs(output_torch - output_triton)).item()
    print(f"Max difference between torch and triton: {max_diff}")
    assert max_diff == 0.0, f"Correctness check failed: max_diff={max_diff}"
    print("Triton vector-add test PASSED")


if __name__ == "__main__":
    main()
