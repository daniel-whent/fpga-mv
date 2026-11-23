# Milestone 2: turn the static warm-up project into a DFX project with two reconfigurable modules.
# Run after create_dfx_project.tcl:  vivado -mode batch -source scripts/dfx/setup_dfx.tcl
#   partition def  pd_rp  (module `rp`, instance u_rp in top)
#   modules        rm_a (pass-through), rm_b (swap 16-bit halves)
#   configurations config_a (impl_1, the full bitstream we program) and config_b (child run)
set repo [file normalize [file dirname [info script]]/../..]
open_project C:/tmp/dfx/p/p.xpr

set_property PR_FLOW 1 [current_project]
create_partition_def -name pd_rp -module rp
create_reconfig_module -name rm_a -partition_def [get_partition_defs pd_rp] -define_from rp
create_reconfig_module -name rm_b -partition_def [get_partition_defs pd_rp] -top rp
add_files -norecurse -of_objects [get_reconfig_modules rm_b] $repo/dfx/rtl/rm_b/rp.v

create_pr_configuration -name config_a -partitions [list u_rp:rm_a]
create_pr_configuration -name config_b -partitions [list u_rp:rm_b]
set_property PR_CONFIGURATION config_a [get_runs impl_1]
create_run child_0_impl_1 -parent_run impl_1 -flow {Vivado Implementation 2025} -pr_config config_b

add_files -fileset constrs_1 -norecurse $repo/dfx/constraints/dfx_floorplan.xdc
update_compile_order -fileset sources_1
puts "DFX configuration done. Next: scripts/dfx/build_dfx.tcl"
