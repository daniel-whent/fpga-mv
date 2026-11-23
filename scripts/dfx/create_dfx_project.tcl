# Create the DFX warm-up project (separate from the VGA project) in a SHORT path (MIG path-length limit).
# Run from any Vivado Tcl console (no project open), or: vivado -mode batch -source <this file>
#   source C:/Users/daniel.whent/workspace/machine-vision/scripts/dfx/create_dfx_project.tcl
# Result: C:/tmp/dfx/p/p.xpr with Stage 1 + Stage 2 + RP GPIO block design, top.v, seg7 + static RM A (rtl/rm_a).

set repo [file normalize [file dirname [info script]]/../..]
set proj_root C:/tmp/dfx
set boards   [file normalize $repo/../blob/vivado-boards/new/board_files]

file delete -force $proj_root/p
file mkdir $proj_root
set_param board.repoPaths [list $boards]
create_project p $proj_root/p -part xc7a100tcsg324-1 -force
set_property BOARD_PART digilentinc.com:nexys-a7-100t:part0:1.3 [current_project]

# MIG customization intermittently fails on Windows with 'permission denied' on a freshly written
# file (transient lock); Stage 1 rebuilds from scratch, so retry the pair.
set ok 0
for {set i 1} {$i <= 3 && !$ok} {incr i} {
    if {[catch {source $repo/scripts/create_bd_stage1.tcl; source $repo/scripts/create_bd_stage2.tcl} err]} {
        puts "WARNING: Stage 1/2 attempt $i failed: $err"
    } else { set ok 1 }
}
if {!$ok} { error "Stage 1/2 failed 3 times" }
source $repo/scripts/dfx/create_bd_rp_gpio.tcl

add_files -norecurse $repo/dfx/rtl/seg7_strobe.v $repo/dfx/rtl/rm_a/rp.v
update_compile_order -fileset sources_1
source $repo/scripts/dfx/gen_top.tcl
add_files -norecurse $repo/dfx/rtl/top.v
add_files -fileset constrs_1 -norecurse $repo/dfx/constraints/seg7.xdc
set_property top top [current_fileset]
update_compile_order -fileset sources_1
puts "DFX warm-up project ready at $proj_root/p. Milestone 1 = static design with module A."
