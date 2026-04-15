# Float32 + Float64 Self-Test over Direct Host Connection + URAM

This example turns `kernel_example_add_host` into a compact floating-point self-test kernel for the Alveo U50.
It keeps the original bluevitis/XRT structure, but replaces the original compute stage with a staged validation path for both the `Float32` and `Float64` libraries.

The example is intentionally small:

- the host writes **three 512-bit input beats**
- the kernel reads those beats through the **direct host connection** on memory port 0
- the kernel stages the beats through **URAM-backed local storage**
- the kernel runs a fixed set of **32-bit and 64-bit floating-point operations**
- the kernel writes **three 512-bit result beats** back through memory port 1

---

## What this example tests

This example checks four things at once:

1. **Float32 module functionality**
   - `mkFpAdd32`
   - `mkFpSub32`
   - `mkFpMult32`
   - `mkFpDiv32`
   - `mkFpSqrt32`
   - `mkFpExp32`
   - `mkFpFma32`
   - `mkFpSqrtCube32`

2. **Float64 module functionality**
   - `mkFpAdd64`
   - `mkFpSub64`
   - `mkFpMult64`
   - `mkFpDiv64`
   - `mkFpSqrt64`
   - `mkFpExp64`
   - `mkFpFma64`
   - `mkFpSqrtCube64`

3. **Direct host-connected kernel memory connectivity**
   - the host writes three input beats into the input BO
   - the kernel issues reads on **memory port 0**
   - the kernel receives three 512-bit words through the host-connected path
   - the kernel writes three packed result beats back through **memory port 1**

4. **Internal URAM staging inside the kernel**
   - the three input beats are stored into `uramIn` and read back before the floating-point tests start
   - the three result beats are stored into `uramOut` and read back before they are written back to host memory

So this is not just a floating-point logic demo.
It also confirms that the **host ↔ direct host memory path ↔ kernel ↔ URAM** data path is correctly wired.

---

## Understanding the direct host connection in this design

This example is intentionally built on top of the **direct host-connected kernel interface** provided by the U50 platform configuration used in `kernel_example_add_host`.

### Connectivity used by this example

The build configuration maps the two kernel memory ports as follows:

- `kernel_1.in -> HOST[0]`
- `kernel_1.out -> HOST[0]`

Inside `KernelTop.bsv`, port 0 is driven from `mem_addr` and port 1 is driven from `file_addr`, so the kernel still sees two independent memory interfaces even though both are connected to the same host-backed memory path.

In practical terms:

- the **input buffer object** is attached to the host-connected input path on port 0
- the **output buffer object** is attached to the host-connected output path on port 1

### How much memory does the example actually touch?

The host allocates **4096 bytes** for the input BO and **4096 bytes** for the output BO, but the current self-test uses only the **first three 64-byte beats** on each side.

In the current example:

- the host writes **3 × 64 B = 192 B** of input data
- the kernel reads only those first three 64-byte beats
- the kernel writes only three 64-byte result beats
- all remaining bytes in the BOs are unused

That means this example is **not a bandwidth test** and **not a large host-memory capacity test**.
It is a compact functional test of a direct host-connected kernel path with URAM staging in the middle.

---

## Prerequisite: generate the floating-point IP cores first

This example depends on pre-generated floating-point IP cores from `bluelibrary`.
Before building the hardware example, make sure the U50-targeted floating-point core set has been generated.

In the updated local flow, this is done by running:

```bash
cd ../../../bluelibrary/core
bash gen-u50.sh
```

This example assumes that your local `gen-u50.sh` flow generates the required U50 floating-point IP cores for both:

- the **32-bit** operators used by `Float32.bsv`
- the **64-bit** operators used by `Float64.bsv`

After generation, your packaging flow must also import the generated `.xci` files into the Vivado project, typically through `fp_import.tcl` inside `package_kernel.tcl`.

If you see errors such as:

```text
Module <fp_add32> not found
Module <fp_div64> not found
```

then the floating-point cores were either not generated yet, or they were not imported into the packaging project.

---

## Module behavior summary

### Float32 modules

This example uses the following 32-bit floating-point test vectors and expected results:

- `mkFpAdd32`      : `1.5 + 2.25 = 3.75`      → `0x40700000`
- `mkFpSub32`      : `5.5 - 2.25 = 3.25`      → `0x40500000`
- `mkFpMult32`     : `1.5 * (-2.0) = -3.0`    → `0xC0400000`
- `mkFpDiv32`      : `7.5 / 2.5 = 3.0`        → `0x40400000`
- `mkFpSqrt32`     : `sqrt(9.0) = 3.0`        → `0x40400000`
- `mkFpExp32`      : `exp(0.0) = 1.0`         → `0x3F800000`
- `mkFpFma32`      : `(1.5 * 2.0) + 0.5 = 3.5`→ `0x40600000`
- `mkFpSqrtCube32` : `4.0 * sqrt(4.0) = 8.0`  → `0x41000000`

