# Float32 Self-Test over Direct Host Connection + URAM

This example turns `kernel_example_add_host` into a compact self-test kernel for the Alveo U50.
It keeps the original bluevitis/XRT structure, but replaces the original compute stage with a staged validation path for the Float32 library.

The example is intentionally small:

- the host writes a single 512-bit input beat
- the kernel reads that beat through the **direct host connection** on memory port 0
- the kernel stages the beat through **URAM-backed local storage**
- the kernel runs a fixed set of 32-bit floating-point operations
- the kernel writes one 512-bit result beat back through memory port 1

---

## What this example tests

This example checks three things at once:

1. **Float32 module functionality**
   - `mkFpAdd32`
   - `mkFpSub32`
   - `mkFpMult32`
   - `mkFpDiv32`
   - `mkFpSqrt32`
   - `mkFpExp32`
   - `mkFpFma32`
   - `mkFpSqrtCube32`

2. **Direct host-connected kernel memory connectivity**
   - the host writes one input beat into the input BO
   - the kernel issues a read on **memory port 0**
   - the kernel receives one 512-bit word through the host-connected path
   - the kernel writes one packed result beat back through **memory port 1**

3. **Internal URAM staging inside the kernel**
   - the input beat is stored into `uramIn` and read back before the Float32 tests start
   - the result beat is stored into `uramOut` and read back before it is written back to host memory

So this is not just a floating-point logic demo.
It also confirms that the **host ↔ direct host memory path ↔ kernel ↔ URAM** data path is correctly wired.

---

## Understanding the direct host connection in this design

This example is intentionally built on top of the **direct host-connected kernel interface** provided by the U50 platform configuration used in `kernel_example_add_host`.

### Connectivity used by this example

The build configuration maps the two kernel memory ports as follows:

- `kernel_1.in -> HOST[0]`
- `kernel_1.out -> HOST[0]`

Inside `KernelTop.bsv`, port 0 is driven from `mem_addr` and port 1 is driven from `file_addr`, so the kernel still sees two independent memory interfaces even though both are connected to the host-backed memory path. In practical terms:

- the **input buffer object** is attached to the host-connected input path on port 0
- the **output buffer object** is attached to the host-connected output path on port 1

### How much memory does the example actually touch?

The host allocates **4096 bytes** for the input BO and **4096 bytes** for the output BO, but the current self-test uses only the **first 64-byte beat** on each side.

In the current example:

- the host writes a single 512-bit test word into the first beat of `boIn`
- the kernel reads only that first 64-byte beat
- the kernel writes only one 64-byte result beat to `boOut`
- all other bytes remain unused

That means this example is **not a bandwidth test** and **not a large host-memory capacity test**.
It is a minimal functional test of a direct host-connected kernel path with URAM staging in the middle.

---

## Prerequisite: generate the floating-point IP cores first

This example depends on pre-generated floating-point IP cores from `bluelibrary`.
Before building the hardware example, generate the U50-targeted floating-point core set:

```bash
cd ../../../bluelibrary/core
bash gen-u50.sh
```

This generates the U50 floating-point IP set under `bluelibrary/core/u50/`.
The current generation flow covers the single-precision cores expected by `Float32.bsv`, including:

- `fp_add32`
- `fp_sub32`
- `fp_mult32`
- `fp_div32`
- `fp_sqrt32`
- `fp_fma32`
- `fp_exp32`

After generation, your packaging flow must also import the generated `.xci` files into the Vivado project, typically through `fp_import.tcl` in `package_kernel.tcl`.

If you see errors such as:

```text
Module <fp_add32> not found
Module <fp_div32> not found
```

then the floating-point cores were either not generated yet, or they were not imported into the packaging project.

---

## Module behavior summary

### `mkFpAdd32`
`mkFpAdd32` performs one single-precision floating-point addition.

In this example:

- input = `1.5 + 2.25`
- expected result = `3.75`
- expected bits = `0x40700000`

