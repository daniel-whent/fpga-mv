# Stage 4: fast frame input over the USB-UART bridge (4 Mbaud) into the DDR2 framebuffer.
# Run after Stage 1, 2 and 3 (project open):
#   source C:/Users/daniel.whent/workspace/machine-vision/scripts/create_bd_stage4_usb.tcl
#
#   PC --USB--> FT2232H --UART RX pin C4--+--> AXI UART Lite (115200 commands, unchanged)
#                                         +--> usb_frame_rx (4 Mbaud, 8N1) --AXIS 8 bit @100 MHz--> axis_data_fifo
#                                              (async, clock crossing) --@MIG ui_clk--> AXI DMA S2MM --> DDR2
# usb_frame_rx is enabled and sized by a GPIO (bit31 enable, [23:0] frame length in bytes); its status
# (overflow, done, framing error, byte count) is read back through the same GPIO's second channel.
# The UART interface is replaced by plain ports usb_uart_rxd (C4) / usb_uart_txd (D4) so the RX pin can feed both.

set bd_name system
set repo_dir [file normalize [file dirname [info script]]/..]
if {[llength [get_bd_cells -quiet axi_vdma_0]] == 0} { puts "ERROR: run Stages 1-3 first"; return }
if {[llength [get_bd_cells -quiet axi_dma_usb]] > 0} { puts "ERROR: Stage 4 already applied. Rebuild with Stages 1-4 in order."; return }
open_bd_design [get_files ${bd_name}.bd]

# ---------------------------------------------------------------- UART pins: split the interface
set uart_intf_nets [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins axi_uartlite_0/UART]]
if {[llength $uart_intf_nets]} { delete_bd_objs $uart_intf_nets }
delete_bd_objs [get_bd_intf_ports usb_uart]
set_property CONFIG.UARTLITE_BOARD_INTERFACE Custom [get_bd_cells axi_uartlite_0]
create_bd_port -dir I usb_uart_rxd
create_bd_port -dir O usb_uart_txd
connect_bd_net [get_bd_ports usb_uart_rxd] [get_bd_pins axi_uartlite_0/rx]
connect_bd_net [get_bd_pins axi_uartlite_0/tx] [get_bd_ports usb_uart_txd]

# ---------------------------------------------------------------- receiver (RTL module reference)
set rtl $repo_dir/usb/rtl/usb_frame_rx.v
if {[llength [get_files -quiet usb_frame_rx.v]] == 0} { add_files -norecurse $rtl }
update_compile_order -fileset sources_1
create_bd_cell -type module -reference usb_frame_rx usb_rx
set_property CONFIG.CLKS_PER_BIT 25 [get_bd_cells usb_rx]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins usb_rx/clk]
connect_bd_net [get_bd_pins rst_clk_wiz_0_100M/peripheral_aresetn] [get_bd_pins usb_rx/rst_n]
connect_bd_net [get_bd_ports usb_uart_rxd] [get_bd_pins usb_rx/rxd]

# ---------------------------------------------------------------- control/status GPIO (100 MHz domain)
set g [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_usb]
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH   32 \
    CONFIG.C_ALL_OUTPUTS  1 \
    CONFIG.C_IS_DUAL      1 \
    CONFIG.C_GPIO2_WIDTH  32 \
    CONFIG.C_ALL_INPUTS_2 1 \
] $g
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /clk_wiz_0/clk_out1 \
    Clk_slave   /clk_wiz_0/clk_out1 \
    Clk_xbar    /clk_wiz_0/clk_out1 \
    Master      {/microblaze_0 (Periph)} \
    Slave       /axi_gpio_usb/S_AXI \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins axi_gpio_usb/S_AXI]
connect_bd_net [get_bd_pins axi_gpio_usb/gpio_io_o]  [get_bd_pins usb_rx/ctrl]
connect_bd_net [get_bd_pins usb_rx/status]           [get_bd_pins axi_gpio_usb/gpio2_io_i]

