# CRC32 / CRC32C HBM Example for bluevitis (U50)

## Overview

This example turns the original `add_hbm` sample into a minimal **CRC test kernel** for **Xilinx Alveo U50**.

The example does the following:

- reads one 512-bit word from the input memory port
- takes the lower 64 bits (`bits[63:0]`) as the 8-byte test payload
- computes:
  - `CRC32`
  - `CRC32C`
- uses **two separate 2-stage Bluespec modules**:
  - `mkCRC32`
  - `mkCRC32C`
- writes the result back to the output memory port

The software host writes the ASCII string:

```text
"12345678"
```

into the input buffer, launches the kernel, reads the output buffer, and compares the hardware result against a software reference.

---

## What changed from the original example?

The original `add_hbm` example was a simple memory read / compute / memory write example.
This version keeps the same overall bluevitis/XRT flow, but replaces the kernel-side computation with CRC logic.

### Hardware-side changes

- `KernelMain.bsv` now:
  - reads one 512-bit word from input memory
  - extracts `Bit#(64)` from `truncate(inWord)`
  - sends the 64-bit payload to:
    - `mkCRC32`
    - `mkCRC32C`
  - waits for both responses
  - packs the result as:

```text
[31:0]   = CRC32
[63:32]  = CRC32C
```

- `CRC32.bsv` provides:
  - `crc32_update_32_reflected`
  - `crc32c_update_32_reflected`
  - 2-stage wrapper modules:
    - `interface CRC32Ifc`, `module mkCRC32`
    - `interface CRC32CIfc`, `module mkCRC32C`

### Software-side changes

- `main.cpp` now:
  - prepares the fixed input `"12345678"`
  - computes software reference values using two 32-bit reflected update steps
  - launches the kernel
  - reads back hardware CRC32 / CRC32C
  - prints `TEST PASSED` if they match

---

## Why HBM is still important in this example

Even though the payload is tiny, this example is intentionally kept on the **HBM-backed memory path** so that it remains a realistic **memory-connected kernel example** for the Alveo U50 flow.

### Memory ports in hardware

`KernelTop.bsv` exposes two AXI memory master ports:

- `in`
- `out`

These correspond to the kernel-side input and output memory channels.

### HBM connectivity on U50

The U50 build config (`u50.cfg`) maps the kernel ports onto HBM resources:

```ini
[connectivity]
nk=kernel:1:kernel_1
sp=kernel_1.in:HBM[0:1]
sp=kernel_1.out:HBM[2:3]
```

That means:

- the kernel input port is connected to HBM pseudo-channels in `HBM[0:1]`
- the kernel output port is connected to HBM pseudo-channels in `HBM[2:3]`

So the example is not just “a CRC toy example”; it is also a compact demonstration of:

- bluevitis hardware packaging
- AXI memory master connectivity
- XRT buffer allocation
- HBM-backed kernel I/O on U50

---

## High-level dataflow

```text
Host main.cpp
   |
   | writes 64B input buffer (contains "12345678" in the first 8 bytes)
   v
HBM-backed input BO
   |
   v
kernel_1.in
   |
   v
KernelMain.bsv
   |
   |-- read one 512b word
   |-- truncate to lower 64b
   |-- send to mkCRC32
   |-- send to mkCRC32C
   |-- wait for both responses
   |-- pack results into one 512b output word
   v
kernel_1.out
   |
   v
HBM-backed output BO
   |
   v
Host main.cpp compares HW vs SW
```

---

## CRC processing model

Both CRC engines use the same 64-bit payload, but they are implemented as **two independent 2-stage modules**.

### Stage split

Each module processes 64 bits as:

1. lower 32 bits
2. upper 32 bits

That is, for CRC32:

```text
mid  = crc32_update_32_reflected(init, lo32)
out  = crc32_update_32_reflected(mid,  hi32)
```

and similarly for CRC32C.

This avoids relying on a single large 64-bit CRC combinational block and better matches the recommended staged implementation style.

---

## Expected test vector

Input bytes:

```text
"12345678"
```

Expected results:

```text
CRC32   = 0x651F2550
CRC32C  = 0x9F787F65
```

---

## Files involved

### Hardware

- `hw/kernel_example_add_hbm/KernelTop.bsv`
- `hw/kernel_example_add_hbm/KernelMain.bsv`
- `hw/kernel_example_add_hbm/u50.cfg`
- `bluelibrary/bsv/CRC32.bsv`

### Software

- `sw/host_example_add_hbm/main.cpp`

---

## KernelMain behavior (step by step)

1. Host starts the kernel through XRT.
2. Kernel issues one AXI read request on memory port 0.
3. Kernel receives one 512-bit word from input memory.
4. Kernel truncates that word to 64 bits.
5. Kernel sends the same 64-bit word to:
   - `mkCRC32`
   - `mkCRC32C`
6. Each module internally performs two 32-bit reflected CRC update steps.
7. Kernel waits for both outputs.
8. Kernel packs the results into a 512-bit output word.
9. Kernel writes that output word to memory port 1.
10. Host reads back the result and checks it.

---

## Host behavior (step by step)

1. Open the U50 device.
2. Load the `.xclbin`.
3. Create kernel handle `kernel:{kernel_1}`.
4. Allocate two BOs:
   - input BO
   - output BO
5. Write `"12345678"` into the first 8 bytes of the input BO.
6. Sync input BO to device.
7. Run the kernel.
8. Sync output BO from device.
9. Read back:
   - output bytes `[3:0]` as CRC32
   - output bytes `[7:4]` as CRC32C
10. Compare with software reference.

---

## Notes on endianness

This example assumes the same byte ordering in hardware and software reference paths:

- software loads the first 4 bytes as `lo32`
- software loads the next 4 bytes as `hi32`
- hardware truncates the 512-bit input and feeds the lower 64 bits into the CRC modules

As long as both sides use the same convention, the example is self-consistent.

---

## Why this is a useful example

This example is intentionally small, but it demonstrates several useful things at once:

- how to import and use Bluespec CRC functions through modules
- how to build a simple 2-stage datapath in Bluespec
- how to connect hardware memory ports through bluevitis
- how to run an HBM-connected kernel on U50 with XRT
- how to validate hardware results against a software golden model

It is a good starting point for larger packet-processing kernels where:

- small fixed-size payloads are read from memory,
- pre-processing is performed in stages,
- and results are written back through AXI/HBM.

---

## Suggested next steps

After this example works, natural follow-up steps are:

1. make input length configurable
2. support variable byte selection / byte mask CRC
3. pipeline the CRC modules further if timing requires it
4. move from a single 64-bit word to multi-word packet streams
5. integrate CRC into a larger packet classification or pattern-matching kernel

