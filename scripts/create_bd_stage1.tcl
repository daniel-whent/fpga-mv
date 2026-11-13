# Stage 1: MicroBlaze + AXI UART Lite + clocking on Nexys A7-100T. No DDR2 yet.
# Run in the Vivado Tcl console with the project open:
#   source C:/Users/daniel.whent/workspace/machine-vision/scripts/create_bd_stage1.tcl
#
# IP versions are left unspecified so Vivado 2025.2 picks its own latest.

set bd_name system

# Rebuild from scratch: remove a previous (possibly partial) run of this script.
if {[llength [get_files -quiet ${bd_name}.bd]] > 0} {
    catch {close_bd_design [get_bd_designs -quiet $bd_name]}
    remove_files [get_files ${bd_name}.bd]
    file delete -force [get_property DIRECTORY [current_project]]/[current_project].srcs/sources_1/bd/$bd_name
}

create_bd_design $bd_name

# ---------------------------------------------------------------- clocking
set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0]
set_property -dict [list \
    CONFIG.PRIMITIVE        MMCM \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 100.000 \
    CONFIG.CLKOUT2_USED     true \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ 200.000 \
    CONFIG.NUM_OUT_CLKS     2 \
] $clk_wiz

# clk_in1/reset are plain pins (not interfaces) on this clk_wiz, so use the board
# automation rule rather than apply_board_connection. It creates the top-level
# ports + pin constraints, and inserts an inverter for the active-low board reset.
apply_bd_automation -rule xilinx.com:bd_rule:board -config {Board_Interface sys_clock} [get_bd_pins clk_wiz_0/clk_in1]
apply_bd_automation -rule xilinx.com:bd_rule:board -config {Board_Interface reset}     [get_bd_pins clk_wiz_0/reset]

# ---------------------------------------------------------------- MicroBlaze
create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze microblaze_0

# Creates local memory (64 KB), debug module, AXI interconnect, reset block.
apply_bd_automation -rule xilinx.com:bd_rule:microblaze -config [list \
    local_mem   64KB \
    ecc         None \
    cache       None \
    debug_module {Debug Only} \
    axi_periph  Enabled \
    axi_intc    0 \
    clk         /clk_wiz_0/clk_out1 \
] [get_bd_cells microblaze_0]

# ---------------------------------------------------------------- UART
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite axi_uartlite_0
apply_board_connection -board_interface "usb_uart" -ip_intf "axi_uartlite_0/UART" -diagram $bd_name
set_property CONFIG.C_BAUDRATE 115200 [get_bd_cells axi_uartlite_0]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /clk_wiz_0/clk_out1 \
    Clk_slave   /clk_wiz_0/clk_out1 \
    Clk_xbar    /clk_wiz_0/clk_out1 \
    Master      {/microblaze_0 (Periph)} \
    Slave       /axi_uartlite_0/S_AXI \
    ddr_seg     Auto \
    intc_ip     {New AXI SmartConnect} \
    master_apm  0 \
] [get_bd_intf_pins axi_uartlite_0/S_AXI]

# ---------------------------------------------------------------- resets
# Automation may have wired some of these already; connect only what is missing.
set rst_blk [get_bd_cells -quiet rst_clk_wiz_*]
if {[llength $rst_blk] == 0} {
    set rst_blk [get_bd_cells -quiet -filter {VLNV =~ *proc_sys_reset*} *]
}
puts "Reset block: $rst_blk"

set ext_rst [get_bd_pins -quiet $rst_blk/ext_reset_in]
if {[llength [get_bd_nets -quiet -of_objects $ext_rst]] == 0} {
    connect_bd_net [get_bd_ports reset] $ext_rst
}
set locked [get_bd_pins -quiet $rst_blk/dcm_locked]
if {[llength [get_bd_nets -quiet -of_objects $locked]] == 0} {
    connect_bd_net [get_bd_pins clk_wiz_0/locked] $locked
}

# ---------------------------------------------------------------- finish
regenerate_bd_layout
validate_bd_design
save_bd_design

# Wrapper as top
set bd_file [get_files ${bd_name}.bd]
make_wrapper -files $bd_file -top
add_files -norecurse [file normalize [get_property DIRECTORY [current_project]]/[current_project].gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v]
update_compile_order -fileset sources_1
set_property top ${bd_name}_wrapper [current_fileset]

puts "Stage 1 block design created. Next: Generate Bitstream, then File > Export > Export Hardware (fixed, include bitstream)."
