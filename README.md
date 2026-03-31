# blueVitis
* An Advanced, High-Performance Boilerplate Codebase for AMD FPGA Kernel Development using Bluespec SystemVerilog (BSV).

* `blueVitis` originated from the foundational work, [`bluespec-vitis-core`](https://github.com/sangwoojun/bluespec-vitis-core), developed by my esteemed advisor, Prof. Sang-Woo Jun. 

## File structure
* hw/
  * All custom hardware logic files and configurations for a specific kernel running are in a certain kernel folder.
  * Recommend copying one of the kernel folders and customize it!
* sw/
  * Customized C++ file that manages and configures all operations between the host machine and the FPGA.

## Prerequisites & Dependencies
* blueLibrary (Required)
  * `blueVitis` relies heavily on custom hardware IP blocks provided by [`blueLibrary`](https://github.com/SeMinLim/bluelibrary).
  * By default, blueLibrary must be cloned at the same level as `blueVitis` (e.g., ~/bluevitis and ~/bluelibrary).
* Environment Setup
  * Operating System: Ubuntu 24.04.4 LTS & 6.8.0-48-generic Kernel 
  * Framework: AMD Vitis 2025.02 & Xilinx Runtime (XRT)
  * Compiler: Bluespec System Verilog (BSC)

## How to build
`blueVitis` features a fully automated, one-touch Makefile system. A single command handles BSV-to-Verilog compilation, Vivado IP packaging, Vitis .xclbin linking, and Host C++ compilation.
* Hardware Emulation (Fast Logic Verification)
  * To verify your BSV logic and Host C++ integration without waiting for the lengthy physical synthesis process:
  * ```make all TARGET=hw_emu && make run TARGET=hw_emu```
* Actual Hardware Synthesis (Bitstream Generation)
  * To synthesize the final `.xclbin` for the physical Alveo U50 FPGA:
  * ```make all TARGET=hw```
* Standalone Host Compilation (Optional)
  * If you only modified the C++ host code (`sw/host_example/main.cpp`) and want to recompile the software without touching the hardware bitstream:
  * ```make host```
* Running on the FPGA
  * Once the `TARGET=hw` build is fully complete, execute the packaged host application:
  * ```make run TARGET=hw```

## Cleaning the Workspace
To prevent caching issues or to free up disk space, use the provided clean targets:
* `make clean`: Removes intermediate object files, logs (.log, .jou), and host executables.
* `make cleanall`: Completely wipes all generated hardware packages, IP caches, and heavy .xclbin / .xo bitstreams.

## Working examples
* hw/example_kernel & sw/example_host: Simple adder example

## Notes
* Maintained by `Se-Min Lim`
* Developed in Vitis 2025.2, tested on Alveo U50
