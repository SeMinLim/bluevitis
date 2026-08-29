# Morbius+ Host Software

The host implements the Markov-adjusted Seed Initializer, per-pipeline working and best tentative-motif offsets, initial leave-one-out BPM/LPM construction, XRT command packing, and final result generation.

Build the bit-accurate software model and run regression tests:

```bash
make model
make test
```

Build the XRT host after sourcing the Vitis and XRT environments:

```bash
make
```

Model execution:

```bash
./obj/model \
	--model \
	--input /path/to/input.fa \
	--output output/result \
	--alphabet dna \
	--motif-length 16 \
	--max-updates 32768 \
	--score-threshold 1.0 \
	--seed 1 \
	--batch-size 256
```
