# blueVitis
* Another Boilerplate codebase for using Bluespec System Verilog for Xilinx Alveo FPGA kernel development.
* blueVitis originated from "[bluespec-vitis-core](https://github.com/sangwoojun/bluespec-vitis-core)," which was developed by my esteemed advisor, Sang-Woo Jun. 

## File structure
* hw/
* sw/

## Clone bluelibrary
* blueVitis depends on the library, [blueLibrary](https://github.com/SeMinLim/bluelibrary).
* By default, bluelibrary must be cloned at the same level as bluespec-vitis-core (e.g., ~/bluevitis and ~/bluelibrary).

## How to build
* Building and packaging kernel, xclbin, and hw: cd to hw/, run `make`
* Using a different kernel: `make KERNEL=sort_kernel`
* Building kernel to generate .xo: cd to the kernel directory, run `make`
* Building software: cd to sw/, run `make`

## Working examples
* hw/example_kernel & sw/example_host: Simple adder example

## Notes
* Developed in Vitis 2023.2, tested on Alveo U50
