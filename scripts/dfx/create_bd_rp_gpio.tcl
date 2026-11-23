# DFX warm-up: after Stage 1 and Stage 2, add a 32-bit GPIO that feeds the reconfigurable partition.
#   rp_din  (output, 32 bit) = GPIO channel 1, written by software, goes INTO the reconfigurable module
#   rp_dout (input,  32 bit) = GPIO channel 2, comes OUT of the reconfigurable module (software can read it back)
# The reconfigurable module and the 7-segment driver live in RTL (dfx/rtl); this script only builds the BD part.

set bd_name system
if {[llength [get_bd_cells -quiet axi_gpio_rp]] > 0} { puts "ERROR: already applied"; return }
open_bd_design [get_files ${bd_name}.bd]

set g [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_rp]
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
    Slave       /axi_gpio_rp/S_AXI \
    ddr_seg     Auto \
    intc_ip     /axi_smc \
    master_apm  0 \
] [get_bd_intf_pins axi_gpio_rp/S_AXI]

create_bd_port -dir O -from 31 -to 0 rp_din
connect_bd_net [get_bd_pins axi_gpio_rp/gpio_io_o] [get_bd_ports rp_din]
create_bd_port -dir I -from 31 -to 0 rp_dout
connect_bd_net [get_bd_ports rp_dout] [get_bd_pins axi_gpio_rp/gpio2_io_i]

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
