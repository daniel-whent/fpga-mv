# xsdb: program config A full bitstream, download the loader ELF, put both partial images in DDR2, run.
# Usage: xsdb scripts/dfx/load_and_run.tcl <full.bit> <loader.elf> <rm_a.bin> <rm_b.bin>
lassign $argv bit elf rma rmb
connect
targets -set -nocase -filter {name =~ "xc7a100t*"}
fpga -file $bit
after 3000
targets -set -nocase -filter {name =~ "MicroBlaze #0"}
catch {stop}
dow $elf
dow -data $rma 0x87000000
dow -data $rmb 0x87100000
con
puts "Running."
