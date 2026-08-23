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
PROJECT := morbius_plus

include makefile_us_alveo.mk

.PHONY: help sim
help:
	@echo "Makefile Usage:"
	@echo "  make sim"
	@echo "      Build and run the standalone GibbsPipeline Bluesim test."
	@echo ""
	@echo "  make all TARGET=<hw_emu/hw> PLATFORM=<FPGA platform>"
	@echo "      Build the host, RTL kernel, and packaged xclbin."
	@echo ""
	@echo "  make run TARGET=<hw_emu/hw> PLATFORM=<FPGA platform>"
	@echo "      Run the packaged application in emulation or on U50."
	@echo ""
	@echo "  make host"
	@echo "      Build only the XRT host application."
	@echo ""
	@echo "  make clean"
	@echo "  make cleanall"

sim:
	mkdir -p obj/sim
	bsc -bdir obj/sim -simdir obj/sim -info-dir obj/sim -u -sim -g mkTestGibbsPipeline TestGibbsPipeline.bsv
	bsc -bdir obj/sim -simdir obj/sim -info-dir obj/sim -sim -e mkTestGibbsPipeline -o obj/sim/test_gibbs
	./obj/sim/test_gibbs
