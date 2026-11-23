# Create a scratch project (short path, MIG path-length limit) with Stages 1-4 and optionally build it.
#   vivado -mode batch -source scripts/create_usb_project.tcl            (project + block design only)
#   set ::do_build 1 before sourcing (or -tclargs build) to also run synthesis/implementation/bitstream + XSA.
set repo [file normalize [file dirname [info script]]/..]
set proj_root C:/tmp/usb
set boards [file normalize $repo/../blob/vivado-boards/new/board_files]
set do_build [expr {[info exists ::do_build] ? $::do_build : ([llength $::argv] > 0 && [lindex $::argv 0] eq "build")}]

file delete -force $proj_root/p
file mkdir $proj_root
set_param board.repoPaths [list $boards]
create_project p $proj_root/p -part xc7a100tcsg324-1 -force
set_property BOARD_PART digilentinc.com:nexys-a7-100t:part0:1.3 [current_project]

# MIG customization intermittently fails on Windows (transient file locks); Stage 1 rebuilds from scratch, so
# retry the whole sequence.
set ok 0
for {set i 1} {$i <= 3 && !$ok} {incr i} {
    if {[catch {
        source $repo/scripts/create_bd_stage1.tcl
        source $repo/scripts/create_bd_stage2.tcl
        source $repo/scripts/create_bd_stage3_vga.tcl
        source $repo/scripts/create_bd_stage4_usb.tcl
    } err]} { puts "WARNING: attempt $i failed: $err" } else { set ok 1 }
}
if {!$ok} { error "Stages 1-4 failed 3 times" }

if {$do_build} {
    reset_run synth_1
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    set st [get_property STATUS [get_runs impl_1]]
    puts "impl_1: $st"
    if {![string match "*write_bitstream Complete*" $st]} { error "build failed: $st" }
    open_run impl_1
    report_timing_summary -file $proj_root/timing.rpt
    write_hw_platform -fixed -include_bit -force $proj_root/usb.xsa
    puts "BUILD OK"
}
