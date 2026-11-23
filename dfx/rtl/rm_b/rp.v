// Reconfigurable module B: AXI4-Lite slave with two registers (module half-swap).
//   0x0 (R/W) value register
//   0x4 (R)   module ID: 0xB
// `value` drives the 7-segment display: the value register with its two 16-bit halves swapped
// (The AXI logic is identical in both modules; only ID and the value mapping differ.)
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
    output wire [31:0] value
);
    localparam [31:0] MODULE_ID = 32'h0000000B;
    reg        awready = 1'b0, wready = 1'b0, bvalid = 1'b0, arready = 1'b0, rvalid = 1'b0;
    reg [31:0] r0 = 32'd0, rdata = 32'd0;

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
        end else begin
            awready <= 1'b0; wready <= 1'b0; arready <= 1'b0;
            if (s_axi_awvalid && s_axi_wvalid && !bvalid && !awready) begin
                awready <= 1'b1; wready <= 1'b1; bvalid <= 1'b1;
                if (s_axi_awaddr[3:2] == 2'd0) begin
                    if (s_axi_wstrb[0]) r0[7:0]   <= s_axi_wdata[7:0];
                    if (s_axi_wstrb[1]) r0[15:8]  <= s_axi_wdata[15:8];
                    if (s_axi_wstrb[2]) r0[23:16] <= s_axi_wdata[23:16];
                    if (s_axi_wstrb[3]) r0[31:24] <= s_axi_wdata[31:24];
                end
            end
            if (bvalid && s_axi_bready) bvalid <= 1'b0;
            if (s_axi_arvalid && !rvalid && !arready) begin
                arready <= 1'b1; rvalid <= 1'b1;
                rdata <= (s_axi_araddr[3:2] == 2'd0) ? r0 : (s_axi_araddr[3:2] == 2'd1) ? MODULE_ID : 32'd0;
            end
            if (rvalid && s_axi_rready) rvalid <= 1'b0;
        end
    end

    assign value = {r0[15:0], r0[31:16]};
endmodule
