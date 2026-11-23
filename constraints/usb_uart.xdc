# USB-UART bridge pins (Nexys A7-100T, from the Digilent board file part0_pins.xml).
# usb_uart_rxd = FPGA input (data from the PC), usb_uart_txd = FPGA output (data to the PC).
set_property -dict { PACKAGE_PIN C4 IOSTANDARD LVCMOS33 } [get_ports usb_uart_rxd]
set_property -dict { PACKAGE_PIN D4 IOSTANDARD LVCMOS33 } [get_ports usb_uart_txd]
