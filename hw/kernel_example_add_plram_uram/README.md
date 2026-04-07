# Serializer Package Self-Test with Host Input over URAM-Mapped PLRAM

This example validates the `Serializer.bsv` package inside the `kernel_example_add_plram_uram` design while also checking the **host -> input buffer -> PLRAM/URAM-mapped memory path -> kernel** read path.

Unlike the earlier self-test that generated all stimulus inside the kernel, this version uses a host-provided 32-bit word as the test vector for `mkSerializer` and `mkDeSerializer`.

---

## What this example tests

This example covers two things at once:

1. **Serializer package functionality**
   - `mkSerializer`
   - `mkDeSerializer`
   - `mkStreamReplicate`
   - `mkStreamSerializeLast`
   - `mkStreamSkip`
   - `mkPipelineShiftRight`
   - `mkSerializerFreeform`

2. **Input-memory connectivity**
   - The host writes `0x11223344` into `boIn[0]`
   - The kernel issues a read request on **memory port 0**
   - The kernel receives the first 512-bit word from the input buffer
   - Lane 0 of that word is used as the serializer/deserializer test vector

So this is not only a logic self-test. It also confirms that the input side of the kernel is actually receiving the host-written value through the URAM-mapped PLRAM connection.

---

## Understanding the URAM-mapped PLRAM in this design

This example is intentionally built on top of a **PLRAM-backed kernel interface**, but with the selected PLRAM banks reconfigured to use **UltraRAM (URAM)** instead of the platform default BRAM implementation.

### Platform default

For the U50 Gen3x16 XDMA base_5 platform (`xilinx_u50_gen3x16_xdma_5_202210_1`), AMD documents four PLRAM channels:

- `PLRAM[0:1]` on **SLR0**
- `PLRAM[2:3]` on **SLR1**
- each channel listed as **128K** in the platform memory table

In the platform guide, these PLRAM resources are described as **block RAM** by default.

### What this example changes

The file `scripts/plram_uram.tcl` overrides the platform default for the two PLRAM banks used by this kernel:

- `PLRAM_MEM00`
  - `SIZE 128K`
  - `AXI_DATA_WIDTH 512`
  - `SLR_ASSIGNMENT SLR0`
  - `READ_LATENCY 1`
  - `MEMORY_PRIMITIVE URAM`

- `PLRAM_MEM01`
  - `SIZE 128K`
  - `AXI_DATA_WIDTH 512`
  - `SLR_ASSIGNMENT SLR0`
  - `READ_LATENCY 1`
  - `MEMORY_PRIMITIVE URAM`

So, in practical terms:

- the **input PLRAM bank** is configured as **128 KB = 131,072 bytes** of URAM-backed PLRAM
- the **output PLRAM bank** is configured as **128 KB = 131,072 bytes** of URAM-backed PLRAM
- the example therefore uses **two 128 KB URAM-mapped PLRAM regions**, one for input and one for output

### Which kernel port goes to which PLRAM bank?

The connectivity file maps the kernel ports as follows:

- `kernel_1.in  -> PLRAM[0]`
- `kernel_1.out -> PLRAM[1]`

Inside `KernelTop.bsv`, memory port 0 is driven from `mem_addr`, and memory port 1 is driven from `file_addr`, so the host-side BOs line up like this:

- `boIn`  -> kernel input port -> `PLRAM[0]` -> **URAM-backed input scratchpad**
- `boOut` -> kernel output port -> `PLRAM[1]` -> **URAM-backed output scratchpad**

### How much of that memory does this self-test actually touch?

The configured PLRAM capacity is larger than what the self-test needs.

In the current host/test code:

- each BO is allocated as **4096 bytes**
- the kernel reads only the **first 64 bytes** from the input BO
- the kernel writes only the **first 64 bytes** to the output BO

That means the self-test is **not trying to fill the entire 128 KB PLRAM bank**. It is simply using the first 512-bit beat to prove that the memory path is alive and correctly wired.

This is useful for bring-up because it isolates connectivity from bandwidth or capacity testing:

- if the kernel reads back `0x11223344` from the first lane, the host-to-URAM-to-kernel path works
- if the kernel writes the result word correctly, the kernel-to-URAM-to-host path works

---

## Module behavior summary

### `mkSerializer`

Splits one wide input word into multiple smaller output words.

In this example:

- input width = 32 bits
- split factor = 4
- output width = 8 bits
- output order = least-significant byte first

If the input is `0x11223344`, the output stream is:

- `0x44`
- `0x33`
- `0x22`
- `0x11`

### `mkDeSerializer`

Collects multiple smaller input words and reconstructs one wide output word.

In this example, feeding:

- `0x44`
- `0x33`
- `0x22`
- `0x11`

produces:

- `0x11223344`

### `mkStreamReplicate`

Repeats each input item `framesize` times.

In this example:

- input = `0xA6`
- `framesize = 3`

output stream:

- `0xA6`
- `0xA6`
- `0xA6`

### `mkStreamSerializeLast`

Expands one frame-level `last` flag into one flag per beat.

In this example:

- input flag = `True`
- `framesize = 4`

output stream:

- `False`
- `False`
- `False`
- `True`

### `mkStreamSkip`

Keeps only one element from each fixed-size frame and discards the others.

In this example:

- `framesize = 4`
- `offset = 2`

input stream:

