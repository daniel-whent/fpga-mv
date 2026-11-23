# Full DFX warm-up build from nothing: project + BD, DFX setup, both configurations.
#   vivado -mode batch -source scripts/dfx/run_all_dfx.tcl      (outputs under C:/tmp/dfx/p)
set d [file dirname [info script]]
source $d/create_dfx_project.tcl
close_project
source $d/setup_dfx.tcl
close_project
source $d/build_dfx.tcl
