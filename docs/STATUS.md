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

| DFX streaming | Partition with AXI4-Lite control + 8-bit AXI4-Stream in/out behind the decoupler; AXI DMA (MM2S+S2MM) moves a 640x480x3 frame DDR2 -> partition -> DDR2; RM A = grayscale, RM B = invert, bypass register; every output byte checked by the MicroBlaze; 10/10 swaps + full-frame checks | `scripts/dfx/create_bd_rp_stream.tcl`, `dfx/rtl/rm_a|rm_b/rp.v`, `dfx/sim/tb_rp_engines.v`, `software/dfx_stream` |

DFX streaming details (verified 2026-11-24): frame time ~19.9 ms with grayscale (7 clocks per pixel), ~10.5 ms for invert/bypass;
timing WNS +1.17 / +0.89 ns (config A / B), `pr_verify` compatible. Build: `scripts/dfx/create_dfx_project.tcl`, then
`setup_dfx.tcl` + `build_dfx.tcl` (about 20 min), `export_dfx_xsa.tcl`, `dfx/tools/bit2words.py` for both partial bitstreams,
`APP=dfx_stream XSA=C:/tmp/dfx/dfx.xsa` with `create_vitis_hello.py`, then `scripts/dfx/load_and_run.tcl` and talk to the board
on the UART (commands: a/b swap+test, g test, z bypass, f new source, i info). This DFX project is separate from the VGA/USB
design (no display yet); `software/dfx_load` belongs to the earlier register-only partition (commit abc8541). Partition
register map now: 0x0 control (bit0 bypass), 0x4 module id, 0x8 input byte counter. Gotchas: the async `axis_data_fifo` has a
single reset pin (`s_axis_aresetn`); the decoupler stream interfaces take TKEEP from the DMA (MODE slave = static side drives);
the DMA's data address spaces must have every peripheral segment excluded explicitly.

NOT YET RUN: the AXI Timer (0x41C00000) in `create_bd_rp_stream.tcl` and the timing/benchmark code in `software/dfx_stream`
(microsecond frame time, per-swap timing, command `t`) were added after the verified build. The project validates, but the
bitstream with the timer was still building when this was pushed. To resume: `scripts/dfx/create_dfx_project.tcl`, then
`setup_dfx.tcl` + `build_dfx.tcl`, `export_dfx_xsa.tcl`, `bit2words.py` (both partials), build `dfx_stream`, `load_and_run.tcl`,
then send `t` on the UART to get the swap times and compare with the frame times.

Decision 2026-11-24: ONE reconfigurable partition shared by the detector and the classifier (they replace each other in the
same slot; never resident together). The swap time is measured by `software/dfx_stream` command `t` (AXI Timer stopwatch)
so we know what a detector -> classifier switch costs; the engine region must be sized for the larger engine.

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

## Stage 4: USB frame input (VERIFIED on hardware 2026-11-24: 5/5 frames, 921600 bytes each, no overflow/framing errors,
## up to 12 Mbaud, 0.78 s per frame; monitor check of the picture still to be confirmed by the user)
The board must delay its `D` reply until the PC has switched back to 115200 (the app now waits 200 ms); without it the reply
was sometimes read at the wrong baud rate.
Fast frame input over the same micro-USB cable (FTDI UART bridge) at 4 Mbaud into the DDR2 framebuffer:
`usb/rtl/usb_frame_rx.v` (simulated, passes `usb/sim/tb_usb_frame_rx.v` with xsim) -> axis_data_fifo (clock crossing) ->
AXI DMA S2MM -> DDR2 framebuffer. Block design: `scripts/create_bd_stage4_usb.tcl` (validates; GPIO ctrl/status at 0x40010000,
DMA at 0x41E00000). Board program `software/usb_frame` ('F' + 3-byte length arms the DMA, PC streams at 4 Mbaud).
PC sender `tools/send_frame.py` (needs `pip install pyserial pillow numpy`).
A scratch build of Stages 1-4 (`scripts/create_usb_project.tcl`, run with `-tclargs build`, project in C:/tmp/usb) completed:
bitstream generated, WNS +1.313 ns, and `software/usb_frame` compiles against its XSA. Not run on the board. The main project
(`fpga-ml-nexys-a7-100T`) is still at Stage 3; rebuild with `scripts/build_all.tcl` (now includes Stage 4) or the scratch script.
Next: build, program, `python tools/send_frame.py --port COM4 --pattern bars`, then a photo; measure throughput.
Speed (verified 2026-11-24 with a 921600-byte ramp checked byte-for-byte on the board, `send_frame.py --pattern ramp`):
4 Mbaud 2.31 s/frame (400 kB/s), 6 Mbaud 1.54 s, 8 Mbaud 1.16 s, 12 Mbaud 0.78 s (1187 kB/s) - all 0 bad bytes, 12 Mbaud is
the FT2232H maximum and is now the default. 10 Mbaud was not tried. The receiver takes the bit period (1/16 clock units) from
ctrl[30:20], so non-integer ratios work (12 Mbaud = 8.33 clocks); the PC sends it in the 'F' command. The fast stream also
reaches the console UART as noise (can decode as commands), so the board flushes that FIFO before replying.
Fast sync-FIFO mode is channel A only and not available for data on this board (unverified).

## Roadmap
1. Stage 4 verified up to 12 Mbaud (0.78 s per frame). Remaining: confirm a real photo looks right on the monitor.
2. DONE (grayscale + invert stream engines, verified). Next: merge the streaming partition into the VGA + USB design so
   the engine output is shown on the monitor (frame in over USB -> engine -> VGA), then a stateful engine with line
   buffers (e.g. 3x3 Sobel edge detector) as a more realistic second module.
3. PC prototype of the model, NO TRAINING (decision 2026-11-24): pretrained ImageNet MobileNet (0.25-width, 128x128) with
   post-training int8 quantization only; heatmap by dropping the global pooling so the 1x1 classifier gives a per-region
   score grid (sum of the animal classes = heatmap). MegaDetector is not used.
4. Run a small version in the reconfigurable partition; heatmap overlay on VGA.

## Repo layout
`scripts/` Vivado/Vitis/xsdb scripts (`build_all.tcl` rebuilds Stages 1-4 + bitstream + XSA; `scripts/dfx/` the DFX project);
`constraints/` XDCs; `ip/` MIG config; `software/` MicroBlaze apps; `dfx/` DFX RTL/constraints/tools;
`usb/` USB receiver RTL + simulation; `tools/` PC-side scripts; `fpga-ml-nexys-a7-100T/` the main Vivado project
(currently reflects Stage 3; rerun `build_all.tcl` to bring it to Stage 4).
