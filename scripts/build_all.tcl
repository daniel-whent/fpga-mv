# Rebuild everything from the Stage 1/2/3 scripts, generate the bitstream and export the XSA.
# Run in the Vivado Tcl console with the project open:
#   source C:/Users/daniel.whent/workspace/machine-vision/scripts/build_all.tcl
# Optional: set ::build_jobs before sourcing (default 4).

set scripts_dir [file normalize [file dirname [info script]]]
set jobs 4
if {[info exists ::build_jobs]} { set jobs $::build_jobs }

foreach stage {create_bd_stage1.tcl create_bd_stage2.tcl create_bd_stage3_vga.tcl create_bd_stage4_usb.tcl} {
    puts "=== running $stage ==="
    if {[catch {source $scripts_dir/$stage} err]} {
        error "$stage failed: $err"
    }
}

puts "=== synthesis + implementation + bitstream ==="
proc run_to_bitstream {jobs} {
    reset_run synth_1
    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    return [catch {wait_on_run impl_1} err]
}
# A Vivado process crash at exit (seen once: EXCEPTION_ACCESS_VIOLATION after a successful synth_design)
# marks the run failed even though it finished; retry once before giving up.
if {[run_to_bitstream $jobs]} {
    puts "WARNING: run failed, retrying once"
    run_to_bitstream $jobs
}

set status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $status"
if {![string match "*write_bitstream Complete*" $status]} {
    error "Bitstream generation did not complete: $status"
}

puts "=== exporting XSA ==="
source $scripts_dir/export_xsa.tcl
puts "=== build_all done ==="
