# Serializer Self-Test over URAM-Mapped PLRAM

This example validates the `Serializer.bsv` package inside `kernel_example_add_plram_uram` while also checking the host-to-kernel memory path over **URAM-mapped PLRAM** on the Alveo U50.

It keeps the original bluevitis/XRT flow, but replaces the original add-style computation with a kernel-internal self-test for the Serializer package.

The host writes a known 32-bit value into the input BO, the kernel reads that value from PLRAM, runs a sequence of Serializer-related tests, packs the observations into one 512-bit result word, and writes that result back to the output BO.

---

## What this example tests

This example checks two things at once:

1. **Serializer package functionality**
   - `mkSerializer`
   - `mkDeSerializer`
   - `mkStreamReplicate`
   - `mkStreamSerializeLast`
   - `mkStreamSkip`
   - `mkPipelineShiftRight`
   - `mkSerializerFreeform`

2. **URAM-mapped PLRAM connectivity**
   - the host writes `0x11223344` into `boIn[0]`
   - the kernel issues a read on **memory port 0**
   - the kernel receives the first 512-bit word from the input BO
   - lane 0 of that word becomes the serializer / deserializer test vector
   - the kernel writes one packed result word back through **memory port 1**

So this is not only a logic self-test.
It also confirms that the host ↔ PLRAM(URAM) ↔ kernel memory path is correctly wired.

---

## Understanding the URAM-mapped PLRAM in this design

This example is intentionally built on top of a **PLRAM-backed kernel interface**, but the selected PLRAM banks are reconfigured to use **UltraRAM (URAM)** instead of the default block RAM implementation.

### Connectivity used by this example

The build configuration maps the two kernel memory ports as follows:

- `kernel_1.in -> PLRAM[0]`
- `kernel_1.out -> PLRAM[1]`

So, in practical terms:

- the **input buffer object** is attached to `PLRAM[0]`
- the **output buffer object** is attached to `PLRAM[1]`

Inside `KernelTop.bsv`, memory port 0 is the input path and memory port 1 is the output path, so the BO-to-port relationship is direct.

### PLRAM configuration used by this example

The file `scripts/plram_uram.tcl` updates the two PLRAM banks used by the kernel:

#### `PLRAM_MEM00`
- `SIZE 128K`
- `AXI_DATA_WIDTH 512`
- `SLR_ASSIGNMENT SLR0`
- `READ_LATENCY 1`
- `MEMORY_PRIMITIVE URAM`

#### `PLRAM_MEM01`
- `SIZE 128K`
- `AXI_DATA_WIDTH 512`
- `SLR_ASSIGNMENT SLR0`
- `READ_LATENCY 1`
- `MEMORY_PRIMITIVE URAM`

So, in practical terms:

- the **input PLRAM bank** is **128 KB = 131,072 bytes**
- the **output PLRAM bank** is **128 KB = 131,072 bytes**
- both are configured as **URAM-backed PLRAM**
- both expose a **512-bit AXI data path**

### How much memory does the example actually touch?

The configured PLRAM capacity is much larger than what this self-test needs.

In the current example:

- the host allocates **4096 bytes** for `boIn`
- the host allocates **4096 bytes** for `boOut`
- the kernel reads only the **first 64 bytes** from the input BO
- the kernel writes only the **first 64 bytes** to the output BO

That means this example is **not trying to fill the entire 128 KB PLRAM bank**.
It is a minimal functional test of a URAM-backed PLRAM memory path.

This is useful for bring-up because it isolates connectivity from bandwidth or capacity testing:

- if the kernel reads back `0x11223344`, the host-to-PLRAM-to-kernel path works
- if the kernel writes the packed result word correctly, the kernel-to-PLRAM-to-host path works

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

Output stream:

- `0xA6`
- `0xA6`
- `0xA6`

### `mkStreamSerializeLast`

Expands one frame-level `last` flag into one flag per beat.

In this example:

- input flag = `True`
- `framesize = 4`

Output stream:

- `False`
- `False`
- `False`
- `True`

### `mkStreamSkip`

Keeps only one element from each fixed-size frame and discards the others.

In this example:

- `framesize = 4`
- `offset = 2`

Input stream:

- frame 0: `A0 A1 A2 A3`
- frame 1: `B0 B1 B2 B3`

Output stream:

- `A2`
- `B2`

### `mkPipelineShiftRight`

Performs a variable right shift using a bit-sliced deep pipeline.

In this example:

- input value = `0xFEDCBA9876543210`
- shift amount = `12`

Expected output:

- `0x000FEDCBA9876543`

### `mkSerializerFreeform`

