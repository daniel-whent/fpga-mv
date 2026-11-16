# Stage 2: add DDR2 (MIG) + LEDs/calibration-status GPIO to the Stage 1 block design.
# Run in the Vivado Tcl console with the project open and Stage 1 'system' BD present:
#   source C:/Users/daniel.whent/workspace/machine-vision/scripts/create_bd_stage2.tcl
#
# Facts used (from the Digilent board file mig.prj):
#   MT47H64M16HR-25E, 128 MiB, 16-bit bus, 650 MT/s, AXI 128-bit / 27-bit address,
#   ui_clk ~81.25 MHz, sys clock input 100 MHz, reference clock input 200 MHz.
# The board file declares the system clock as "Single-Ended" (MIG puts its own input buffer on the
# pad). We feed MIG from the Clocking Wizard instead, so ip/mig_nexys_a7_nobuf.prj is the board's
# mig.prj with <SystemClock> changed to "No Buffer".

set bd_name system
set repo_dir [file normalize [file dirname [info script]]/..]
set mig_prj  $repo_dir/ip/mig_nexys_a7_nobuf.prj

if {![file exists $mig_prj]} { puts "ERROR: missing $mig_prj"; return }
if {[llength [get_files -quiet ${bd_name}.bd]] == 0} { puts "ERROR: run create_bd_stage1.tcl first"; return }

# Path-length guard: MIG's generated example design has very long file names (Windows limit 260).
set longest "[get_property DIRECTORY [current_project]]/[current_project].gen/sources_1/bd/$bd_name/ip/system_mig_7series_0_0/_tmp//system_mig_7series_0_0/example_design/rtl/traffic_gen/mig_7series_v4_2_axi4_tg.v"
if {[string length $longest] > 240} {
    puts "ERROR: project path too long for MIG ([string length $longest] chars; limit 260). Move the project to a shorter path."
    return
}

open_bd_design [get_files ${bd_name}.bd]

if {[llength [get_bd_cells -quiet mig_7series_0]] > 0} {
    puts "ERROR: mig_7series_0 already exists. Re-run create_bd_stage1.tcl to rebuild from scratch, then this script."
    return
}

# ---------------------------------------------------------------- MIG
set mig [create_bd_cell -type ip -vlnv xilinx.com:ip:mig_7series mig_7series_0]
# Board connection creates the DDR2 pins + constraints; it also creates two clock ports we don't want.
apply_board_connection -board_interface ddr2_sdram -ip_intf mig_7series_0/mig_ddr_interface -diagram $bd_name
delete_bd_objs [get_bd_ports {sys_clk_i clk_ref_i}]
set_property CONFIG.XML_INPUT_FILE $mig_prj $mig

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins mig_7series_0/sys_clk_i]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins mig_7series_0/clk_ref_i]
# MIG sys_rst is active-low per mig.prj; use the board reset (CPU RESET button) which is active-low.
connect_bd_net [get_bd_ports reset] [get_bd_pins mig_7series_0/sys_rst]

# MicroBlaze peripheral port -> MIG (adds reset block for ui_clk, clock crossing, address map).
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /clk_wiz_0/clk_out1 \
    Clk_slave   /mig_7series_0/ui_clk \
    Clk_xbar    /clk_wiz_0/clk_out1 \
    Master      {/microblaze_0 (Periph)} \
    Slave       /mig_7series_0/S_AXI \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins mig_7series_0/S_AXI]

# ---------------------------------------------------------------- GPIO: LEDs + calibration status
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH   16 \
    CONFIG.C_ALL_OUTPUTS  1 \
    CONFIG.C_IS_DUAL      1 \
    CONFIG.C_GPIO2_WIDTH  2 \
    CONFIG.C_ALL_INPUTS_2 1 \
] $gpio
apply_board_connection -board_interface led_16bits -ip_intf axi_gpio_0/GPIO -diagram $bd_name

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /clk_wiz_0/clk_out1 \
    Clk_slave   /clk_wiz_0/clk_out1 \
    Clk_xbar    /clk_wiz_0/clk_out1 \
    Master      {/microblaze_0 (Periph)} \
    Slave       /axi_gpio_0/S_AXI \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins axi_gpio_0/S_AXI]

# GPIO2 bit0 = init_calib_complete, bit1 = mmcm_locked (MIG)
set cat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat xlconcat_status]
set_property -dict [list CONFIG.NUM_PORTS 2 CONFIG.IN0_WIDTH 1 CONFIG.IN1_WIDTH 1] $cat
connect_bd_net [get_bd_pins mig_7series_0/init_calib_complete] [get_bd_pins xlconcat_status/In0]
connect_bd_net [get_bd_pins mig_7series_0/mmcm_locked]         [get_bd_pins xlconcat_status/In1]
connect_bd_net [get_bd_pins xlconcat_status/dout]              [get_bd_pins axi_gpio_0/gpio2_io_i]

# ---------------------------------------------------------------- finish
regenerate_bd_layout
validate_bd_design
save_bd_design
assign_bd_address -quiet
puts "Address map:"
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/Data]] {
    puts "  $seg  offset=[get_property OFFSET $seg] range=[get_property RANGE $seg]"
}

make_wrapper -files [get_files ${bd_name}.bd] -top
update_compile_order -fileset sources_1
puts "Stage 2 block design updated. Next: Generate Bitstream (MIG synthesis takes longer), export XSA, run the DDR2 test."