### `mkFpSub32`
`mkFpSub32` performs one single-precision floating-point subtraction.

In this example:

- input = `5.5 - 2.25`
- expected result = `3.25`
- expected bits = `0x40500000`

### `mkFpMult32`
`mkFpMult32` performs one single-precision floating-point multiplication.

In this example:

- input = `1.5 * (-2.0)`
- expected result = `-3.0`
- expected bits = `0xC0400000`

### `mkFpDiv32`
`mkFpDiv32` performs one single-precision floating-point division.

In this example:

- input = `7.5 / 2.5`
- expected result = `3.0`
- expected bits = `0x40400000`

### `mkFpSqrt32`
`mkFpSqrt32` performs one single-precision floating-point square root.

In this example:

- input = `9.0`
- expected result = `3.0`
- expected bits = `0x40400000`

### `mkFpExp32`
`mkFpExp32` performs one single-precision exponential.

In this example:

- input = `0.0`
- expected result = `1.0`
- expected bits = `0x3F800000`

### `mkFpFma32`
`mkFpFma32` performs a fused multiply-add/subtract style operation.

In this example the addition path is used:

- input = `(1.5 * 2.0) + 0.5`
- expected result = `3.5`
- expected bits = `0x40600000`

### `mkFpSqrtCube32`
`mkFpSqrtCube32` computes `a * sqrt(a)`.

In this example:

- input = `4.0`
- expected result = `8.0`
- expected bits = `0x41000000`

---

## End-to-end flow of the example

### 1. Host prepares one 512-bit input word

The host allocates:

- `boIn` for the input memory path
- `boOut` for the output/result memory path

Both are created as **host-only XRT BOs**.
The host then fills the first 512-bit input beat as 16 lanes of 32 bits each:

| Lane | Meaning |
|---|---|
| 0 | `add_a = 1.5` |
| 1 | `add_b = 2.25` |
| 2 | `sub_a = 5.5` |
| 3 | `sub_b = 2.25` |
| 4 | `mul_a = 1.5` |
| 5 | `mul_b = -2.0` |
| 6 | `div_a = 7.5` |
| 7 | `div_b = 2.5` |
| 8 | `sqrt_a = 9.0` |
| 9 | `exp_a = 0.0` |
| 10 | `fma_a = 1.5` |
| 11 | `fma_b = 2.0` |
| 12 | `fma_c = 0.5` |
| 13 | `sqrtcube_a = 4.0` |
| 14 | host-path sentinel 0 = `0x13579BDF` |
| 15 | host-path sentinel 1 = `0x2468ACE0` |

### 2. Host launches the kernel

The host launches the kernel with the usual ABI:

- scalar argument
- input BO (`mem`, port 0)
- output BO (`file`, port 1)

The scalar value is not used for the arithmetic itself.

### 3. Kernel reads the input beat from port 0

Inside `KernelMain.bsv`, the kernel:

- issues a **64-byte read request** on memory port 0
- waits for one 512-bit word to return
- stores that word into `uramIn`

This is the explicit direct-host input step.

### 4. Kernel validates the host-to-URAM path

Before running any floating-point operation, the kernel reads the staged input word back from `uramIn` and checks that the two sentinel lanes are still intact:

- lane 14 must still be `0x13579BDF`
- lane 15 must still be `0x2468ACE0`

This is the explicit **host → direct host connection → kernel → URAM** validation step.

### 5. Kernel runs all Float32 module tests sequentially

Using the URAM-returned input word, the kernel runs:

1. `mkFpAdd32`
2. `mkFpSub32`
3. `mkFpMult32`
4. `mkFpDiv32`
5. `mkFpSqrt32`
6. `mkFpExp32`
7. `mkFpFma32`
8. `mkFpSqrtCube32`

Each observed output is compared against a fixed expected 32-bit bit pattern.
If a module matches, the corresponding bit in `passMask` is set.

### 6. Kernel packs the result word