Repackages a wider stream into a narrower stream even when the widths are not an integer multiple.

In this example:

- input width = 10 bits
- output width = 6 bits
- inputs = `0x3AB`, `0x155`, `0x2C3`

Expected five outputs:

- `0x2B`
- `0x1E`
- `0x15`
- `0x0D`
- `0x2C`

These are packed into the observed 30-bit value:

- `0x2B79536C`

---

## End-to-end flow of the example

### 1. Host prepares buffers

The host allocates:

- `boIn` for the input memory path
- `boOut` for the output/result memory path

Then it writes:

- `boIn[0] = 0x11223344`

This becomes lane 0 of the first 512-bit input word seen by the kernel.

### 2. Host launches the kernel

The host launches the kernel with the usual ABI:

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

This is the explicit connectivity test for the URAM-backed input path.

### 4. Kernel runs all Serializer tests

The kernel state machine then runs the module tests in order:

1. `mkSerializer`
2. `mkDeSerializer`
3. `mkStreamReplicate`
4. `mkStreamSerializeLast`
5. `mkStreamSkip`
6. `mkPipelineShiftRight`
7. `mkSerializerFreeform`

Some modules use the host-provided input word, while others use built-in fixed test vectors.

### 5. Kernel packs the result

After all tests complete, the kernel packs the observations into one 512-bit result word.

The packed word includes:

- a magic value
- overall status
- pass mask
- cycle count
- each module's observed output
- the observed input word
- the input-path pass flag

### 6. Kernel writes the result to port 1

The kernel issues a **64-byte write request** on memory port 1 and writes the single result word back to the output BO.

### 7. Host reads the result and checks pass/fail

The host:

- syncs `boOut` back from device memory
- unpacks the first result word
- verifies the observed values against the expected values
- checks that the input path really delivered `0x11223344`
- prints `TEST PASSED` only if the connectivity check and all module checks succeed

---

## Output word format

The kernel writes one 512-bit output word, interpreted as **16 lanes of 32 bits**.

| Lane | Meaning |
|---|---|
| 0 | magic = `0x53524C5A` (`'SRLZ'`) |
| 1 | status (`3` means overall PASS) |
| 2 | pass mask |
| 3 | elapsed cycles |
| 4 | observed result from `mkSerializer` |
| 5 | observed result from `mkDeSerializer` |
| 6 | observed result from `mkStreamReplicate` |
| 7 | observed result from `mkStreamSerializeLast` |
| 8 | observed result from `mkStreamSkip` |
| 9 | low 32 bits of `mkPipelineShiftRight` |
| 10 | high 32 bits of `mkPipelineShiftRight` |
| 11 | observed result from `mkSerializerFreeform` |
| 12 | input word observed by the kernel |
| 13 | input-path pass flag |
| 14 | zero |
| 15 | zero |

---

## Expected results

### Input-path check

- host writes `0x11223344`
- kernel should observe `0x11223344`
- input-path pass flag should be `1`

### Serializer package observations

- `mkSerializer`          -> `0x11223344`
- `mkDeSerializer`        -> `0x11223344`
- `mkStreamReplicate`     -> `0x00A6A6A6`
- `mkStreamSerializeLast` -> `0x00000001`
- `mkStreamSkip`          -> `0x0000A2B2`
- `mkPipelineShiftRight`  -> `0x000FEDCBA9876543`
- `mkSerializerFreeform`  -> `0x2B79536C`

### Overall pass condition

- `status   = 3`
- `passMask = 0x7F`

---

## Files involved

### Hardware

- `hw/kernel_example_add_plram_uram/KernelTop.bsv`
- `hw/kernel_example_add_plram_uram/KernelMain.bsv`
- `hw/kernel_example_add_plram_uram/u50.cfg`
- `hw/kernel_example_add_plram_uram/scripts/plram_uram.tcl`
- `bluelibrary/bsv/Serializer.bsv`

### Software

- `sw/host_example_add_plram_uram/main.cpp`

---

## Why this example is useful

This example is intentionally small, but it demonstrates several useful things at once:

- how to use URAM-backed PLRAM instead of the platform default BRAM-backed PLRAM
- how to connect bluevitis kernel ports to PLRAM banks
- how to read one AXI memory beat into Bluespec logic
- how to validate a group of Serializer-related modules with fixed test vectors
- how to verify the host-to-kernel memory path using a known input word
- how to return a compact pass/fail report to the host

It is a good starting point for larger scratchpad-style kernels where:

- host software preloads on-card memory
- the kernel consumes data from URAM-backed PLRAM
- multiple small datapath components need quick bring-up validation
- and results are written back through a second PLRAM-connected port