- frame 0: `A0 A1 A2 A3`
- frame 1: `B0 B1 B2 B3`

output stream:

- `A2`
- `B2`

### `mkPipelineShiftRight`

Performs a variable right shift using a bit-sliced deep pipeline.

In this example:

- input value = `0xFEDCBA9876543210`
- shift amount = `12`

expected output:

- `0x000FEDCBA9876543`

### `mkSerializerFreeform`

Repackages a wider stream into a narrower stream even when the widths are not an integer multiple.

In this example:

- input width = 10 bits
- output width = 6 bits
- inputs = `0x3AB`, `0x155`, `0x2C3`

expected five outputs:

- `0x2B`
- `0x1E`
- `0x15`
- `0x0D`
- `0x2C`

These are packed into the 30-bit observed value:

- `0x2B79536C`

---

## End-to-end flow of the example

### 1. Host prepares buffers

The host allocates:

- `boIn` for the input memory path
- `boOut` for the output/result memory path

Then it writes:

- `boIn[0] = 0x11223344`

This value becomes lane 0 of the first 512-bit input word.

### 2. Host launches the kernel

The host launches the kernel with the same ABI as before:

- scalar argument
- input BO (`mem`, port 0)
- output BO (`file`, port 1)

### 3. Kernel reads the input word from port 0

Inside `KernelMain.bsv`, the kernel:

- issues a **64-byte read request** on memory port 0
- waits for one 512-bit word to return
- truncates lane 0 to obtain a 32-bit value
- stores that observed input in `inputObs`
- checks whether it equals `0x11223344`

This is the explicit connectivity test for the host-to-kernel input path.

### 4. Kernel runs all Serializer tests

The kernel state machine then runs the module tests in order:

1. `mkSerializer`
2. `mkDeSerializer`
3. `mkStreamReplicate`
4. `mkStreamSerializeLast`
5. `mkStreamSkip`
6. `mkPipelineShiftRight`
7. `mkSerializerFreeform`

For `mkSerializer` and `mkDeSerializer`, the kernel uses the host-provided word from port 0.
For the other modules, the kernel uses fixed internal test vectors.

### 5. Kernel packs results into one 512-bit word

After all tests finish, the kernel writes one result word to `boOut` through memory port 1.

### 6. Host reads and checks the result word

The host reads back the first 512-bit output word, prints all observed values, checks each pass bit, and reports:

- `TEST PASSED` if everything matches
- `TEST FAILED` otherwise

---

## Output word format

The first 512-bit word of `boOut` is interpreted as 16 lanes of 32 bits.

| Lane | Meaning |
|---|---|
| 0 | magic = `0x53524C5A` (`'SRLZ'`) |
| 1 | status (`3` means overall PASS) |
| 2 | `passMask` |
| 3 | elapsed cycles |
| 4 | observed result from `mkSerializer` |
| 5 | observed result from `mkDeSerializer` |
| 6 | observed result from `mkStreamReplicate` |
| 7 | observed result from `mkStreamSerializeLast` |
| 8 | observed result from `mkStreamSkip` |
| 9 | low 32 bits of `mkPipelineShiftRight` result |
| 10 | high 32 bits of `mkPipelineShiftRight` result |
| 11 | observed result from `mkSerializerFreeform` |
| 12 | input word observed by the kernel |
| 13 | input-path pass flag (`1` if lane 12 is `0x11223344`) |
| 14 | reserved / zero |
| 15 | reserved / zero |

---

## Meaning of `passMask`

`passMask` is a 7-bit summary of the Serializer module checks.

| Bit | Module |
|---|---|
| 0 | `mkSerializer` |
| 1 | `mkStreamReplicate` |
| 2 | `mkStreamSerializeLast` |
| 3 | `mkDeSerializer` |
| 4 | `mkStreamSkip` |
| 5 | `mkPipelineShiftRight` |
| 6 | `mkSerializerFreeform` |

If all module tests pass, then:

- `passMask = 0x7F`

The final `status` is set to:

- `3` if **all module tests pass** and the **input connectivity test passes**
- otherwise `0xBAD00000 | passMask`

---

## Expected results

When the design works correctly, the host should observe:

- host input written by software: `0x11223344`
- host input observed by kernel: `0x11223344`
- input-path pass flag: `1`
- `mkSerializer` -> `0x11223344`
- `mkDeSerializer` -> `0x11223344`
- `mkStreamReplicate` -> `0x00A6A6A6`
- `mkStreamSerializeLast` -> `0x00000001`
- `mkStreamSkip` -> `0x0000A2B2`
- `mkPipelineShiftRight` -> `0x000FEDCBA9876543`
- `mkSerializerFreeform` -> `0x2B79536C`
- `passMask` -> `0x0000007F`
- `status` -> `0x00000003`

---

## Why this version is useful

This version is more informative than a kernel-only self-test because it validates both:

- the **functional behavior** of all Serializer package modules
- the **actual memory connectivity path** from host software into the kernel through the URAM-mapped PLRAM-backed input buffer

It also makes the PLRAM configuration easier to understand:

- the U50 platform exposes PLRAM banks as on-chip scratchpad memory
- this example remaps the selected banks from **BRAM-backed PLRAM** to **URAM-backed PLRAM**
- the self-test proves the data path using a small, deterministic 64-byte transaction

That makes it a good bring-up example for confirming that both the kernel logic and the memory plumbing are working.
