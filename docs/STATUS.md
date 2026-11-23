# Project status and how to pick it up on another machine

Goal: animal-type detection (heatmap output) on a Digilent Nexys A7-100T (XC7A100T), learning exercise using mostly
Vivado IP-catalog blocks. Frames come from a PC over the USB-UART bridge, are stored in DDR2 and shown on VGA;
reconfigurable partitions (DFX) will later swap detector/classifier engines. Last updated 2026-11-23.

## Tools and environment
- Vivado/Vitis 2025.2 (installed at `C:\AMDDesignTools\2025.2`), Windows, board files from Digilent
  (`vivado-boards/new/board_files`, board part `digilentinc.com:nexys-a7-100t:part0:1.3`), expected next to the repo at
  `../blob/vivado-boards` (see `BoardPartRepoPaths` in the .xpr and `scripts/create_*_project.tcl`).
- UART is on COM4 on the original machine (COM3 was the PC's Intel AMT port). 115200 8N1 for the console.
- Keep project paths SHORT: MIG generation breaks near the 260-character Windows limit. Scratch builds live in `C:/tmp/...`.
- Vitis flow: `scripts/create_vitis_hello.py` (env `APP`, `XSA`, `VITIS_WS`); needs Vivado AND Vitis `settings64.bat` loaded in
  cmd.exe. Program the board with `xsdb scripts/program_board.tcl <bit> <elf>`. If a Vitis workspace is locked, use a new
  `VITIS_WS` folder.
- When editing C sources from scripts, avoid text-mode file writes on Windows (CRLF / escape corruption).

## What works (verified on hardware)
| Stage | What | Where |
|---|---|---|
| 1 | MicroBlaze + AXI UART Lite, console | `scripts/create_bd_stage1.tcl`, `software/hello` |
| 2 | DDR2 via MIG (128 MiB at 0x80000000), GPIO LEDs/status | `create_bd_stage2.tcl`, `software/ddr2_test` |
| 3 | VGA 640x480 from DDR2 via VDMA; solid colors, bars, patterns | `create_bd_stage3_vga.tcl`, `software/vga_test` |
| DFX warm-up | AXI4-Lite reconfigurable partition behind dfx_decoupler + dfx_axi_shutdown_manager, HWICAP loader, partition reset, 7-seg display; A<->B swaps 10/10 | `scripts/dfx/*`, `dfx/`, `software/dfx_load` |

Key facts learned (all verified on the board unless noted):
- `v_axi4s_vid_out` does not zero `vid_data` in blanking; VGA colors must be ANDed with `vid_active_video` (Stage 3 does this).
  Without it solid colors blacked out on the monitor.
- A decoupler alone does not terminate bus transactions: reading a decoupled partition hangs the CPU. The shutdown manager
  answers instead (returns 0). Shutdown manager regs: write 1 = shutdown, 0 = pass-through; read bit1 = both channels shut down.
- A partial bitstream does not initialize the new module's flip-flops: pulse a local partition reset after every load.
- HWICAP: CR bits FIFO-clear (0x4) and reset (0x8) are level bits (set, wait, clear), not self-clearing; write bit 0x1 self-clears.
- DDR2 is 0x80000000..0x87FFFFFF; addresses beyond that read garbage.
- Vivado sometimes crashes at exit after a good synthesis and MIG customization fails intermittently with a transient
  "permission denied"; the scripts retry.

## Stage 4: USB frame input (WRITTEN, NOT YET TESTED ON HARDWARE)
Fast frame input over the same micro-USB cable (FTDI UART bridge) at 4 Mbaud into the DDR2 framebuffer:
`usb/rtl/usb_frame_rx.v` (simulated, passes `usb/sim/tb_usb_frame_rx.v` with xsim) -> axis_data_fifo (clock crossing) ->
AXI DMA S2MM -> DDR2 framebuffer. Block design: `scripts/create_bd_stage4_usb.tcl` (validates; GPIO ctrl/status at 0x40010000,
DMA at 0x41E00000). Board program `software/usb_frame` ('F' + 3-byte length arms the DMA, PC streams at 4 Mbaud).
PC sender `tools/send_frame.py` (needs `pip install pyserial pillow numpy`).
A scratch build of Stages 1-4 (`scripts/create_usb_project.tcl`, run with `-tclargs build`, project in C:/tmp/usb) completed:
bitstream generated, WNS +1.313 ns, and `software/usb_frame` compiles against its XSA. Not run on the board. The main project
(`fpga-ml-nexys-a7-100T`) is still at Stage 3; rebuild with `scripts/build_all.tcl` (now includes Stage 4) or the scratch script.
Next: build, program, `python tools/send_frame.py --port COM4 --pattern bars`, then a photo; measure throughput.
Speed notes: 4 Mbaud (25 clocks/bit at 100 MHz) ~0.4 MB/s, full frame ~2.3 s. FT2232H UART goes up to 12 Mbaud per its
datasheet; 10 Mbaud is 10 clocks/bit but whether the FTDI can generate it accurately is unverified (plan: measure the real
rate with a bit-timing diagnostic). Fast sync-FIFO mode is channel A only and not available for data on this board (unverified).

## Roadmap
1. Verify Stage 4 on hardware; try 10/12 Mbaud.
2. Turn the DFX partition into an AXI-stream engine (data path + AXI-Lite control) and feed it from the frame buffer
   (AXI DMA / VDMA read side).
3. PC prototype of the model: MobileNet-0.25-style fully-convolutional heatmap, fine-tuned, int8; MegaDetector V6 used on
   the PC for labels/crops only (AGPL-3.0, not on the FPGA).
4. Run a small version in the reconfigurable partition; heatmap overlay on VGA.

## Repo layout
`scripts/` Vivado/Vitis/xsdb scripts (`build_all.tcl` rebuilds Stages 1-4 + bitstream + XSA; `scripts/dfx/` the DFX project);
`constraints/` XDCs; `ip/` MIG config; `software/` MicroBlaze apps; `dfx/` DFX RTL/constraints/tools;
`usb/` USB receiver RTL + simulation; `tools/` PC-side scripts; `fpga-ml-nexys-a7-100T/` the main Vivado project
(currently reflects Stage 3; rerun `build_all.tcl` to bring it to Stage 4).
