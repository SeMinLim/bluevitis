# CRC32 / CRC32C Self-Test over HBM

This example turns `kernel_example_add_hbm` into a compact CRC validation kernel for the Alveo U50.

It keeps the original bluevitis/XRT structure, but replaces the original compute stage with two CRC engines:

- `mkCRC32`
- `mkCRC32C`

The example is intentionally small: the host writes a single 512-bit input beat, the kernel consumes only the lower 64 bits, computes two CRC variants, and writes one 512-bit result beat back to memory.

---

## What this example tests

This example checks two things at once:

1. **CRC module functionality**
   - `mkCRC32`
   - `mkCRC32C`

2. **HBM-backed kernel memory connectivity**
   - the host writes one 64-byte input buffer
   - the kernel issues a read on **memory port 0**
   - the kernel receives one 512-bit word from HBM
   - the kernel computes CRC32 and CRC32C from the lower 64 bits
   - the kernel writes the packed result back through **memory port 1**

So this is not just a CRC logic demo.
It also confirms that the host ↔ HBM ↔ kernel memory path is correctly wired.

---

## Understanding the HBM-backed memory path in this design

This example is intentionally built on top of the **HBM-backed kernel interface** provided by the U50 platform.

### Connectivity used by this example

The build configuration maps the two kernel memory ports as follows:

- `kernel_1.in -> HBM[0:1]`
- `kernel_1.out -> HBM[2:3]`

So, in practical terms:

- the **input buffer object** is attached to the HBM-connected input path on port 0
- the **output buffer object** is attached to the HBM-connected output path on port 1

Inside `KernelTop.bsv`, these are the same two memory ports exposed to `KernelMain`.

### How much memory does the example actually touch?

The host allocates **64 bytes** for the input BO and **64 bytes** for the output BO.

In the current example:

- the host writes the ASCII string `"12345678"` into the first 8 bytes of the input BO
- the remaining bytes in the first 512-bit beat are zero
- the kernel reads only the **first 64 bytes**
- the kernel writes only the **first 64 bytes**
- only the low 64 bits of the returned input beat are used for CRC computation

That means this example is **not a bandwidth test** and **not a large HBM capacity test**.
It is a minimal functional test of an HBM-connected kernel path.

---

## Module behavior summary

### `mkCRC32`

`mkCRC32` computes standard reflected CRC32 over a 64-bit payload using two 32-bit update steps.

In this example:

- initial CRC = `0xFFFFFFFF`
- the lower 32 bits of the payload are processed first
- the upper 32 bits are processed second

Conceptually:

```text
mid = crc32_update_32_reflected(init, lo32)
out = crc32_update_32_reflected(mid,  hi32)
```

### `mkCRC32C`

`mkCRC32C` works the same way, but uses the CRC32C reflected polynomial.

Conceptually:

```text
mid = crc32c_update_32_reflected(init, lo32)
out = crc32c_update_32_reflected(mid,  hi32)
```

The two modules are independent and are fed with the same 64-bit input word.

---

## End-to-end flow of the example

### 1. Host prepares buffers

The host allocates:

- `boIn` for the input memory path
- `boOut` for the output/result memory path

Then it writes:

- the ASCII bytes `"12345678"` into the first 8 bytes of `boIn`

This becomes the lower 64 bits of the first 512-bit input word seen by the kernel.

### 2. Host launches the kernel

The host launches the kernel with the usual ABI:

- scalar argument
- input BO (`mem`, port 0)
- output BO (`file`, port 1)

The scalar argument is unused in this example.

### 3. Kernel reads the input word from port 0

Inside `KernelMain.bsv`, the kernel:

- issues a **64-byte read request** on memory port 0
- waits for one 512-bit word to return
- truncates the word to its lower 64 bits
- uses that 64-bit payload as the CRC test vector

This is the explicit memory-read step for the HBM input path.

### 4. Kernel runs both CRC modules

The kernel sends the same 64-bit payload to:

1. `mkCRC32`
2. `mkCRC32C`

Each module processes the payload in two 32-bit reflected update steps and returns its final CRC result.

### 5. Kernel packs the result

The kernel combines the two CRC outputs into one 64-bit value:

- bits `[31:0]`   = `CRC32`
- bits `[63:32]`  = `CRC32C`

Then it zero-extends that packed value into a 512-bit result word.

### 6. Kernel writes the result to port 1

The kernel issues a **64-byte write request** on memory port 1 and writes the single result word back to the output BO.

### 7. Host reads the result and compares against software

The host:

- syncs `boOut` back from device memory
- reads back `CRC32` and `CRC32C`
- computes the software reference values locally
- reports `TEST PASSED` only if both hardware values match the software reference

---

## Output word format

The kernel writes one 512-bit output word.

Only the low 64 bits are used:

- bits `[31:0]`   = `CRC32`
- bits `[63:32]`  = `CRC32C`

All higher bits are zero.

---

## Expected test vector and expected results

### Input payload

```text
"12345678"
```

### Expected CRC values

- `CRC32  = 0x651F2550`
- `CRC32C = 0x9F787F65`

These are the values the host expects to read back from the output BO.

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

## Why this example is useful

This example is intentionally small, but it demonstrates several useful things at once:

- how to connect a bluevitis kernel to HBM-backed memory ports
- how to read one AXI memory beat into Bluespec logic
- how to build a simple staged compute path with two independent CRC modules
- how to return compact results to host memory
- how to validate hardware behavior against a software golden model

It is a good starting point for larger HBM-connected kernels where:

- fixed-size data is read from memory
- the computation is naturally staged
- and the result needs to be written back to host-visible memory
