# Configure U50 PLRAM[0] and PLRAM[1] to use UltraRAM instead of the
# platform default block RAM implementation.
#
# U50 Gen3x16 XDMA base_5 exposes PLRAM[0:1] on SLR0 and PLRAM[2:3] on SLR1.
# This example maps kernel_1.in  -> PLRAM[0]
#                 kernel_1.out -> PLRAM[1]

set mem_subsys [get_bd_cells /memory_subsystem]

sdx_memory_subsystem::update_plram_specification \
  $mem_subsys PLRAM_MEM00 { \
    SIZE 128K \
    AXI_DATA_WIDTH 512 \
    SLR_ASSIGNMENT SLR0 \
    READ_LATENCY 1 \
    MEMORY_PRIMITIVE URAM \
  }

sdx_memory_subsystem::update_plram_specification \
  $mem_subsys PLRAM_MEM01 { \
    SIZE 128K \
    AXI_DATA_WIDTH 512 \
    SLR_ASSIGNMENT SLR0 \
    READ_LATENCY 1 \
    MEMORY_PRIMITIVE URAM \
  }

validate_bd_design -force
save_bd_design

