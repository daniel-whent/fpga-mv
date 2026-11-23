`timescale 1ns/1ps
// Fast UART receiver that turns a frame of bytes into an AXI4-Stream packet (feeds an AXI DMA S2MM).
//   ctrl[31]    enable (rising edge starts a new frame: counters, flags cleared). Bytes are ignored while 0,
//               which lets the slow 115200 command traffic on the same RX pin pass unnoticed.
//   ctrl[23:0]  frame length in bytes. TLAST is asserted on the last byte; later bytes are ignored.
//   status[0]   overflow (a byte arrived while the previous one was not yet accepted) - sticky until re-enable
//   status[1]   frame_done (all bytes received)     status[2] framing_error seen (sticky)
//   status[31:8] bytes received so far
// 8N1, CLKS_PER_BIT = clk_hz / baud (100 MHz / 4 Mbaud = 25).
module usb_frame_rx #(parameter integer CLKS_PER_BIT = 25) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
    input  wire        clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST", X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        rst_n,
    input  wire        rxd,
    input  wire [31:0] ctrl,
    output wire [31:0] status,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [7:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire        m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire        m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output wire        m_axis_tlast
);
    // ---- input synchronizer and enable edge detect
    reg [2:0] rx_sync = 3'b111;
    reg       en_d = 1'b0;
    always @(posedge clk) begin
        rx_sync <= {rx_sync[1:0], rxd};
        en_d    <= ctrl[31];
    end
    wire rx = rx_sync[2];
    wire start_frame = ctrl[31] & ~en_d;

    // ---- UART receiver
    localparam integer HALF = CLKS_PER_BIT / 2;
    reg [1:0]  state = 2'd0;          // 0 idle, 1 start, 2 data, 3 stop
    reg [15:0] cnt = 16'd0;
    reg [2:0]  bitn = 3'd0;
    reg [7:0]  shreg = 8'd0;
    reg        byte_ready = 1'b0;
    reg [7:0]  byte_data = 8'd0;
    reg        ferr = 1'b0;

    always @(posedge clk) begin
        byte_ready <= 1'b0;
        if (!rst_n) begin
            state <= 2'd0; cnt <= 16'd0; ferr <= 1'b0;
        end else begin
            if (start_frame) ferr <= 1'b0;
            case (state)
            2'd0: if (rx == 1'b0) begin state <= 2'd1; cnt <= 16'd0; end
            2'd1: begin                                   // confirm start bit at its middle
                if (cnt == HALF - 1) begin
                    if (rx == 1'b0) begin state <= 2'd2; cnt <= 16'd0; bitn <= 3'd0; end
                    else state <= 2'd0;
                end else cnt <= cnt + 16'd1;
            end
            2'd2: begin
                if (cnt == CLKS_PER_BIT - 1) begin
                    cnt <= 16'd0;
                    shreg <= {rx, shreg[7:1]};            // LSB first
                    if (bitn == 3'd7) state <= 2'd3; else bitn <= bitn + 3'd1;
                end else cnt <= cnt + 16'd1;
            end
            2'd3: begin
                if (cnt == CLKS_PER_BIT - 1) begin
                    state <= 2'd0;
                    if (rx == 1'b1) begin byte_ready <= 1'b1; byte_data <= shreg; end
                    else ferr <= 1'b1;
                end else cnt <= cnt + 16'd1;
            end
            endcase
        end
    end

    // ---- frame logic and AXI4-Stream output (single byte holding register)
    reg [23:0] count = 24'd0;
    reg        done = 1'b0, ovf = 1'b0;
    reg        tvalid = 1'b0, tlast = 1'b0;
    reg [7:0]  tdata = 8'd0;
    wire [23:0] frame_len = ctrl[23:0];

    always @(posedge clk) begin
        if (!rst_n || start_frame) begin
            count <= 24'd0; done <= 1'b0; ovf <= 1'b0; tvalid <= 1'b0; tlast <= 1'b0;
        end else begin
            if (tvalid && m_axis_tready) tvalid <= 1'b0;
            if (byte_ready && ctrl[31] && !done) begin
                if (tvalid && !m_axis_tready) ovf <= 1'b1;
                else begin
                    tdata  <= byte_data;
                    tvalid <= 1'b1;
                    count  <= count + 24'd1;
                    tlast  <= (count + 24'd1 == frame_len);
                    if (count + 24'd1 == frame_len) done <= 1'b1;
                end
            end
        end
    end

    assign m_axis_tdata  = tdata;
    assign m_axis_tvalid = tvalid;
    assign m_axis_tlast  = tlast;
    assign status = {count, 5'd0, ferr, done, ovf};
endmodule
