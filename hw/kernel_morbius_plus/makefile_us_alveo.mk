SHELL := /bin/bash
#----------------------------------------------------------------------------------------
# 1. Directory & Project Settings
#----------------------------------------------------------------------------------------
BUILD_DIR := ./$(TARGET)
OBJ_DIR := ./obj
HOSTDIR := ../../sw/host_morbius_plus
#----------------------------------------------------------------------------------------
# 2. Host C++ Global Settings
#----------------------------------------------------------------------------------------
CXXFLAGS := -g -std=c++17 -Wall -Wextra -pedantic -O2
#----------------------------------------------------------------------------------------
# 3. Hardware Build Settings (BSV & Vitis)
#----------------------------------------------------------------------------------------
VIVADO := $(XILINX_VIVADO)/bin/vivado
BSCFLAGS := -show-schedule -aggressive-conditions
BSCFLAGS_SYNTH := -bdir $(OBJ_DIR) -vdir $(OBJ_DIR)/verilog -simdir $(OBJ_DIR) -info-dir $(OBJ_DIR) -fdir $(OBJ_DIR)
JOBS := 8
VPPFLAGS := --vivado.param general.maxThreads=$(JOBS) --vivado.impl.jobs $(JOBS) --vivado.synth.jobs $(JOBS) --temp_dir $(BUILD_DIR) --log_dir $(BUILD_DIR) --report_dir $(BUILD_DIR) --report_level 2
#----------------------------------------------------------------------------------------
# 4. Targets Declaration
#----------------------------------------------------------------------------------------
.PHONY: all run build host clean cleanall emconfig package
all: package
build: $(BUILD_DIR)/kernel.xclbin
#----------------------------------------------------------------------------------------
# 5. Host C++ Build
#----------------------------------------------------------------------------------------
host:
	$(MAKE) -C $(HOSTDIR) CXXFLAGS="$(CXXFLAGS)"
#----------------------------------------------------------------------------------------
# 6. Kernel Hardware Build (BSV -> Verilog -> XO -> XCLBIN)
#----------------------------------------------------------------------------------------
$(OBJ_DIR)/verilog/.done: $(wildcard *.bsv) $(wildcard *.v)
	mkdir -p $(OBJ_DIR)
	mkdir -p $(OBJ_DIR)/verilog
	bsc $(BSCFLAGS) $(BSCFLAGS_SYNTH) -remove-dollar -verilog -u -g kernel KernelTop.bsv
	cd $(OBJ_DIR)/verilog/ && bash ../../scripts/verilogcopy.sh
	cp *.v $(OBJ_DIR)/verilog/
	@touch $@
$(BUILD_DIR)/kernel.xo: ./kernel.xml ./scripts/package_kernel.tcl ./scripts/gen_xo.tcl $(OBJ_DIR)/verilog/.done
	mkdir -p $(BUILD_DIR)
	$(VIVADO) -mode batch -tempDir $(OBJ_DIR) -source scripts/gen_xo.tcl -tclargs $@ kernel $(TARGET) $(PLATFORM)
$(BUILD_DIR)/kernel.xclbin: $(BUILD_DIR)/kernel.xo
	mkdir -p $(BUILD_DIR)
	v++ -l -t $(TARGET) --platform $(PLATFORM) --config u50.cfg $(VPPFLAGS) $< -o $@
	@if [ "$(TARGET)" = "hw" ]; then \
		vivado -mode batch -source ./scripts/report_hierarchical_utilization.tcl -tclargs $(BUILD_DIR); \
	fi
#----------------------------------------------------------------------------------------
# 7. Emulation Config Generation
#----------------------------------------------------------------------------------------
emconfig: $(BUILD_DIR)/emconfig.json
$(BUILD_DIR)/emconfig.json:
	mkdir -p $(BUILD_DIR)
	emconfigutil --platform $(PLATFORM) --od $(BUILD_DIR) --nd 1
#----------------------------------------------------------------------------------------
# 8. Final Packaging
#----------------------------------------------------------------------------------------
package: host build emconfig
	mkdir -p $(BUILD_DIR)/hw_package
	cp $(HOSTDIR)/obj/main $(BUILD_DIR)/hw_package/
	cp $(BUILD_DIR)/kernel.xclbin $(BUILD_DIR)/hw_package/
	cp $(BUILD_DIR)/emconfig.json $(BUILD_DIR)/hw_package/
	cp xrt.ini $(BUILD_DIR)/hw_package/
	cd $(BUILD_DIR) && tar czvf hw_package.tgz hw_package/
#----------------------------------------------------------------------------------------
# 9. Run Application
#----------------------------------------------------------------------------------------
XCLBIN_ABS_PATH := $(CURDIR)/$(BUILD_DIR)/kernel.xclbin
run:
ifeq ($(TARGET),hw_emu)
	@echo "========================================="
	@echo " Running Hardware Emulation... "
	@echo "========================================="
	cp -rf $(BUILD_DIR)/emconfig.json $(HOSTDIR)/
	cd $(HOSTDIR) && export XCL_EMULATION_MODE=hw_emu && ./obj/main --xclbin $(XCLBIN_ABS_PATH) $${MORBIUS_ARGS}
else
	@echo "========================================="
	@echo " Running on Actual Hardware... "
	@echo "========================================="
	cd $(HOSTDIR) && unset XCL_EMULATION_MODE && ./obj/main --xclbin $(XCLBIN_ABS_PATH) $${MORBIUS_ARGS}
endif
#----------------------------------------------------------------------------------------
# 10. Cleaning Rules
#----------------------------------------------------------------------------------------
clean:
	@echo "Cleaning non-hardware files..."
	rm -rf $(OBJ_DIR) *.log *.jou xilinx* .Xil _x emconfig.json
	rm -rf ./analyzer_input *.csv xrt.run_summary
	$(MAKE) -C $(HOSTDIR) clean

cleanall: clean
	@echo "Cleaning all generated bitstreams and packages..."
	rm -rf ./hw ./hw_emu .ipcache
