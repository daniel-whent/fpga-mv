`timescale 1ns/1ps
module tb;
    reg clk = 0, rst_n = 0, rxd = 1;
    reg [31:0] ctrl = 0;
    wire [31:0] status;
    wire [7:0] tdata; wire tvalid, tlast; reg tready = 1;
    usb_frame_rx #(.CLKS_PER_BIT(25)) dut (.clk(clk), .rst_n(rst_n), .rxd(rxd), .ctrl(ctrl), .status(status),
        .m_axis_tdata(tdata), .m_axis_tvalid(tvalid), .m_axis_tready(tready), .m_axis_tlast(tlast));
    always #5 clk = ~clk;                       // 100 MHz

    integer got = 0, errors = 0, last_seen = -1;
    reg [7:0] expected [0:15];
    always @(posedge clk) if (tvalid && tready) begin
        if (got < 16 && tdata !== expected[got]) begin errors = errors + 1; $display("MISMATCH %0d: got %h want %h", got, tdata, expected[got]); end
        if (tlast) last_seen = got;
        got = got + 1;
    end

    task send_byte(input [7:0] b, input integer bitclks);
        integer i;
        begin
            rxd = 0; repeat (bitclks) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin rxd = b[i]; repeat (bitclks) @(posedge clk); end
            rxd = 1; repeat (bitclks) @(posedge clk);
        end
    endtask

    always @(posedge clk) if (dut.start_frame) $display("%0t start_frame count=%0d done=%b", $time, dut.count, dut.done);
    always @(posedge clk) if (!rst_n) $display("%0t in reset", $time);
    integer k;
    initial begin
        for (k = 0; k < 16; k = k + 1) expected[k] = 8'h10 + k * 8'h11;
        repeat (20) @(posedge clk); rst_n = 1; repeat (20) @(posedge clk);
        // slow 115200-like traffic while disabled (868 clocks per bit at 100 MHz): must be ignored
        send_byte(8'h46, 868); send_byte(8'hA5, 868);
        if (got != 0) begin errors = errors + 1; $display("received bytes while disabled"); end
        // arm: 12-byte frame, then send 16 bytes (4 extra after the frame end must be ignored)
        repeat (500) @(posedge clk);                       // let the receiver return to idle (as the real PC gap does)
        ctrl <= {1'b1, 7'd0, 24'd12}; repeat (10) @(posedge clk);
        for (k = 0; k < 16; k = k + 1) send_byte(expected[k], 25);
        repeat (100) @(posedge clk);
        $display("got=%0d last_at=%0d status=%h", got, last_seen, status);
        if (got != 12) begin errors = errors + 1; $display("expected 12 bytes"); end
        if (last_seen != 11) begin errors = errors + 1; $display("tlast not on byte 12"); end
        if (status[1] !== 1'b1 || status[0] !== 1'b0 || status[2] !== 1'b0) begin errors = errors + 1; $display("bad status flags"); end
        if (status[31:8] !== 24'd12) begin errors = errors + 1; $display("bad count"); end
        // overflow check: stall tready, send two back-to-back bytes after a re-arm
        ctrl <= 0; repeat (10) @(posedge clk);
        got = 0; tready = 0;
        ctrl <= {1'b1, 7'd0, 24'd8}; repeat (10) @(posedge clk);
        $display("armed2: ctrl=%h en_d=%b count=%0d done=%b", ctrl, dut.en_d, dut.count, dut.done);
        send_byte(8'h11, 25);
        $display("after byte1: count=%0d tvalid=%b ovf=%b state=%0d", dut.count, dut.tvalid, dut.ovf, dut.state);
        send_byte(8'h22, 25);
        repeat (50) @(posedge clk);
        $display("overflow phase: status=%h tvalid=%b", status, tvalid);
        if (status[0] !== 1'b1) begin errors = errors + 1; $display("overflow not flagged"); end
        if (errors == 0) $display("PASS"); else $display("FAIL errors=%0d", errors);
        $finish;
    end
endmodule