# ---------------------------------------------------------------- clock-crossing FIFO (100 MHz -> MIG ui_clk)
set f [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo axis_fifo_usb]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES 1 \
    CONFIG.HAS_TLAST       1 \
    CONFIG.FIFO_DEPTH      1024 \
    CONFIG.IS_ACLK_ASYNC   1 \
] $f
connect_bd_intf_net [get_bd_intf_pins usb_rx/m_axis] [get_bd_intf_pins axis_fifo_usb/S_AXIS]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1]                     [get_bd_pins axis_fifo_usb/s_axis_aclk]
connect_bd_net [get_bd_pins rst_clk_wiz_0_100M/peripheral_aresetn]  [get_bd_pins axis_fifo_usb/s_axis_aresetn]
connect_bd_net [get_bd_pins mig_7series_0/ui_clk]                   [get_bd_pins axis_fifo_usb/m_axis_aclk]

# ---------------------------------------------------------------- AXI DMA (S2MM only, simple register mode)
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_usb]
set_property -dict [list \
    CONFIG.c_include_sg            0 \
    CONFIG.c_include_mm2s          0 \
    CONFIG.c_include_s2mm          1 \
    CONFIG.c_include_s2mm_dre      1 \
    CONFIG.c_s2mm_burst_size       16 \
    CONFIG.c_sg_length_width       23 \
    CONFIG.c_m_axi_s2mm_data_width 32 \
    CONFIG.c_s_axis_s2mm_tdata_width 8 \
] $dma
connect_bd_intf_net [get_bd_intf_pins axis_fifo_usb/M_AXIS] [get_bd_intf_pins axi_dma_usb/S_AXIS_S2MM]

# DMA control registers on the MIG user clock (as for the VDMA), data port to DDR2
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /clk_wiz_0/clk_out1 \
    Clk_slave   /mig_7series_0/ui_clk \
    Clk_xbar    /clk_wiz_0/clk_out1 \
    Master      {/microblaze_0 (Periph)} \
    Slave       /axi_dma_usb/S_AXI_LITE \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins axi_dma_usb/S_AXI_LITE]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /mig_7series_0/ui_clk \
    Clk_slave   /mig_7series_0/ui_clk \
    Clk_xbar    /mig_7series_0/ui_clk \
    Master      /axi_dma_usb/M_AXI_S2MM \
    Slave       /mig_7series_0/S_AXI \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins mig_7series_0/S_AXI]

# the DMA only needs DDR2
foreach seg {axi_gpio_0/S_AXI/Reg axi_uartlite_0/S_AXI/Reg axi_vdma_0/S_AXI_LITE/Reg axi_gpio_usb/S_AXI/Reg axi_dma_usb/S_AXI_LITE/Reg} {
    catch {exclude_bd_addr_seg [get_bd_addr_segs $seg] -target_address_space [get_bd_addr_spaces axi_dma_usb/Data_S2MM]}
}

# the FIFO's master side runs on ui_clk with the MIG reset
connect_bd_net [get_bd_pins rst_mig_7series_0_81M/peripheral_aresetn] [get_bd_pins axis_fifo_usb/m_axis_aresetn] -quiet

# ---------------------------------------------------------------- pins
set xdc $repo_dir/constraints/usb_uart.xdc
if {[llength [get_files -quiet [file tail $xdc]]] == 0} { add_files -fileset constrs_1 -norecurse $xdc }

# ---------------------------------------------------------------- finish
regenerate_bd_layout
set ok 0
for {set i 0} {$i < 4 && !$ok} {incr i} {
    if {[catch {validate_bd_design} err]} { puts "validate attempt [expr {$i+1}] failed: $err" } else { set ok 1 }
}
if {!$ok} { error "validate_bd_design failed 4 times" }
save_bd_design
assign_bd_address -quiet
puts "Address map:"
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/Data]] {
    puts "  $seg  offset=[get_property OFFSET $seg] range=[get_property RANGE $seg]"
}
make_wrapper -files [get_files ${bd_name}.bd] -top
update_compile_order -fileset sources_1
puts "Stage 4 (USB frame input) block design updated."
