# BLShifter Self-Test over PLRAM / BRAM

This example turns `kernel_example_add_plram_bram` into a compact BLShifter validation kernel for the Alveo U50.

It keeps the original bluevitis/XRT structure and also keeps the original two-port PLRAM-backed memory pattern:

* memory port 0 reads the input data vector
* memory port 1 reads the shift-amount vector
* memory port 1 writes the packed BLShifter results back to memory

The example is intentionally small, but more comprehensive than a single-vector smoke test. The host prepares `TEST_CNT` vectors, the kernel reads one 512-bit beat from each input port per test, feeds eight BLShifter instances in parallel, and writes one 512-bit packed result beat back through port 1.

* * *

## What this example tests

This example checks several things at once:

1. BLShifter module functionality

   * left shift and right shift
   * `shiftsz=6, shift_bits_per_stage=1`
   * `shiftsz=6, shift_bits_per_stage=2`
   * `shiftsz=6, shift_bits_per_stage=6`
   * `shiftsz=5, shift_bits_per_stage=2`

2. PLRAM-backed kernel memory connectivity

   * the host writes input data to memory port 0
   * the host writes shift amounts to memory port 1
   * the kernel issues reads on memory port 0 and memory port 1
   * the kernel consumes the lower 64 bits from each returned 512-bit word
   * the kernel writes one packed 512-bit result word back through memory port 1

3. Scalar control path functionality

   * `scalar00` is used as `TEST_CNT`
   * `KernelTop.bsv` relays `scalar00` into `KernelMain.start(...)`
   * `KernelMain.bsv` uses that value as the number of test vectors to process

So this is not just a BLShifter logic demo. It also confirms that the host ↔ PLRAM ↔ kernel control/data path is correctly wired.

* * *

## Understanding the PLRAM-backed memory path in this design

This example is intentionally built on top of the PLRAM-backed kernel interface provided by the U50 platform.

### Connectivity used by this example

The build configuration maps the two kernel memory ports as follows:

* `kernel_1.in -> PLRAM[0]`
* `kernel_1.out -> PLRAM[1]`

So, in practical terms:

* the input buffer object is attached to the PLRAM-backed input path on port 0
* the second buffer object is attached to the PLRAM-backed port 1 path
* that same port 1 path is used twice in this example:
  * first as the shift-amount input source
  * later as the result destination

Inside `KernelTop.bsv`, these are the same two memory ports exposed to `KernelMain`.

### Kernel argument mapping

The kernel ABI remains:

* `scalar00` : test count
* `mem`      : input BO on port `in`
* `file`     : BO on port `out`

This means the host still launches the kernel with the usual three-argument form:

* scalar argument
* input BO (`mem`, port 0)
* second BO (`file`, port 1)

* * *

## How much memory does the example actually touch?

The host allocates:

* `TEST_CNT * 64` bytes for `boIn`
* `TEST_CNT * 64` bytes for `boOut`

With the default setting:

* `TEST_CNT = 16`
* each BO is `1024` bytes

For each test vector:

* port 0 supplies one 512-bit beat whose lower 64 bits are used as the input data
* port 1 supplies one 512-bit beat whose lower 64 bits are used as the shift amount
* the kernel writes one 512-bit result beat back to port 1

This is still a compact functional test. It is not intended as a bandwidth benchmark. It is meant to validate module behavior and PLRAM connectivity with a clear and repeatable memory pattern.

* * *

## Module behavior summary

### `mkPipelinedShift(False)`

This instance performs left shift on the input data.

### `mkPipelinedShift(True)`

This instance performs right shift on the input data.

In this example, the kernel instantiates eight BLShifter paths in parallel:

1. left shift,  `shiftsz=6`, `shift_bits_per_stage=1`
2. right shift, `shiftsz=6`, `shift_bits_per_stage=1`
3. left shift,  `shiftsz=6`, `shift_bits_per_stage=2`
4. right shift, `shiftsz=6`, `shift_bits_per_stage=2`
5. left shift,  `shiftsz=6`, `shift_bits_per_stage=6`
6. right shift, `shiftsz=6`, `shift_bits_per_stage=6`
7. left shift,  `shiftsz=5`, `shift_bits_per_stage=2`
8. right shift, `shiftsz=5`, `shift_bits_per_stage=2`

The last pair is especially useful because it exercises the partial last-stage case.

* * *

## End-to-end flow of the example

### 1. Host prepares buffers

The host allocates:

* `boIn` for input data on port 0
* `boOut` for shift input on port 1 and final result on port 1

Then it writes:

* one 64-bit input data value into lane 0 of each 512-bit word in `boIn`
* one 64-bit shift value into lane 0 of each 512-bit word in `boOut`

