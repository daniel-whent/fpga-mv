# DFX stage 2: after Stage 1 and Stage 2 add AXI HWICAP and an AXI4-Lite reconfigurable partition behind a
# DFX decoupler:
#   MicroBlaze -> axi_smc -> axi_dec (dfx_decoupler) -> external interface rp_axi -> RTL partition u_rp (top.v)
#   The decoupler has its own control register (s_axi_reg) on the same bus; rp_aclk / rp_aresetn go to the partition.
# The reconfigurable modules and the 7-segment driver live in RTL (dfx/rtl); this script only builds the BD part.

set bd_name system
if {[llength [get_bd_cells -quiet axi_dec]] > 0} { puts "ERROR: already applied"; return }
open_bd_design [get_files ${bd_name}.bd]

set sig {ARVALID {WIDTH 1 PRESENT 1} ARREADY {WIDTH 1 PRESENT 1} AWVALID {WIDTH 1 PRESENT 1} AWREADY {WIDTH 1 PRESENT 1} BVALID {WIDTH 1 PRESENT 1} BREADY {WIDTH 1 PRESENT 1} RVALID {WIDTH 1 PRESENT 1} RREADY {WIDTH 1 PRESENT 1} WVALID {WIDTH 1 PRESENT 1} WREADY {WIDTH 1 PRESENT 1} AWADDR {WIDTH 32 PRESENT 1} AWPROT {WIDTH 3 PRESENT 1} WDATA {WIDTH 32 PRESENT 1} WSTRB {WIDTH 4 PRESENT 1} BRESP {WIDTH 2 PRESENT 1} ARADDR {WIDTH 32 PRESENT 1} ARPROT {WIDTH 3 PRESENT 1} RDATA {WIDTH 32 PRESENT 1} RRESP {WIDTH 2 PRESENT 1}}
# One decoupler for the whole partition boundary: intf_0 = AXI4-Lite control (static master -> partition),
# intf_1 = 8-bit AXI4-Stream into the partition (with TKEEP, which the DMA always sends), intf_2 = 8-bit AXI4-Stream out of the partition.
# (MODE is seen from the static side: slave = static logic drives it, master = the partition drives it.)
set axs_in  {TVALID {WIDTH 1 PRESENT 1} TREADY {WIDTH 1 PRESENT 1} TDATA {WIDTH 8 PRESENT 1} TKEEP {WIDTH 1 PRESENT 1} TLAST {WIDTH 1 PRESENT 1}}
set axs_out {TVALID {WIDTH 1 PRESENT 1} TREADY {WIDTH 1 PRESENT 1} TDATA {WIDTH 8 PRESENT 1} TLAST {WIDTH 1 PRESENT 1}}
set dec [create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_decoupler axi_dec]
set_property CONFIG.ALL_PARAMS "HAS_SIGNAL_CONTROL 0 HAS_SIGNAL_STATUS 0 HAS_AXI_LITE 1 INTF {intf_0 {ID 0 VLNV xilinx.com:interface:aximm_rtl:1.0 MODE slave PROTOCOL AXI4LITE SIGNALS {$sig}} intf_1 {ID 1 VLNV xilinx.com:interface:axis_rtl:1.0 MODE slave SIGNALS {$axs_in}} intf_2 {ID 2 VLNV xilinx.com:interface:axis_rtl:1.0 MODE master SIGNALS {$axs_out}}} ALWAYS_HAVE_AXI_CLK 1 IPI_PROP_COUNT 0" $dec

# decoupler control register: normal AXI-Lite slave on the SmartConnect
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list     Clk_master  /clk_wiz_0/clk_out1     Clk_slave   /clk_wiz_0/clk_out1     Clk_xbar    /clk_wiz_0/clk_out1     Master      {/microblaze_0 (Periph)}     Slave       /axi_dec/s_axi_reg     ddr_seg     Auto     intc_ip     /axi_smc     master_apm  0 ] [get_bd_intf_pins axi_dec/s_axi_reg]

