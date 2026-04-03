# Serializer Package and Self-Test Example

This repository includes a `Serializer` package and a compact kernel-level self-test example for validating all of its main modules on hardware.

The example is designed to run inside `hw/kernel_example_add_plram_uram` by replacing `KernelMain.bsv` and the host `main.cpp`. The kernel executes a sequence of functional checks, packs the observed results into one 512-bit word, and writes that word back to host memory. The host program reads the result word, decodes it, and prints a per-module pass/fail summary.

---

## 1. Modules in `Serializer.bsv`

### `mkSerializer`
`mkSerializer` splits one wide input word into multiple narrower output words.

- Interface: `SerializerIfc#(srcSz, multiplier)`
- Input width: `srcSz`
- Output width: `srcSz / multiplier`
- Behavior:
  - `put()` accepts one `srcSz`-bit word.
  - `get()` returns the serialized chunks in little-endian slice order, starting from the least-significant bits.

Example:
- `mkSerializer(32, 4)` converts one 32-bit word into four 8-bit outputs.
- Input: `0x11223344`
- Output sequence: `0x44`, `0x33`, `0x22`, `0x11`

---

### `mkDeSerializer`
`mkDeSerializer` performs the inverse operation of `mkSerializer`.

- Interface: `DeSerializerIfc#(srcSz, multiplier)`
- Input width: `srcSz`
- Output width: `srcSz * multiplier`
- Behavior:
  - `put()` accepts one narrow word at a time.
  - After `multiplier` inputs are collected, `get()` returns one reconstructed wide word.

Example:
- `mkDeSerializer(8, 4)` converts four 8-bit inputs into one 32-bit output.
- Input sequence: `0x44`, `0x33`, `0x22`, `0x11`
- Output: `0x11223344`

---

### `mkStreamReplicate`
`mkStreamReplicate` repeats each input element a fixed number of times.

- Interface: `FIFO#(dtype)`
- Parameter: `framesize`
- Behavior:
  - For every input element, the same value is emitted `framesize` times.

Example:
- `mkStreamReplicate(3)`
- Input: `0xA6`
- Output sequence: `0xA6`, `0xA6`, `0xA6`

---

### `mkStreamSerializeLast`
`mkStreamSerializeLast` expands a per-frame boolean flag into a stream where only the last element of the frame carries the flag value.

- Interface: `FIFO#(Bool)`
- Parameter: `framesize`
- Behavior:
  - For each input flag, the output frame has length `framesize`.
  - The first `framesize - 1` outputs are `False`.
  - The last output is the original input flag.

Example:
- `mkStreamSerializeLast(4)`
- Input: `True`
- Output sequence: `False`, `False`, `False`, `True`

---

### `mkStreamSkip`
`mkStreamSkip` forwards exactly one element per frame and drops the rest.

- Interface: `FIFO#(dtype)`
- Parameters:
  - `framesize`
  - `offset`
- Behavior:
  - Within each frame of length `framesize`, only the element at index `offset` is forwarded.

Example:
- `mkStreamSkip(4, 2)`
- Input frame: `[A0, A1, A2, A3]`
- Output: `A2`

---

### `mkPipelineShiftRight`
`mkPipelineShiftRight` implements a right shifter using a bit-sliced deep pipeline.

- Interface: `PipelineShiftIfc#(sz, shiftsz)`
- Behavior:
  - `put(v, shift)` inserts a value and shift amount.
  - `get()` returns `v >> shift` after the pipeline latency.
- Design intent:
  - The shift amount is processed stage by stage, one bit per stage.
  - This avoids a single large combinational variable shifter and is more suitable for timing closure at larger widths.

Example:
- Input: `0xFEDCBA9876543210`, shift = `12`
- Output: `0x000FEDCBA9876543`

---

### `mkSerializerFreeform`
`mkSerializerFreeform` converts a stream between arbitrary source and destination widths, even when the widths are not integer multiples of each other.

- Interface: `SerializerFreeformIfc#(srcSz, dstSz)`
- Behavior:
  - `put()` accepts `srcSz`-bit words.
  - `get()` emits `dstSz`-bit words whenever enough bits are available.
  - Internally, it uses a buffered packing/unpacking strategy plus `mkPipelineShiftRight`.

Example used in the self-test:
- `mkSerializerFreeform(10, 6)`
- Input words: `3AB`, `155`, `2C3`
- Output words: `2B`, `1E`, `15`, `0D`, `2C`
- Packed observation: `0x2B79536C`

---

## 2. How the self-test example works

The example kernel instantiates all major modules in `Serializer.bsv` and tests them one by one using a simple state machine.

### Tested modules
The self-test covers:

1. `mkSerializer`
2. `mkStreamReplicate`
3. `mkStreamSerializeLast`
4. `mkDeSerializer`
5. `mkStreamSkip`
6. `mkPipelineShiftRight`
7. `mkSerializerFreeform`

A 7-bit `passMask` is used to record which module checks passed.

- bit 0: `mkSerializer`
- bit 1: `mkStreamReplicate`
- bit 2: `mkStreamSerializeLast`
- bit 3: `mkDeSerializer`
- bit 4: `mkStreamSkip`
- bit 5: `mkPipelineShiftRight`
- bit 6: `mkSerializerFreeform`

---

## 3. End-to-end test flow

### Step 1: Start the kernel
The host launches the kernel as usual:

```cpp
auto run = krnl(0u, boIn, boOut);
run.wait();
```

The demo keeps the original kernel ABI, so two buffer arguments are still passed (`mem` and `file`), even though only the output buffer is used by this test.

---

### Step 2: Run module tests inside the kernel
Inside `KernelMain.bsv`, the kernel performs the following sequence:

#### A. `mkSerializer`
- Input: `0x11223344`
- Expected serialized bytes: `44, 33, 22, 11`
- Repacked observation: `0x11223344`

#### B. `mkDeSerializer`
- The same serialized bytes are fed into `mkDeSerializer`
- Expected reconstructed value: `0x11223344`

#### C. `mkStreamReplicate`
- Input: `0xA6`
- Expected output stream: `A6, A6, A6`
- Packed observation: `0x00A6A6A6`

#### D. `mkStreamSerializeLast`
- Input: `True`
- Frame size: `4`
- Expected output: `0, 0, 0, 1`
- Packed observation: `0x00000001`

#### E. `mkStreamSkip`
- Frame size: `4`, offset: `2`
- Inputs: `A0, A1, A2, A3, B0, B1, B2, B3`
- Expected forwarded outputs: `A2, B2`
- Packed observation: `0x0000A2B2`

#### F. `mkPipelineShiftRight`
- Input: `0xFEDCBA9876543210`
- Shift amount: `12`
- Expected output: `0x000FEDCBA9876543`

#### G. `mkSerializerFreeform`
- Source width: `10`
- Destination width: `6`
- Inputs: `0x3AB`, `0x155`, `0x2C3`
- Expected outputs: `0x2B`, `0x1E`, `0x15`, `0x0D`, `0x2C`
- Packed observation: `0x2B79536C`

---

### Step 3: Pack the results into one 512-bit word
After all checks complete, the kernel writes one 512-bit result word to output memory.

The result word is organized as sixteen 32-bit lanes:

| Lane | Meaning |
|------|---------|
| 0 | magic = `0x53524C5A` (`'SRLZ'`) |
| 1 | status (`3` means PASS) |
| 2 | passMask |
| 3 | elapsed cycles |
| 4 | serializer observation |
| 5 | deserializer observation |
| 6 | replicate observation |
| 7 | serialize-last observation |
| 8 | skip observation |
| 9 | shift result low 32 bits |
| 10 | shift result high 32 bits |
| 11 | freeform observation |
| 12-15 | zero |

If every test passes, the kernel sets:

```text
status = 3
passMask = 0x7F
```

Otherwise, `status` is set to `0xBAD00000 | passMask`.

---

## 4. Host-side output interpretation

The host program reads the first 512-bit output word and decodes it into scalar values:

- `magic`
- `status`
- `passMask`
- `cycles`
- one observed value per tested module

It then compares each observed value with the expected golden value and prints `OK` or `FAIL` for each module.

Expected values:

| Module | Expected value |
|--------|----------------|
| `mkSerializer` | `0x11223344` |
| `mkDeSerializer` | `0x11223344` |
| `mkStreamReplicate` | `0x00A6A6A6` |
| `mkStreamSerializeLast` | `0x00000001` |
| `mkStreamSkip` | `0x0000A2B2` |
| `mkPipelineShiftRight` | `0x000FEDCBA9876543` |
| `mkSerializerFreeform` | `0x2B79536C` |

The host prints `TEST PASSED` only when:

- `magic == 0x53524C5A`, and
- `status == 3`

---

## 5. Files used in the demo

- `Serializer.bsv` — serializer/deserializer utility modules
- `KernelMain.bsv` — hardware self-test state machine
- `main.cpp` — XRT host application that launches the kernel and decodes the result word

---

## 6. Notes

- The demo is intended as a **functional hardware self-test**, not a throughput benchmark.
- `mkPipelineShiftRight` is intentionally kept as a **deep pipelined shifter**, because that structure is more realistic for wider datapaths and tighter timing goals.
- The self-test writes only one 512-bit word, so the host-side logic stays simple and easy to inspect.
