# Export the implemented design as a fixed hardware platform (.xsa) including the bitstream.
# Run in the Vivado Tcl console with the project open and impl_1 complete:
#   source C:/Users/daniel.whent/workspace/machine-vision/scripts/export_xsa.tcl

set proj_dir [get_property DIRECTORY [current_project]]
set out_dir  [file normalize $proj_dir/../hw_export]
file mkdir $out_dir

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: impl_1 is not complete. Run Generate Bitstream first."
    return
}

open_run impl_1
write_hw_platform -fixed -include_bit -force $out_dir/system_wrapper.xsa
puts "Wrote $out_dir/system_wrapper.xsa"