Only lane 0 is used on input. All remaining lanes are zero.

### 2. Host launches the kernel

The host launches the kernel with:

* `scalar00 = TEST_CNT`
* input BO (`mem`, port 0)
* second BO (`file`, port 1)

### 3. Kernel reads input data from port 0

Inside `KernelMain.bsv`, the kernel:

* issues 64-byte read requests on memory port 0
* receives one 512-bit word per test vector
* truncates each word to its lower 64 bits
* uses that 64-bit value as the BLShifter input data

### 4. Kernel reads shift amounts from port 1

The kernel:

* issues 64-byte read requests on memory port 1
* receives one 512-bit word per test vector
* truncates each word to its lower 64 bits
* uses that value as the shift amount source
* derives:
  * `shift6 = truncate(y)`
  * `shift5 = truncate(y)`

### 5. Kernel runs eight BLShifter instances

For every test vector, the same input data is fed into eight BLShifter instances with different parameterizations and directions.

### 6. Kernel packs the result

The kernel packs the eight 64-bit results into one 512-bit output word in this order:

* lane 0 = `L(6,1)`
* lane 1 = `R(6,1)`
* lane 2 = `L(6,2)`
* lane 3 = `R(6,2)`
* lane 4 = `L(6,6)`
* lane 5 = `R(6,6)`
* lane 6 = `L(5,2)`
* lane 7 = `R(5,2)`

### 7. Kernel writes the result to port 1

The kernel issues 64-byte write requests on memory port 1 and writes the packed result words back to `boOut`.

This means the original shift input buffer on port 1 is intentionally overwritten by the final results.

### 8. Host reads the result and compares against software

The host:

* syncs `boOut` back from device memory
* computes software reference results locally using C++ shift operators
* compares all eight hardware results against the software golden model for every test vector
* reports `TEST PASSED` only if every lane of every vector matches

* * *

## Input word format

### Port 0 input word (`mem`)

One 512-bit input beat per test vector:

* lane 0 `[63:0]` : input data
* lane 1~7        : unused / zero

### Port 1 input word (`file`, before kernel writes results)

One 512-bit input beat per test vector:

* lane 0 `[63:0]` : shift amount
* lane 1~7        : unused / zero

* * *

## Output word format

The kernel writes one 512-bit output word per test vector to port 1.

Lane mapping:

* lane 0 : left shift  (`shiftsz=6`, `shift_bits_per_stage=1`)
* lane 1 : right shift (`shiftsz=6`, `shift_bits_per_stage=1`)
* lane 2 : left shift  (`shiftsz=6`, `shift_bits_per_stage=2`)
* lane 3 : right shift (`shiftsz=6`, `shift_bits_per_stage=2`)
* lane 4 : left shift  (`shiftsz=6`, `shift_bits_per_stage=6`)
* lane 5 : right shift (`shiftsz=6`, `shift_bits_per_stage=6`)
* lane 6 : left shift  (`shiftsz=5`, `shift_bits_per_stage=2`)
* lane 7 : right shift (`shiftsz=5`, `shift_bits_per_stage=2`)

* * *

## Test vectors used by the host

The host uses `TEST_CNT = 16` vectors.

The default input data set includes:

* single-bit values
* all-ones / all-high-bit patterns
* alternating-bit patterns
* structured hexadecimal patterns
* values that make large shifts easy to inspect

The default shift set includes:

* small shifts: `0` to `7`
* mid-range shifts: `15`, `31`, `32`, `33`
* large shifts: `47`, `48`, `62`, `63`

For the `shiftsz=5` cases, the host naturally verifies against `shift & 0x1F`.
For the `shiftsz=6` cases, the host verifies against `shift & 0x3F`.

* * *

## Files involved

### Hardware

* `hw/kernel_example_add_plram_bram/KernelTop.bsv`
* `hw/kernel_example_add_plram_bram/KernelMain.bsv`
* `hw/kernel_example_add_plram_bram/u50.cfg`
* `bluelibrary/bsv/BLShifter.bsv`

### Software

* `sw/host_example_add_plram_bram/main.cpp`

* * *

## Why this example is useful

This example is intentionally small, but it demonstrates several useful things at once:

* how to keep the original bluevitis two-port PLRAM structure
* how to read independent input streams from two AXI memory ports
* how to use `scalar00` as a meaningful control value (`TEST_CNT`)
* how to test multiple Bluespec module parameterizations in a single kernel run
* how to pack several 64-bit hardware results into one 512-bit output word
* how to validate hardware behavior against a software golden model

It is a good starting point for larger PLRAM-backed kernels where:

* different inputs arrive on different ports
* several parameterized compute paths run in parallel
* and compact packed results are written back to host-visible memory