# Partition data path: the partition is RTL outside the BD, so declare it as an external AXI4-Lite port
# (an external Master-mode port gets its own address segment) and chain SmartConnect -> decoupler -> port.
set smc [get_bd_cells axi_smc]
set n [get_property CONFIG.NUM_MI $smc]
set_property CONFIG.NUM_MI [expr {$n+1}] $smc
set mi [format "M%02d_AXI" $n]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 rp_axi
set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.ADDR_WIDTH 32 CONFIG.DATA_WIDTH 32] [get_bd_intf_ports rp_axi]
# AXI shutdown manager: while shut down it answers bus transactions itself instead of letting them hang on a
# decoupled / half-configured partition. Chain: SmartConnect -> axi_asm -> decoupler -> rp_axi.
set asm [create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_axi_shutdown_manager axi_asm]
set_property -dict [list CONFIG.DP_PROTOCOL AXI4LITE CONFIG.DP_AXI_ADDR_WIDTH 32 CONFIG.DP_AXI_DATA_WIDTH 32     CONFIG.CTRL_INTERFACE_TYPE 1 CONFIG.RP_IS_MASTER false] $asm
connect_bd_intf_net [get_bd_intf_pins axi_smc/$mi] [get_bd_intf_pins axi_asm/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_asm/M_AXI] [get_bd_intf_pins axi_dec/s_intf_0]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_asm/clk]
connect_bd_net [get_bd_pins rst_clk_wiz_0_100M/peripheral_aresetn] [get_bd_pins axi_asm/resetn]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list     Clk_master  /clk_wiz_0/clk_out1     Clk_slave   /clk_wiz_0/clk_out1     Clk_xbar    /clk_wiz_0/clk_out1     Master      {/microblaze_0 (Periph)}     Slave       /axi_asm/S_AXI_CTRL     ddr_seg     Auto     intc_ip     /axi_smc     master_apm  0 ] [get_bd_intf_pins axi_asm/S_AXI_CTRL]
connect_bd_intf_net [get_bd_intf_pins axi_dec/rp_intf_0] [get_bd_intf_ports rp_axi]
assign_bd_address -quiet
# interface-side clock/reset of the decoupler (same domain as the bus)
set rstn [get_bd_pins -quiet rst_clk_wiz_0_100M/peripheral_aresetn]
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_dec/s_axi_reg_aresetn]]] == 0} { connect_bd_net $rstn [get_bd_pins axi_dec/s_axi_reg_aresetn] }
# interface 0 = AXI4-Lite, 1/2 = the two stream interfaces (wired up in create_bd_rp_stream.tcl)
foreach i {0 1 2} {
    if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_dec/intf_${i}_aclk]]] == 0} { connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_dec/intf_${i}_aclk] }
    if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_dec/intf_${i}_arstn]]] == 0} { connect_bd_net $rstn [get_bd_pins axi_dec/intf_${i}_arstn] }
}

# partition side: AXI4-Lite master interface out of the BD, plus clock and reset for the partition
create_bd_port -dir O -type clk rp_aclk
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_ports rp_aclk]
create_bd_port -dir O -type rst rp_aresetn
# Local partition reset: flip-flops of a freshly loaded module are NOT initialized by a partial bitstream here,
# so software pulses this after every load (while still decoupled). rp_aresetn = bus reset AND gpio bit.
set rg [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_rst]
set_property -dict [list CONFIG.C_GPIO_WIDTH 1 CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_DOUT_DEFAULT 0x00000001] $rg
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list     Clk_master  /clk_wiz_0/clk_out1     Clk_slave   /clk_wiz_0/clk_out1     Clk_xbar    /clk_wiz_0/clk_out1     Master      {/microblaze_0 (Periph)}     Slave       /axi_gpio_rst/S_AXI     ddr_seg     Auto     intc_ip     /axi_smc     master_apm  0 ] [get_bd_intf_pins axi_gpio_rst/S_AXI]
set rand [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic rp_rst_and]
set_property -dict [list CONFIG.C_SIZE 1 CONFIG.C_OPERATION and] $rand
connect_bd_net $rstn [get_bd_pins rp_rst_and/Op1]
connect_bd_net [get_bd_pins axi_gpio_rst/gpio_io_o] [get_bd_pins rp_rst_and/Op2]
connect_bd_net [get_bd_pins rp_rst_and/Res] [get_bd_ports rp_aresetn]
set_property CONFIG.ASSOCIATED_BUSIF rp_axi [get_bd_ports rp_aclk]
set_property CONFIG.ASSOCIATED_RESET rp_aresetn [get_bd_ports rp_aclk]
set_property CONFIG.FREQ_HZ 100000000 [get_bd_ports rp_aclk]

# AXI HWICAP: lets MicroBlaze write partial bitstreams into the internal ICAPE2 (7 series, 32-bit ICAP, 100 MHz).
set hw [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_hwicap axi_hwicap_0]
set_property CONFIG.C_ICAP_EXTERNAL 0 $hw
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list     Clk_master  /clk_wiz_0/clk_out1     Clk_slave   /clk_wiz_0/clk_out1     Clk_xbar    /clk_wiz_0/clk_out1     Master      {/microblaze_0 (Periph)}     Slave       /axi_hwicap_0/S_AXI_LITE     ddr_seg     Auto     intc_ip     /axi_smc     master_apm  0 ] [get_bd_intf_pins axi_hwicap_0/S_AXI_LITE]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_hwicap_0/icap_clk]
set hw_eos [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant const_eos]
set_property -dict [list CONFIG.CONST_VAL 1 CONFIG.CONST_WIDTH 1] $hw_eos
connect_bd_net [get_bd_pins const_eos/dout] [get_bd_pins axi_hwicap_0/eos_in]

regenerate_bd_layout
# validate intermittently fails in the MIG propagate procedure (getParamPrjVal); it passes on retry
set ok 0
for {set i 0} {$i < 4 && !$ok} {incr i} {
    if {[catch {validate_bd_design} err]} { puts "validate attempt [expr {$i+1}] failed: $err" } else { set ok 1 }
}
if {!$ok} { error "validate_bd_design failed 4 times" }
save_bd_design
puts "Address map:"
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/Data]] {
    puts "  $seg  offset=[get_property OFFSET $seg] range=[get_property RANGE $seg]"
}
make_wrapper -files [get_files ${bd_name}.bd] -top
update_compile_order -fileset sources_1