### Float64 modules

This example uses the following 64-bit floating-point test vectors and expected results:

- `mkFpAdd64`      : `1.5 + 2.25 = 3.75`      → `0x400E000000000000`
- `mkFpSub64`      : `5.5 - 2.25 = 3.25`      → `0x400A000000000000`
- `mkFpMult64`     : `1.5 * (-2.0) = -3.0`    → `0xC008000000000000`
- `mkFpDiv64`      : `7.5 / 2.5 = 3.0`        → `0x4008000000000000`
- `mkFpSqrt64`     : `sqrt(9.0) = 3.0`        → `0x4008000000000000`
- `mkFpExp64`      : `exp(0.0) = 1.0`         → `0x3FF0000000000000`
- `mkFpFma64`      : `(1.5 * 2.0) + 0.5 = 3.5`→ `0x400C000000000000`
- `mkFpSqrtCube64` : `4.0 * sqrt(4.0) = 8.0`  → `0x4020000000000000`

---

## End-to-end flow of the example

### 1. Host prepares three 512-bit input beats

The host allocates:

- `boIn` for the input memory path
- `boOut` for the output/result memory path

Both are created as **host-only XRT BOs**.
The host then fills three 512-bit beats.

#### Beat 0: Float32 inputs (16 lanes of 32 bits)

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
| 14 | 32-bit host-path sentinel 0 = `0x13579BDF` |
| 15 | 32-bit host-path sentinel 1 = `0x2468ACE0` |

#### Beat 1: Float64 binary-op inputs (8 lanes of 64 bits)

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

#### Beat 2: Float64 unary / ternary inputs + sentinels (8 lanes of 64 bits)

| Lane | Meaning |
|---|---|
| 0 | `sqrt_a = 9.0` |
| 1 | `exp_a = 0.0` |
| 2 | `fma_a = 1.5` |
| 3 | `fma_b = 2.0` |
| 4 | `fma_c = 0.5` |
| 5 | `sqrtcube_a = 4.0` |
| 6 | 64-bit host-path sentinel 0 = `0x0123456789ABCDEF` |
| 7 | 64-bit host-path sentinel 1 = `0x0FEDCBA987654321` |

### 2. Host launches the kernel

The host launches the kernel with the usual ABI:

- scalar argument
- input BO (`mem`, port 0)
- output BO (`file`, port 1)

The scalar value is not used for the arithmetic itself.

### 3. Kernel reads the three input beats from port 0

Inside `KernelMain.bsv`, the kernel:

- issues three **64-byte read requests** on memory port 0
- waits for three 512-bit words to return
- stores those words into `uramIn`

This is the explicit direct-host input step.

### 4. Kernel validates the host-to-URAM path

Before running any floating-point operation, the kernel reads the staged input beats back from `uramIn` and checks that the sentinel values are still intact.

For the 32-bit path:

- beat 0 lane 14 must still be `0x13579BDF`
- beat 0 lane 15 must still be `0x2468ACE0`

For the 64-bit path:

- beat 2 lane 6 must still be `0x0123456789ABCDEF`
- beat 2 lane 7 must still be `0x0FEDCBA987654321`

This is the explicit **host → direct host connection → kernel → URAM** validation step.

### 5. Kernel runs all Float32 module tests sequentially

Using the URAM-returned beat 0, the kernel runs:

1. `mkFpAdd32`
2. `mkFpSub32`
3. `mkFpMult32`
4. `mkFpDiv32`
5. `mkFpSqrt32`
6. `mkFpExp32`
7. `mkFpFma32`
8. `mkFpSqrtCube32`

Each observed output is compared against a fixed expected 32-bit bit pattern.
If the result matches, the corresponding low-half `passMask` bit is set.

### 6. Kernel runs all Float64 module tests sequentially

Using the URAM-returned beats 1 and 2, the kernel runs:

1. `mkFpAdd64`
2. `mkFpSub64`
3. `mkFpMult64`
4. `mkFpDiv64`
5. `mkFpSqrt64`
6. `mkFpExp64`
7. `mkFpFma64`
8. `mkFpSqrtCube64`

Each observed output is compared against a fixed expected 64-bit bit pattern.
If the result matches, the corresponding high-half `passMask` bit is set.

### 7. Kernel packs three result beats

After all tests complete, the kernel packs the observations into three 512-bit result beats.

#### Result beat 0: summary + Float32 observations (16 lanes of 32 bits)

