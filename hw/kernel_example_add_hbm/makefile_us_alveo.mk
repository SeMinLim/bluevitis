TARGET := hw
PROJECT := example_add_hbm
PLATFORM ?= xilinx_u50_gen3x16_xdma_5_202210_1

HOSTDIR := ../../sw/host_$(PROJECT)/
BUILD_DIR := ./$(TARGET)
CXXFLAGS += -g -std=c++17 -Wall -O2

JOBS := 8
VPPFLAGS := --vivado.param general.maxThreads=$(JOBS) --vivado.impl.jobs $(JOBS) --vivado.synth.jobs $(JOBS) --temp_dir $(BUILD_DIR) --log_dir $(BUILD_DIR) --report_dir $(BUILD_DIR) --report_level 2


build: package

# Host C++ Code Building
host: $(HOSTDIR)/obj/main
$(HOSTDIR)/obj/main: $(wildcard $(HOSTDIR)/*.cpp) $(wildcard $(HOSTDIR)/*.h)
	$(MAKE) -C $(HOSTDIR)

# Vitis Linking (.xo -> .xclbin)
xclbin: $(BUILD_DIR)/kernel.xclbin
$(BUILD_DIR)/kernel.xclbin: $(BUILD_DIR)/kernel.xo
	mkdir -p $(BUILD_DIR)
	v++ -l -t ${TARGET} --platform $(PLATFORM) --config u50.cfg $(VPPFLAGS) $(BUILD_DIR)/kernel.xo -o $(BUILD_DIR)/kernel.xclbin
	@if [ "$(TARGET)" = "hw" ]; then \
		vivado -mode batch -source ./scripts/report_hierarchical_utilization.tcl -tclargs $(BUILD_DIR); \
	fi

# Emulation File Building
emconfig: $(BUILD_DIR)/emconfig.json
$(BUILD_DIR)/emconfig.json:
	mkdir -p $(BUILD_DIR)
	emconfigutil --platform $(PLATFORM) --od $(BUILD_DIR) --nd 1

# Final Packaging
package: host emconfig xclbin
	mkdir -p $(BUILD_DIR)/hw_package
	cp $(HOSTDIR)/obj/main $(BUILD_DIR)/hw_package/
	cp $(BUILD_DIR)/kernel.xclbin $(BUILD_DIR)/hw_package/
	cp $(BUILD_DIR)/emconfig.json $(BUILD_DIR)/hw_package/
	cp xrt.ini $(BUILD_DIR)/hw_package/
	cd $(BUILD_DIR) && tar czvf hw_package.tgz hw_package/

# Cleaning Task
clean:
	rm -rf $(BUILD_DIR) *json *.log *summary _x xilinx* .run .Xil .ipcache *.jou
