# blueVitis
**An Advanced, High-Performance Boilerplate Codebase for AMD FPGA Kernel Development using Bluespec SystemVerilog (BSV).**

`blueVitis` originated from the foundational work, [`bluespec-vitis-core`](https://github.com/sangwoojun/bluespec-vitis-core), developed by my esteemed advisor, Prof. Sang-Woo Jun. 

## File structure
* hw/

  All custom hardware logic files and configurations for a specific kernel running on AMD FPGA.
* sw/

## Prerequisites & Dependencies
1. blueLibrary (Required)
 
   `blueVitis` relies heavily on custom hardware IP blocks provided by [blueLibrary](https://github.com/SeMinLim/bluelibrary)..

   By default, blueLibrary must be cloned at the same level as blueVitis (e.g., ~/bluevitis and ~/bluelibrary).

## Environment Setup
* **Operating System:** Ubuntu 24.04.4 LTS & 6.8.0-48-generic Kernel
* **Framework:** AMD Vitis 2025.02 & Xilinx Runtime (XRT)
* **Compiler:** Bluespec System Verilog (BSC)

## How to build
* Building and packaging kernel, xclbin, and hw: cd to hw/, run `make`
* Using a different kernel: `make KERNEL=sort_kernel`
* Building kernel to generate .xo: cd to the kernel directory, run `make`
* Building software: cd to sw/, run `make`

## Working examples
* hw/example_kernel & sw/example_host: Simple adder example

## Notes
* Developed in Vitis 2023.2, tested on Alveo U50
