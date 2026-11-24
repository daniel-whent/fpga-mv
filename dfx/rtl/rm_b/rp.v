`timescale 1ns/1ps
// Reconfigurable module B: INVERT stream engine (every byte -> 255 - byte, a photographic negative).
//   Pure pass-through datapath with no pixel buffering, so it keeps the stream's TLAST/handshake unchanged.
// AXI4-Lite registers (word addresses), same layout as module A:
//   0x0 (R/W) control: bit0 = bypass (1: stream passes through unchanged). Change only between frames.
//   0x4 (R)   module ID: 0xB
//   0x8 (R/W) input byte counter (any write clears it)
// `value` (7-segment display) = input byte counter.
module rp (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire [31:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    input  wire [7:0]  s_axis_tdata,
    input  wire [0:0]  s_axis_tkeep,   // always 1 for 8-bit streams, unused
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [31:0] value
);
    localparam [31:0] MODULE_ID = 32'h0000000B;

    // ------------------------------------------------------------ AXI4-Lite registers
    reg        awready = 1'b0, wready = 1'b0, bvalid = 1'b0, arready = 1'b0, rvalid = 1'b0;
    reg [31:0] rdata = 32'd0;
    reg        bypass = 1'b0;
    reg [31:0] bytes = 32'd0;
    wire       in_fire;

    assign s_axi_awready = awready;
    assign s_axi_wready  = wready;
    assign s_axi_bvalid  = bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = arready;
    assign s_axi_rvalid  = rvalid;
    assign s_axi_rdata   = rdata;
    assign s_axi_rresp   = 2'b00;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; arready <= 1'b0; rvalid <= 1'b0;
            bypass <= 1'b0; bytes <= 32'd0;
        end else begin
            awready <= 1'b0; wready <= 1'b0; arready <= 1'b0;
            if (in_fire) bytes <= bytes + 32'd1;
            if (s_axi_awvalid && s_axi_wvalid && !bvalid && !awready) begin
                awready <= 1'b1; wready <= 1'b1; bvalid <= 1'b1;
                if (s_axi_awaddr[3:2] == 2'd0 && s_axi_wstrb[0]) bypass <= s_axi_wdata[0];
                if (s_axi_awaddr[3:2] == 2'd2) bytes <= 32'd0;
            end
            if (bvalid && s_axi_bready) bvalid <= 1'b0;
            if (s_axi_arvalid && !rvalid && !arready) begin
                arready <= 1'b1; rvalid <= 1'b1;
                rdata <= (s_axi_araddr[3:2] == 2'd0) ? {31'd0, bypass} :
                         (s_axi_araddr[3:2] == 2'd1) ? MODULE_ID :
                         (s_axi_araddr[3:2] == 2'd2) ? bytes : 32'd0;
            end
            if (rvalid && s_axi_rready) rvalid <= 1'b0;
        end
    end
    assign value = bytes;

    // ------------------------------------------------------------ invert engine
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tvalid = s_axis_tvalid;
    assign m_axis_tdata  = bypass ? s_axis_tdata : ~s_axis_tdata;
    assign m_axis_tlast  = s_axis_tlast;
    assign in_fire = s_axis_tvalid && s_axis_tready;
endmodule
