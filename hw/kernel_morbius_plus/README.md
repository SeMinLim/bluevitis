# Morbius+ U50 Hardware

This directory contains the blueVitis-compatible Morbius+ RTL kernel for the Alveo U50. The kernel uses the direct `HOST[0]` connection and retains sixteen independent Gibbs search states on chip.

## Prototype configuration

- `NumPipeline = 16`
- `NumPE_Profiler = 32`
- `NumPE_LPM = 4`
- `PWL lanes = 32`
- `ACCELSEGMENTSIZE = 32` in the matching host model
- maximum sequence length: 1024 symbols
- maximum motif length: 128 symbols
- maximum alphabet size: 20 symbols
- target clock: 250 MHz

## Resource-oriented microarchitecture

- one shared controller advances sixteen independent Gibbs states
- two common 32-symbol Profiler window providers serve the sixteen searches; pipeline-specific motif reads return four symbols
- packed 5-bit sequence rows use staged bounded window selection
- BPM and tentative-motif state use explicit block RAM
- LPM uses symbol-banked RAMB36E2 with masked four-entry writes and one-column reads
- one vector PWL array per Gibbs state contains eight log/exp lanes and twenty-four exp-only lanes with narrowed internal messages
- paired 24-bit Profiler additions use DSP48E2 TWO24 without changing accumulator feedback latency
- Phase 2 reuses one weight reduction tree and performs streaming weighted-reservoir sampling
- tentative-motif insertion and complete-state score calculation share one pass
- the input and output ports use specialized burst read and burst write masters

The 32-candidate segment has a 24-bit mass and a 48-bit local sampling product.
Profiler window providers use two adjacent 32-symbol rows, including unaligned windows;
pipeline-specific motif memories retain their four-symbol access path.
The host model uses the same 32-candidate segment size. Rebuild both host and xclbin.
Changing the segment width changes random-number consumption and fixed-point grouping,
so an identical seed need not reproduce the former 16-lane result.

## Standalone BSV test

```bash
make sim
```

## U50 build

```bash
make all TARGET=hw_emu
make run TARGET=hw_emu MORBIUS_ARGS="--input /path/to/input.fa --output output/result --alphabet dna --motif-length 16 --max-updates 32768 --score-threshold 1.0 --seed 1"
```

For the physical U50:

```bash
xbutil configure --device <BDF> --host-mem --size 1G enable
make all TARGET=hw
make run TARGET=hw MORBIUS_ARGS="--input /path/to/input.fa --output output/result --alphabet dna --motif-length 16 --max-updates 32768 --score-threshold 1.0 --seed 1"
```
