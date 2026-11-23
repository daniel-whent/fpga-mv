# Milestone 1: build the DFX warm-up project as a plain static design (module A), bitstream + XSA.
#   vivado -mode batch -source scripts/dfx/build_static.tcl
open_project C:/tmp/dfx/p/p.xpr
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
puts "impl_1: $st"
if {![string match "*write_bitstream Complete*" $st]} { error "build failed: $st" }
open_run impl_1
report_timing_summary -file C:/tmp/dfx/timing.rpt
write_hw_platform -fixed -include_bit -force C:/tmp/dfx/static.xsa
puts "BUILD OK"
