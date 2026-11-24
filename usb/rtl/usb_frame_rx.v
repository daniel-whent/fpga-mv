`timescale 1ns/1ps
// Fast UART receiver that turns a frame of bytes into an AXI4-Stream packet (feeds an AXI DMA S2MM).
//   ctrl[31]     enable (rising edge starts a new frame: counters, flags cleared). Bytes are ignored while 0,
//                which lets the slow 115200 command traffic on the same RX pin pass unnoticed.
//   ctrl[30:20]  bit period in 1/16 clock cycles (100 MHz clock: 4 Mbaud = 400, 6 Mbaud = 267, 8 Mbaud = 200,
//                12 Mbaud = 133). 0 selects 400 (4 Mbaud).
//   ctrl[19:0]   frame length in bytes (max 1048575). TLAST is asserted on the last byte; later bytes are ignored.
//   status[0]    overflow (a byte arrived while the previous one was not yet accepted) - sticky until re-enable
//   status[1]    frame_done (all bytes received)     status[2] framing_error seen (sticky)
//   status[31:8] bytes received so far
// 8N1. Sampling instants come from a fractional phase accumulator restarted on every start bit, so non-integer
// clocks-per-bit ratios (e.g. 100 MHz / 12 Mbaud = 8.33) are handled without drift.
module usb_frame_rx #(parameter integer CLKS_PER_BIT = 25 /* unused: the bit period now comes from ctrl[30:20] */) (
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

    // ---- bit-period phase accumulator (units of 1/16 clock)
    wire [10:0] period_f = (ctrl[30:20] == 11'd0) ? 11'd400 : ctrl[30:20];
    reg  [10:0] period = 11'd400;
    always @(posedge clk) if (start_frame) period <= period_f;

    // ---- UART receiver
    reg [1:0]  state = 2'd0;          // 0 idle, 1 start, 2 data, 3 stop
    reg [11:0] ph = 12'd0;
    reg [2:0]  bitn = 3'd0;
    reg [7:0]  shreg = 8'd0;
    reg        byte_ready = 1'b0;
    reg [7:0]  byte_data = 8'd0;
    reg        ferr = 1'b0;

    wire [11:0] ph_next = ph + 12'd16;
    wire        tick    = (ph_next >= {1'b0, period});

    always @(posedge clk) begin
        byte_ready <= 1'b0;
        if (!rst_n) begin
            state <= 2'd0; ph <= 12'd0; ferr <= 1'b0;
        end else begin
            if (start_frame) ferr <= 1'b0;
            if (state != 2'd0) ph <= tick ? (ph_next - {1'b0, period}) : ph_next;
            case (state)
            2'd0: if (rx == 1'b0) begin state <= 2'd1; ph <= {2'b0, period[10:1]}; end   // first tick after half a bit
            2'd1: if (tick) begin                              // confirm start bit at its middle
                if (rx == 1'b0) begin state <= 2'd2; bitn <= 3'd0; end
                else state <= 2'd0;
            end
            2'd2: if (tick) begin
                shreg <= {rx, shreg[7:1]};                     // LSB first
                if (bitn == 3'd7) state <= 2'd3; else bitn <= bitn + 3'd1;
            end
            2'd3: if (tick) begin
                state <= 2'd0;
                if (rx == 1'b1) begin byte_ready <= 1'b1; byte_data <= shreg; end
                else ferr <= 1'b1;
            end
            endcase
        end
    end

    // ---- frame logic and AXI4-Stream output (single byte holding register)
    reg [23:0] count = 24'd0;
    reg        done = 1'b0, ovf = 1'b0;
    reg        tvalid = 1'b0, tlast = 1'b0;
    reg [7:0]  tdata = 8'd0;
    wire [23:0] frame_len = {4'd0, ctrl[19:0]};

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
