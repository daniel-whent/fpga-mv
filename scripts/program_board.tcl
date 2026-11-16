# Program the FPGA and run a MicroBlaze ELF.
# Usage (from a Vitis shell):
#   xsdb C:/Users/daniel.whent/workspace/machine-vision/scripts/program_board.tcl <bitstream.bit> <program.elf>
# Example:
#   xsdb scripts/program_board.tcl fpga-ml-nexys-a7-100T/fpga-ml-nexys-a7-100T.runs/impl_1/system_wrapper.bit vitis_ws/hello/build/hello.elf

if {$argc != 2} {
    puts "usage: xsdb program_board.tcl <bitstream.bit> <program.elf>"
    exit 1
}
lassign $argv bit elf

connect
puts "Targets:"
targets

# Configure the FPGA (JTAG chain device filter: the Artix-7)
targets -set -nocase -filter {name =~ "xc7a100t*"}
fpga -file $bit

# MicroBlaze appears after configuration, via the MDM
targets -set -nocase -filter {name =~ "*MicroBlaze*#0"}
dow $elf
con
puts "Running. Open a serial terminal on the board's USB-UART at 115200 8N1."
