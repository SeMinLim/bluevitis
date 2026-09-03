# Morbius+ U50 Hardware

This directory contains the blueVitis-compatible Morbius+ RTL kernel for the Alveo U50. The kernel uses the direct `HOST[0]` connection and retains sixteen independent Gibbs search states on chip.

## Prototype configuration

- `NumPipeline = 16`
- `NumPE_Profiler = 16`
- `NumPE_LPM = 4`
- maximum sequence length: 1024 symbols
- maximum motif length: 128 symbols
- maximum alphabet size: 20 symbols
- target clock: 250 MHz

## Resource-oriented microarchitecture

- one shared controller advances sixteen independent Gibbs states
- packed 5-bit sequence rows and bounded 16-symbol windows replace wide variable shifts
- BPM, LPM, and tentative-motif state use explicit block RAM
- one vector PWL array per Gibbs state contains eight log/exp lanes and eight exp-only lanes
- Phase 2 reuses one weight reduction tree and performs streaming weighted-reservoir sampling
- tentative-motif insertion and complete-state score calculation share one pass
- the input and output ports use specialized burst read and burst write masters

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
