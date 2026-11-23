# Build both configurations (full bitstream for config_a, partial bitstreams for both).
open_project C:/tmp/dfx/p/p.xpr
reset_run synth_1
launch_runs impl_1 child_0_impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
wait_on_run child_0_impl_1
puts "impl_1: [get_property STATUS [get_runs impl_1]]"
puts "child_0_impl_1: [get_property STATUS [get_runs child_0_impl_1]]"
