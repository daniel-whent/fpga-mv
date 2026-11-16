# Stage 3: VGA output (640x480 @ ~59.5 Hz) read from a DDR2 framebuffer by AXI VDMA.
# Run after create_bd_stage1.tcl and create_bd_stage2.tcl (project open):
#   source C:/Users/daniel.whent/workspace/machine-vision/scripts/create_bd_stage3_vga.tcl
#
#   DDR2 (MIG) --M_AXI_MM2S--> AXI VDMA --24-bit stream @25 MHz--> AXI4-Stream to Video Out --> VGA pins
#                                                          ^ timing from Video Timing Controller
# Pixel clock = 25.000 MHz from a 3rd Clocking Wizard output (exact: 1000 MHz VCO / 40).
# Refresh = 25e6 / (800 * 525) = 59.52 Hz. Sync pulses are active-low (640x480 standard).
# Framebuffer format: 24 bits/pixel packed, 640 px/line = 1920 bytes/line, 921600 bytes/frame.
# Video data mapping (Xilinx "RGB" stream order): tdata[23:16]=R, [15:8]=B, [7:0]=G, so in memory
# each pixel is the bytes G, B, R. If colors look swapped on the monitor, change rgb_* below.

set bd_name system
set repo_dir [file normalize [file dirname [info script]]/..]
set xdc $repo_dir/constraints/vga.xdc

if {[llength [get_bd_cells -quiet mig_7series_0]] == 0} { puts "ERROR: run Stage 1 and Stage 2 first"; return }
if {[llength [get_bd_cells -quiet axi_vdma_0]] > 0}     { puts "ERROR: Stage 3 already applied. Rebuild with Stage 1, 2, 3 in order."; return }
open_bd_design [get_files ${bd_name}.bd]

# ---------------------------------------------------------------- pixel clock + reset
set_property -dict [list \
    CONFIG.CLKOUT3_USED true \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ 25.000 \
    CONFIG.NUM_OUT_CLKS 3 \
] [get_bd_cells clk_wiz_0]

set rst_pix [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pix]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins rst_pix/slowest_sync_clk]
connect_bd_net [get_bd_ports reset]             [get_bd_pins rst_pix/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins rst_pix/dcm_locked]

# ---------------------------------------------------------------- VDMA (read side only)
set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma axi_vdma_0]
set_property -dict [list \
    CONFIG.c_include_s2mm            0 \
    CONFIG.c_m_axis_mm2s_tdata_width 24 \
    CONFIG.c_num_fstores             1 \
    CONFIG.c_use_mm2s_fsync          0 \
] $vdma

# control registers from MicroBlaze. The VDMA requires s_axi_lite_aclk <= m_axi_mm2s_aclk, so its
# control port runs on the MIG user clock (81.25 MHz) like its memory port; SmartConnect crosses clocks.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /clk_wiz_0/clk_out1 \
    Clk_slave   /mig_7series_0/ui_clk \
    Clk_xbar    /clk_wiz_0/clk_out1 \
    Master      {/microblaze_0 (Periph)} \
    Slave       /axi_vdma_0/S_AXI_LITE \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins axi_vdma_0/S_AXI_LITE]

# framebuffer reads from DDR2
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /mig_7series_0/ui_clk \
    Clk_slave   /mig_7series_0/ui_clk \
    Clk_xbar    /mig_7series_0/ui_clk \
    Master      /axi_vdma_0/M_AXI_MM2S \
    Slave       /mig_7series_0/S_AXI \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins mig_7series_0/S_AXI]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins axi_vdma_0/m_axis_mm2s_aclk]

# The VDMA shares the SmartConnect with MicroBlaze; keep it away from peripheral registers (it only
# needs DDR2).
foreach seg {axi_gpio_0/S_AXI/Reg axi_uartlite_0/S_AXI/Reg axi_vdma_0/S_AXI_LITE/Reg} {
    catch {exclude_bd_addr_seg [get_bd_addr_segs $seg] -target_address_space [get_bd_addr_spaces axi_vdma_0/Data_MM2S]}
}

# ---------------------------------------------------------------- Video Timing Controller (generator only)
set vtc [create_bd_cell -type ip -vlnv xilinx.com:ip:v_tc v_tc_0]
set_property -dict [list \
    CONFIG.HAS_AXI4_LITE      false \
    CONFIG.enable_detection   false \
    CONFIG.enable_generation  true \
    CONFIG.VIDEO_MODE         Custom \
    CONFIG.GEN_HACTIVE_SIZE   640 \
    CONFIG.GEN_HFRAME_SIZE    800 \
    CONFIG.GEN_HSYNC_START    656 \
    CONFIG.GEN_HSYNC_END      752 \
    CONFIG.GEN_VACTIVE_SIZE   480 \
    CONFIG.GEN_F0_VFRAME_SIZE 525 \
    CONFIG.GEN_F0_VSYNC_VSTART 489 \
    CONFIG.GEN_F0_VSYNC_VEND   491 \
    CONFIG.GEN_F0_VBLANK_HSTART 640 \
    CONFIG.GEN_F0_VBLANK_HEND   640 \
    CONFIG.GEN_F0_VSYNC_HSTART  640 \
    CONFIG.GEN_F0_VSYNC_HEND    640 \
    CONFIG.GEN_HSYNC_POLARITY Low \
    CONFIG.GEN_VSYNC_POLARITY Low \
] $vtc