After all tests complete, the kernel packs a single 512-bit result word containing:

- a magic signature
- a status word
- a pass mask
- cycle count
- all observed Float32 outputs
- the two echoed sentinel values
- the final host-path pass flag

### 7. Kernel stages the result through a second URAM

Before writing the result back to host memory, the kernel stores the result word into `uramOut` and reads it back once more.

This gives the example a symmetric structure:

- input word staged through URAM before compute
- output word staged through URAM before write-back

### 8. Kernel writes the result to port 1

The kernel issues a **64-byte write request** on memory port 1 and writes the single 512-bit result beat back to the output BO.

### 9. Host checks all observed values

The host:

- syncs `boOut` back from device memory
- reads the result lanes
- checks the magic value
- checks the host-path sentinel echo and pass flag
- checks every Float32 module result against a software-side expected bit pattern
- reports `TEST PASSED` only if everything matches

---

## Output word format

The kernel writes one 512-bit output word as 16 lanes of 32 bits each.

| Lane | Meaning |
|---|---|
| 0 | magic = `0x46503332` (`"FP32"`) |
| 1 | status (`3` means overall PASS) |
| 2 | `passMask` |
| 3 | elapsed cycles |
| 4 | observed result from `mkFpAdd32` |
| 5 | observed result from `mkFpSub32` |
| 6 | observed result from `mkFpMult32` |
| 7 | observed result from `mkFpDiv32` |
| 8 | observed result from `mkFpSqrt32` |
| 9 | observed result from `mkFpExp32` |
| 10 | observed result from `mkFpFma32` |
| 11 | observed result from `mkFpSqrtCube32` |
| 12 | echoed sentinel 0 after the URAM input path |
| 13 | echoed sentinel 1 after the URAM input path |
| 14 | host-path pass flag |
| 15 | zero |

---

## Expected test vectors and expected results

### Floating-point test cases

- `1.5 + 2.25 = 3.75` → `0x40700000`
- `5.5 - 2.25 = 3.25` → `0x40500000`
- `1.5 * (-2.0) = -3.0` → `0xC0400000`
- `7.5 / 2.5 = 3.0` → `0x40400000`
- `sqrt(9.0) = 3.0` → `0x40400000`
- `exp(0.0) = 1.0` → `0x3F800000`
- `(1.5 * 2.0) + 0.5 = 3.5` → `0x40600000`
- `4.0 * sqrt(4.0) = 8.0` → `0x41000000`

### Host-path sentinels

- sentinel 0 = `0x13579BDF`
- sentinel 1 = `0x2468ACE0`

### Expected pass state

- `magic = 0x46503332`
- `status = 3`
- `passMask = 0xFF`
- `hostPathPass = 1`

---

## Files involved

### Hardware

- `hw/kernel_example_add_host/KernelTop.bsv`
- `hw/kernel_example_add_host/KernelMain.bsv`
- `hw/kernel_example_add_host/u50.cfg`
- `bluelibrary/bsv/Float32.bsv`
- `bluelibrary/bsv/URAM.bsv`

### Software

- `sw/host_example_add_host/main.cpp`

### Core-generation support

- `bluelibrary/core/gen-u50.sh`
- `bluelibrary/core/synth-fp-u50.tcl`
- `bluelibrary/core/fp_import.tcl`

---

## Why this example is useful

This example is intentionally compact, but it demonstrates several useful things at once:

- how to use the **direct host connection** as the kernel memory backend
- how to stage host-provided data through **URAM-backed local storage**
- how to exercise multiple Float32 modules from one fixed input beat
- how to package module-level results into one compact return word
- how to validate vendor-IP-backed floating-point modules in a realistic bluevitis flow
- how to debug both arithmetic correctness and memory-path correctness in one self-test

It is a good starting point for larger kernels where:

- floating-point operators are mixed with host-fed control or parameter blocks
- local URAM staging is needed between memory and compute
- a small deterministic self-test is useful before integrating a larger data path
