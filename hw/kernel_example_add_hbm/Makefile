SHELL := /bin/bash
PWD = $(shell readlink -f .)

.DEFAULT_GOAL := help

NEEDS_TARGET := $(filter all run build,$(MAKECMDGOALS))
ifneq ($(NEEDS_TARGET),)
ifeq ($(filter $(TARGET),hw hw_emu),)
$(error [ERROR] TARGET must be specified! Usage: 'make $(word 1, $(NEEDS_TARGET)) TARGET=<hw_emu/hw>')
endif
endif

PLATFORM ?= xilinx_u50_gen3x16_xdma_5_202210_1
PROJECT := example_add_hbm

include makefile_us_alveo.mk

help:
	@echo "Makefile Usage:"
	@echo "  make all TARGET=<hw_emu/hw> PLATFORM=<FPGA platform>"
	@echo "      Command to generate the design for specified Target and Shell."
	@echo ""
	@echo "  make run TARGET=<hw_emu/hw> PLATFORM=<FPGA platform>"
	@echo "      Command to run application in emulation."
	@echo ""
	@echo "  make build TARGET=<hw_emu/hw> PLATFORM=<FPGA platform>"
	@echo "      Command to build xclbin application."
	@echo ""
	@echo "  make host"
	@echo "      Command to build host application."
	@echo ""
	@echo "  make clean "
	@echo "      Command to remove the generated non-hardware files."
	@echo ""
	@echo "  make cleanall"
	@echo "      Command to remove all the generated files."
	@echo ""
