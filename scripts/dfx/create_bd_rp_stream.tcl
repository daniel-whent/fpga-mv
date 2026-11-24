# DFX stage 3: streaming data path through the reconfigurable partition. Run after create_bd_rp_axi.tcl.
#
#   DDR2 --MM2S--> axi_dma_rp --(ui_clk)--> axis_fifo_in (async) --(100 MHz)--> axi_dec s_intf_1 -> rp_s_axis -> u_rp
#   DDR2 <--S2MM-- axi_dma_rp <-(ui_clk)--- axis_fifo_out (async) <-(100 MHz)-- axi_dec s_intf_2 <- rp_m_axis <- u_rp
#
# 8-bit streams (pixels as G,B,R bytes), AXI DMA in simple register mode (control registers on the MIG ui_clk,
# like the Stage 4 DMA). The partition runs on the 100 MHz clock (rp_aclk), so the two FIFOs cross the clock domains.
# The decoupler (already created with intf_1 / intf_2 in create_bd_rp_axi.tcl) holds the stream interfaces idle
# while the partition is being reconfigured.

set bd_name system
if {[llength [get_bd_cells -quiet axi_dec]] == 0} { puts "ERROR: run create_bd_rp_axi.tcl first"; return }
if {[llength [get_bd_cells -quiet axi_dma_rp]] > 0} { puts "ERROR: already applied"; return }
open_bd_design [get_files ${bd_name}.bd]

set clk100 [get_bd_pins clk_wiz_0/clk_out1]
set rst100 [get_bd_pins rst_clk_wiz_0_100M/peripheral_aresetn]
set clkui  [get_bd_pins mig_7series_0/ui_clk]
set rstui  [get_bd_pins rst_mig_7series_0_81M/peripheral_aresetn]

# ---------------------------------------------------------------- AXI DMA, MM2S + S2MM
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_rp]
set_property -dict [list \
    CONFIG.c_include_sg              0 \
    CONFIG.c_include_mm2s            1 \
    CONFIG.c_include_s2mm            1 \
    CONFIG.c_include_mm2s_dre        1 \
    CONFIG.c_include_s2mm_dre        1 \
    CONFIG.c_mm2s_burst_size         16 \
    CONFIG.c_s2mm_burst_size         16 \
    CONFIG.c_sg_length_width         23 \
    CONFIG.c_m_axi_mm2s_data_width   32 \
    CONFIG.c_m_axi_s2mm_data_width   32 \
    CONFIG.c_m_axis_mm2s_tdata_width 8 \
    CONFIG.c_s_axis_s2mm_tdata_width 8 \
] $dma

# ---------------------------------------------------------------- clock-crossing FIFOs
proc mk_fifo {name} {
    set f [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo $name]
    set_property -dict [list CONFIG.TDATA_NUM_BYTES 1 CONFIG.HAS_TLAST 1 CONFIG.FIFO_DEPTH 1024 CONFIG.IS_ACLK_ASYNC 1] $f
    return $f
}
set fin  [mk_fifo axis_fifo_in]
set fout [mk_fifo axis_fifo_out]

# DMA control registers and data ports on ui_clk (as in Stage 4)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /clk_wiz_0/clk_out1 \
    Clk_slave   /mig_7series_0/ui_clk \
    Clk_xbar    /clk_wiz_0/clk_out1 \
    Master      {/microblaze_0 (Periph)} \
    Slave       /axi_dma_rp/S_AXI_LITE \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins axi_dma_rp/S_AXI_LITE]
foreach m {M_AXI_MM2S M_AXI_S2MM} {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Clk_master  /mig_7series_0/ui_clk \
        Clk_slave   /mig_7series_0/ui_clk \
        Clk_xbar    /mig_7series_0/ui_clk \
        Master      /axi_dma_rp/$m \
        Slave       /mig_7series_0/S_AXI \
        ddr_seg     Auto \
        intc_ip     /axi_smc \
        master_apm  0 \
    ] [get_bd_intf_pins mig_7series_0/S_AXI]
}

# ---------------------------------------------------------------- stream wiring
# into the partition
connect_bd_intf_net [get_bd_intf_pins axi_dma_rp/M_AXIS_MM2S] [get_bd_intf_pins axis_fifo_in/S_AXIS]
connect_bd_net $clkui  [get_bd_pins axis_fifo_in/s_axis_aclk]
connect_bd_net $rstui  [get_bd_pins axis_fifo_in/s_axis_aresetn]
connect_bd_net $clk100 [get_bd_pins axis_fifo_in/m_axis_aclk]
connect_bd_intf_net [get_bd_intf_pins axis_fifo_in/M_AXIS] [get_bd_intf_pins axi_dec/s_intf_1]
# out of the partition
connect_bd_intf_net [get_bd_intf_pins axi_dec/s_intf_2] [get_bd_intf_pins axis_fifo_out/S_AXIS]
connect_bd_net $clk100 [get_bd_pins axis_fifo_out/s_axis_aclk]
connect_bd_net $rst100 [get_bd_pins axis_fifo_out/s_axis_aresetn]
connect_bd_net $clkui  [get_bd_pins axis_fifo_out/m_axis_aclk]
connect_bd_intf_net [get_bd_intf_pins axis_fifo_out/M_AXIS] [get_bd_intf_pins axi_dma_rp/S_AXIS_S2MM]

# partition-side stream ports (external interface ports; the RTL partition u_rp is outside the BD)
set pin [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 rp_s_axis]
set pout [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 rp_m_axis]
# rp_s_axis (Master) takes its properties from the decoupler; the Slave-mode rp_m_axis needs them set
set_property -dict [list CONFIG.TDATA_NUM_BYTES 1 CONFIG.HAS_TLAST 1 CONFIG.HAS_TREADY 1 CONFIG.HAS_TKEEP 0 CONFIG.HAS_TSTRB 0 CONFIG.FREQ_HZ 100000000] [get_bd_intf_ports rp_m_axis]
connect_bd_intf_net [get_bd_intf_pins axi_dec/rp_intf_1] [get_bd_intf_ports rp_s_axis]
connect_bd_intf_net [get_bd_intf_ports rp_m_axis] [get_bd_intf_pins axi_dec/rp_intf_2]
set_property CONFIG.ASSOCIATED_BUSIF {rp_axi:rp_s_axis:rp_m_axis} [get_bd_ports rp_aclk]

# AXI Timer used as a free-running 100 MHz microsecond-resolution stopwatch for benchmarking (swap time, frame time)
set tmr [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer axi_timer_0]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master  /clk_wiz_0/clk_out1 \
    Clk_slave   /clk_wiz_0/clk_out1 \
    Clk_xbar    /clk_wiz_0/clk_out1 \
    Master      {/microblaze_0 (Periph)} \
    Slave       /axi_timer_0/S_AXI \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins axi_timer_0/S_AXI]

# the DMA's data masters only need DDR2: exclude every peripheral segment from both of its address spaces
foreach space {axi_dma_rp/Data_MM2S axi_dma_rp/Data_S2MM} {
    foreach seg {axi_gpio_0/S_AXI/Reg axi_uartlite_0/S_AXI/Reg axi_dec/s_axi_reg/Reg rp_axi/Reg axi_asm/S_AXI_CTRL/Reg
                 axi_hwicap_0/S_AXI_LITE/Reg axi_gpio_rst/S_AXI/Reg axi_dma_rp/S_AXI_LITE/Reg axi_timer_0/S_AXI/Reg} {
        catch {exclude_bd_addr_seg [get_bd_addr_segs /$seg] -target_address_space [get_bd_addr_spaces /$space]}
    }
}

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
puts "Streaming data path added."
