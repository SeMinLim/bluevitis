.DEFAULT_GOAL := all_xclbin

ROOT_DIR = ../../
PLATFORM ?= xilinx_u50_gen3x16_xdma_5_202210_1
BSCFLAGS = -show-schedule -aggressive-conditions 
BSCFLAGS_SYNTH = -bdir ./obj -vdir ./obj/verilog -simdir ./obj -info-dir ./obj -fdir ./obj 
TARGET := hw
BUILD_DIR := ./$(TARGET)
BLIB_DIR = $(ROOT_DIR)/../bluelib/src


.PHONY: all verilog clean clean_all all_xclbin

MODULEPATH=
VIVADO := $(XILINX_VIVADO)/bin/vivado
BOARD_MAKEFILE := makefile_us_alveo.mk

all_xclbin: $(BUILD_DIR)/kernel.xo
	$(MAKE) -f $(BOARD_MAKEFILE) TARGET=$(TARGET) PLATFORM=$(PLATFORM) package

$(BUILD_DIR)/kernel.xo: ./kernel.xml ./scripts/package_kernel.tcl ./scripts/gen_xo.tcl $(wildcard ./obj/verilog/*.v) verilog
	mkdir -p obj
	mkdir -p $(BUILD_DIR)
	$(VIVADO) -mode batch -tempDir obj -source scripts/gen_xo.tcl -tclargs $(BUILD_DIR)/kernel.xo kernel $(TARGET) $(PLATFORM)

verilog: $(wildcard *.bsv) $(wildcard *.v)
	mkdir -p obj
	mkdir -p obj/verilog
	bsc  $(BSCFLAGS) $(BSCFLAGS_SYNTH) -remove-dollar -p +:$(MODULEPATH):$(BLIB_DIR) -verilog -u -g kernel KernelTop.bsv
	cd obj/verilog/;bash ../../scripts/verilogcopy.sh
	cp *.v ./obj/verilog/

clean:
	rm -rf obj $(BUILD_DIR)/kernel.xo
	rm -rf *.log *.jou

clean_all: clean
	$(MAKE) -f $(BOARD_MAKEFILE) clean
	rm -rf ./analyzer_input
