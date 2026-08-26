# Morbius+ U50 Hardware

This directory is a blueVitis-compatible RTL kernel for the Alveo U50.
The kernel uses the direct `HOST[0]` memory connection from `kernel_example_add_host` and retains sixteen independent Gibbs pipeline states on chip.

## Prototype configuration

- `NumPipeline = 16`
- `NumPE_Profiler = 128`
- `NumPE_LPM = 4`
- physical dual-mode PWL lanes: `max(NumPE_Profiler, NumPE_LPM) = 128`
- maximum sequence length: 1024 symbols
- maximum motif length: 128 symbols
- maximum alphabet size: 20 symbols
- target clock: 250 MHz

## Standalone BSV test

```bash
make sim
```

## U50 build

```bash
make all TARGET=hw_emu
make run TARGET=hw_emu MORBIUS_ARGS="--input /path/to/input.fa --output output/result --alphabet dna --motif-length 16 --pipelines 16 --max-updates 32768 --score-threshold 1.0 --seed 1"
```

For the physical U50:

```bash
xbutil configure --device <BDF> --host-mem --size 1G enable
make all TARGET=hw
make run TARGET=hw MORBIUS_ARGS="--input /path/to/input.fa --output output/result --alphabet dna --motif-length 16 --pipelines 16 --max-updates 32768 --score-threshold 1.0 --seed 1"
```
