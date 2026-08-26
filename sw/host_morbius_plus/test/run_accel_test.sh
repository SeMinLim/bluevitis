#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/test/output"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

"$ROOT_DIR/obj/model" \
	--model \
	--input "$ROOT_DIR/test/DNA_TEST.fasta" \
	--output "$OUTPUT_DIR/dna_result" \
	--alphabet dna \
	--motif-length 8 \
	--pipelines 16 \
	--max-updates 4096 \
	--score-threshold 0.90 \
	--seed 1 \
	--batch-size 32

"$ROOT_DIR/obj/model" \
	--model \
	--input "$ROOT_DIR/test/PROTEIN_TEST.fasta" \
	--output "$OUTPUT_DIR/protein_result" \
	--alphabet protein \
	--motif-length 6 \
	--pipelines 16 \
	--max-updates 1024 \
	--score-threshold 0.80 \
	--seed 1 \
	--batch-size 32

grep -q "Consensus Subsequence    : ACGTGCAA" "$OUTPUT_DIR/dna_result.summary.txt"
grep -q "Consensus Subsequence    : MKLDPA" "$OUTPUT_DIR/protein_result.summary.txt"
test -s "$OUTPUT_DIR/dna_result.meme"
test -s "$OUTPUT_DIR/protein_result.meme"

printf "All Morbius+ accelerator model tests passed.\n"
