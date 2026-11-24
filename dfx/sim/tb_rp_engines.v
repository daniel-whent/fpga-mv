`timescale 1ns/1ps
// Test bench for the stream engines. Compile with the module under test and +define+GRAY or +define+INVERT:
//   xvlog -d GRAY   dfx/rtl/rm_a/rp.v dfx/sim/tb_rp_engines.v    (grayscale, module A)
//   xvlog -d INVERT dfx/rtl/rm_b/rp.v dfx/sim/tb_rp_engines.v    (invert, module B)
module tb;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, arvalid = 0, bready = 1, rready = 1;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata, value;

    reg  [7:0]  s_tdata = 0; reg s_tvalid = 0, s_tlast = 0; wire s_tready;
    wire [7:0]  m_tdata; wire m_tvalid, m_tlast; reg m_tready = 0;

    rp dut (.s_axi_aclk(clk), .s_axi_aresetn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(1'b1), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .value(value));

    task axi_write(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
            @(posedge clk); while (!(awready && wready)) @(posedge clk);
            awvalid <= 0; wvalid <= 0;
            while (!bvalid) @(posedge clk);
            @(posedge clk);
        end
    endtask
    task axi_read(input [31:0] a, output [31:0] d);
        begin
            @(posedge clk); araddr <= a; arvalid <= 1;
            @(posedge clk); while (!arready) @(posedge clk);
            arvalid <= 0;
            while (!rvalid) @(posedge clk);
            d = rdata; @(posedge clk);
        end
    endtask

    localparam integer NPIX = 300;
    localparam integer NB = NPIX * 3;
    reg [7:0] src [0:NB-1];
    reg [7:0] exp [0:NB-1];
    integer errors = 0, got = 0, tlast_at = -1, k, p;
    integer seed = 1;

    // output checker with random back-pressure
    always @(posedge clk) begin
        m_tready <= ($random(seed) & 3) != 0;
        if (m_tvalid && m_tready) begin
            if (got < NB && m_tdata !== exp[got]) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH %0d: got %0d want %0d", got, m_tdata, exp[got]);
            end
            if (m_tlast) tlast_at = got;
            got = got + 1;
        end
    end

    task send_all(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                // random input gaps (tvalid is low during them)
                repeat ($random(seed) & 3) @(posedge clk);
                s_tdata <= src[i]; s_tvalid <= 1; s_tlast <= (i == n - 1);
                @(posedge clk); while (!s_tready) @(posedge clk);   // transfer happened at this edge
                s_tvalid <= 0; s_tlast <= 0;
            end
        end
    endtask

    reg [31:0] rd;
    initial begin
        for (k = 0; k < NB; k = k + 1) src[k] = $random(seed);
        src[0] = 8'h00; src[1] = 8'h00; src[2] = 8'h00; src[3] = 8'hFF; src[4] = 8'hFF; src[5] = 8'hFF;
        for (p = 0; p < NPIX; p = p + 1) begin : mk
            integer gg, bb, rr, y;
            gg = src[p*3]; bb = src[p*3+1]; rr = src[p*3+2];
`ifdef GRAY
            y = (77 * rr + 150 * gg + 29 * bb) >> 8;
            exp[p*3] = y; exp[p*3+1] = y; exp[p*3+2] = y;
`else
            exp[p*3] = ~src[p*3]; exp[p*3+1] = ~src[p*3+1]; exp[p*3+2] = ~src[p*3+2];
`endif
        end
        repeat (10) @(posedge clk); rstn = 1; repeat (5) @(posedge clk);
        axi_read(32'h4, rd);
`ifdef GRAY
        if (rd !== 32'hA) begin errors = errors + 1; $display("bad id %h", rd); end
`else
        if (rd !== 32'hB) begin errors = errors + 1; $display("bad id %h", rd); end
`endif
        // frame 1: processing
        send_all(NB);
        repeat (50) @(posedge clk);
        $display("frame1: got=%0d tlast_at=%0d errors=%0d value=%0d", got, tlast_at, errors, value);
        if (got != NB || tlast_at != NB - 1) begin errors = errors + 1; $display("count/tlast wrong"); end
        if (value !== NB) begin errors = errors + 1; $display("byte counter wrong"); end
        axi_read(32'h8, rd);
        if (rd !== NB) begin errors = errors + 1; $display("reg2 wrong %0d", rd); end
        // clear counter, bypass on: output must equal input
        axi_write(32'h8, 0);
        axi_write(32'h0, 1);
        axi_read(32'h0, rd);
        if (rd !== 1) begin errors = errors + 1; $display("bypass reg wrong"); end
        for (k = 0; k < NB; k = k + 1) exp[k] = src[k];
        got = 0; tlast_at = -1;
        send_all(NB);
        repeat (50) @(posedge clk);
        $display("frame2 (bypass): got=%0d tlast_at=%0d errors=%0d value=%0d", got, tlast_at, errors, value);
        if (got != NB || tlast_at != NB - 1 || value !== NB) begin errors = errors + 1; $display("bypass count/tlast wrong"); end
        if (errors == 0) $display("PASS"); else $display("FAIL errors=%0d", errors);
        $finish;
    end
endmodule