# ---------------------------------------------------------------- AXI4-Stream to Video Out
set vo [create_bd_cell -type ip -vlnv xilinx.com:ip:v_axi4s_vid_out v_axi4s_vid_out_0]
set_property -dict [list \
    CONFIG.C_HAS_ASYNC_CLK 0 \
    CONFIG.C_PIXELS_PER_CLOCK 1 \
    CONFIG.C_NATIVE_COMPONENT_WIDTH 8 \
    CONFIG.C_S_AXIS_VIDEO_DATA_WIDTH 8 \
] $vo

connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins v_axi4s_vid_out_0/video_in]
connect_bd_intf_net [get_bd_intf_pins v_tc_0/vtiming_out]     [get_bd_intf_pins v_axi4s_vid_out_0/vtiming_in]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins v_axi4s_vid_out_0/aclk] [get_bd_pins v_tc_0/clk]
connect_bd_net [get_bd_pins rst_pix/peripheral_aresetn] [get_bd_pins v_axi4s_vid_out_0/aresetn] [get_bd_pins v_tc_0/resetn]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vtg_ce] [get_bd_pins v_tc_0/gen_clken]

set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant const_one]
set_property -dict [list CONFIG.CONST_VAL 1 CONFIG.CONST_WIDTH 1] $one
foreach p {v_axi4s_vid_out_0/aclken v_tc_0/clken} {
    connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins $p]
}
if {[llength [get_bd_pins -quiet v_axi4s_vid_out_0/vid_io_out_ce]] > 0} {
    connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins v_axi4s_vid_out_0/vid_io_out_ce]
}

# ---------------------------------------------------------------- VGA pins: top 4 bits of each color
# vid_data: [23:16]=R, [15:8]=B, [7:0]=G
array set slice {r {23 20} b {15 12} g {7 4}}
foreach c {r g b} {
    lassign $slice($c) hi lo
    set s [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice vga_${c}_slice]
    set_property -dict [list CONFIG.DIN_WIDTH 24 CONFIG.DIN_FROM $hi CONFIG.DIN_TO $lo CONFIG.DOUT_WIDTH 4] $s
    connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_data] [get_bd_pins vga_${c}_slice/Din]
    create_bd_port -dir O -from 3 -to 0 vga_$c
    connect_bd_net [get_bd_pins vga_${c}_slice/Dout] [get_bd_ports vga_$c]
}
create_bd_port -dir O vga_hs
create_bd_port -dir O vga_vs
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_hsync] [get_bd_ports vga_hs]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_vsync] [get_bd_ports vga_vs]

# ---------------------------------------------------------------- debug: status flags + stream ILA
# Video Out status flags into the GPIO status register (software-readable):
#   bit0 init_calib_complete, bit1 mmcm_locked, bit2 vid_out locked, bit3 underflow, bit4 overflow
# (flags are in the pixel-clock domain; fine for slow software reads)
set_property CONFIG.NUM_PORTS 5 [get_bd_cells xlconcat_status]
set_property CONFIG.C_GPIO2_WIDTH 5 [get_bd_cells axi_gpio_0]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/locked]    [get_bd_pins xlconcat_status/In2]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/underflow] [get_bd_pins xlconcat_status/In3]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/overflow]  [get_bd_pins xlconcat_status/In4]

# ILA 1: the VDMA -> Video Out AXI4-Stream (tdata/tvalid/tready/tlast/tuser) at pixel clock
set_property HDL_ATTRIBUTE.DEBUG true [get_bd_intf_nets axi_vdma_0_M_AXIS_MM2S]
apply_bd_automation -rule xilinx.com:bd_rule:debug -dict [list     [get_bd_intf_nets axi_vdma_0_M_AXIS_MM2S] {AXIS_SIGNALS "Data and Trigger" CLK_SRC "/clk_wiz_0/clk_out3" SYSTEM_ILA "Auto" APC_EN "0"} ]

# ---------------------------------------------------------------- finish
regenerate_bd_layout
validate_bd_design
save_bd_design

if {[llength [get_files -quiet [file tail $xdc]]] == 0} {
    add_files -fileset constrs_1 -norecurse $xdc
}

puts "Address map:"
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/Data]] {
    puts "  $seg  offset=[get_property OFFSET $seg] range=[get_property RANGE $seg]"
}
make_wrapper -files [get_files ${bd_name}.bd] -top
update_compile_order -fileset sources_1
puts "Stage 3 (VGA) block design updated. Next: Generate Bitstream, export XSA, run the VGA test pattern."