| Lane | Meaning |
|---|---|
| 0 | magic = `0x46505832` (`"FPX2"`) |
| 1 | status (`3` means overall PASS) |
| 2 | `passMask` |
| 3 | elapsed cycles |
| 4 | observed `mkFpAdd32` |
| 5 | observed `mkFpSub32` |
| 6 | observed `mkFpMult32` |
| 7 | observed `mkFpDiv32` |
| 8 | observed `mkFpSqrt32` |
| 9 | observed `mkFpExp32` |
| 10 | observed `mkFpFma32` |
| 11 | observed `mkFpSqrtCube32` |
| 12 | echoed 32-bit sentinel 0 |
| 13 | echoed 32-bit sentinel 1 |
| 14 | 32-bit host-path pass flag |
| 15 | 64-bit host-path pass flag |

#### Result beat 1: Float64 observations (8 lanes of 64 bits)

| Lane | Meaning |
|---|---|
| 0 | observed `mkFpAdd64` |
| 1 | observed `mkFpSub64` |
| 2 | observed `mkFpMult64` |
| 3 | observed `mkFpDiv64` |
| 4 | observed `mkFpSqrt64` |
| 5 | observed `mkFpExp64` |
| 6 | observed `mkFpFma64` |
| 7 | observed `mkFpSqrtCube64` |

#### Result beat 2: echoed 64-bit sentinels (8 lanes of 64 bits)

| Lane | Meaning |
|---|---|
| 0 | echoed 64-bit sentinel 0 |
| 1 | echoed 64-bit sentinel 1 |
| 2-7 | zero |

### 8. Kernel stages the result through URAM and writes it back

Before writing the results back to host memory, the kernel stores the three result beats into `uramOut`, reads them back, and only then issues three **64-byte write requests** on memory port 1.

This makes the output path symmetric with the input path:

- host memory → kernel port 0 → `uramIn` → floating-point modules
- floating-point modules → `uramOut` → kernel port 1 → host memory

### 9. Host reads the result and validates everything

The host:

- syncs `boOut` back from device memory
- reads the three result beats
- checks the magic value
- checks the two host-path flags
- checks all 8 Float32 results
- checks all 8 Float64 results
- checks that `passMask == 0xFFFF`
- reports `TEST PASSED` only if every check succeeds

---

## Expected results

### Expected summary values

- magic = `0x46505832`
- status = `3`
- `passMask = 0x0000FFFF`
- 32-bit host-path flag = `1`
- 64-bit host-path flag = `1`

### Expected Float32 observations

- `mkFpAdd32`      → `0x40700000`
- `mkFpSub32`      → `0x40500000`
- `mkFpMult32`     → `0xC0400000`
- `mkFpDiv32`      → `0x40400000`
- `mkFpSqrt32`     → `0x40400000`
- `mkFpExp32`      → `0x3F800000`
- `mkFpFma32`      → `0x40600000`
- `mkFpSqrtCube32` → `0x41000000`

### Expected Float64 observations

- `mkFpAdd64`      → `0x400E000000000000`
- `mkFpSub64`      → `0x400A000000000000`
- `mkFpMult64`     → `0xC008000000000000`
- `mkFpDiv64`      → `0x4008000000000000`
- `mkFpSqrt64`     → `0x4008000000000000`
- `mkFpExp64`      → `0x3FF0000000000000`
- `mkFpFma64`      → `0x400C000000000000`
- `mkFpSqrtCube64` → `0x4020000000000000`

### Expected echoed sentinels

- 32-bit sentinel 0 → `0x13579BDF`
- 32-bit sentinel 1 → `0x2468ACE0`
- 64-bit sentinel 0 → `0x0123456789ABCDEF`
- 64-bit sentinel 1 → `0x0FEDCBA987654321`

---

## Files involved

### Hardware

- `hw/kernel_example_add_host/KernelTop.bsv`
- `hw/kernel_example_add_host/KernelMain.bsv`
- `hw/kernel_example_add_host/u50.cfg`
- `bluelibrary/bsv/Float32.bsv`
- `bluelibrary/bsv/Float64.bsv`
- `bluelibrary/bsv/URAM.bsv`

### Software

- `sw/host_example_add_host/main.cpp`

### Core-generation support

- `bluelibrary/core/gen-u50.sh`
- `bluelibrary/core/synth-fp-u50.tcl`
- `bluelibrary/core/synth-fp-double-u50.tcl`
- `bluelibrary/core/fp_import.tcl`

---

## Why this example is useful

This example is intentionally compact, but it demonstrates several useful things at once:

- how to connect a bluevitis kernel to the **direct host memory path**
- how to read multiple AXI memory beats into Bluespec logic
- how to stage input and output through **URAM-backed local storage**
- how to validate both **Float32** and **Float64** arithmetic modules in one self-test kernel
- how to return compact, structured results to host memory
- how to validate hardware behavior against fixed host-side golden values

It is a good starting point for larger host-connected kernels where:

- a small number of structured input beats are read from host-visible memory
- the compute path mixes 32-bit and 64-bit arithmetic
- local on-chip staging is useful before or after the compute phase
- and the result needs to be reported back in a simple, debuggable format
