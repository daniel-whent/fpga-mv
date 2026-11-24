`timescale 1ns/1ps
module tb;
    reg clk = 0, rst_n = 0, rxd = 1;
    reg [31:0] ctrl = 0;
    wire [31:0] status;
    wire [7:0] tdata; wire tvalid, tlast; reg tready = 1;
    usb_frame_rx dut (.clk(clk), .rst_n(rst_n), .rxd(rxd), .ctrl(ctrl), .status(status),
        .m_axis_tdata(tdata), .m_axis_tvalid(tvalid), .m_axis_tready(tready), .m_axis_tlast(tlast));
    always #5 clk = ~clk;                       // 100 MHz

    integer got = 0, errors = 0, last_seen = -1;
    reg [7:0] expected [0:255];
    always @(posedge clk) if (tvalid && tready) begin
        if (got < 256 && tdata !== expected[got]) begin errors = errors + 1; $display("MISMATCH %0d: got %h want %h", got, tdata, expected[got]); end
        if (tlast) last_seen = got;
        got = got + 1;
    end

    // bit time in ns (real), e.g. 250.0 for 4 Mbaud, 83.333 for 12 Mbaud
    task send_byte(input [7:0] b, input real bit_ns);
        integer i;
        begin
            rxd = 0; #(bit_ns);
            for (i = 0; i < 8; i = i + 1) begin rxd = b[i]; #(bit_ns); end
            rxd = 1; #(bit_ns);
        end
    endtask

    // one frame of n bytes at the given rate; period16 = 16 * clocks per bit
    task run_frame(input integer n, input real bit_ns, input integer period16, input integer extra);
        integer j;
        begin
            ctrl <= 0; repeat (10) @(posedge clk);
            got = 0; last_seen = -1;
            ctrl <= (32'h80000000 | (period16 << 20) | n); repeat (10) @(posedge clk);
            for (j = 0; j < n + extra; j = j + 1) send_byte(expected[j], bit_ns);
            repeat (100) @(posedge clk);
            $display("rate period16=%0d: got=%0d last_at=%0d status=%h", period16, got, last_seen, status);
            if (got != n) begin errors = errors + 1; $display("expected %0d bytes", n); end
            if (last_seen != n - 1) begin errors = errors + 1; $display("tlast not on last byte"); end
            if (status[1] !== 1'b1 || status[0] !== 1'b0 || status[2] !== 1'b0) begin errors = errors + 1; $display("bad status flags"); end
            if (status[31:8] !== n) begin errors = errors + 1; $display("bad count"); end
        end
    endtask

    integer k;
    initial begin
        for (k = 0; k < 256; k = k + 1) expected[k] = (k * 37 + 5) & 8'hFF;
        expected[0] = 8'h00; expected[1] = 8'hFF; expected[2] = 8'h55; expected[3] = 8'hAA; expected[4] = 8'h80; expected[5] = 8'h01;
        repeat (20) @(posedge clk); rst_n = 1; repeat (20) @(posedge clk);
        // slow 115200-like traffic while disabled: must be ignored
        send_byte(8'h46, 8680.0); send_byte(8'hA5, 8680.0);
        if (got != 0) begin errors = errors + 1; $display("received bytes while disabled"); end
        repeat (500) @(posedge clk);
        run_frame(12, 250.0,   400, 4);     //  4 Mbaud
        run_frame(40, 250.0,     0, 0);     //  period 0 selects 4 Mbaud
        run_frame(100, 166.667, 267, 0);    //  6 Mbaud
        run_frame(100, 125.0,   200, 0);    //  8 Mbaud
        run_frame(200, 83.333,  133, 0);    // 12 Mbaud
        // 2% fast / slow sender at 12 Mbaud (FTDI divisor tolerance)
        run_frame(100, 81.667,  133, 0);
        run_frame(100, 85.0,    133, 0);
        // overflow check: stall tready, send two back-to-back bytes after a re-arm
        ctrl <= 0; repeat (10) @(posedge clk);
        got = 0; tready = 0;
        ctrl <= (32'h80000000 | 8); repeat (10) @(posedge clk);
        send_byte(8'h11, 250.0);
        send_byte(8'h22, 250.0);
        repeat (50) @(posedge clk);
        if (status[0] !== 1'b1) begin errors = errors + 1; $display("overflow not flagged"); end
        if (errors == 0) $display("PASS"); else $display("FAIL errors=%0d", errors);
        $finish;
    end
endmodule
