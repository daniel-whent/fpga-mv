// Strobed 8-digit hex display driver for the Nexys A7 (common-anode, active-low segments and anodes).
// Each digit is lit for 2^14 clocks in turn (about 6.1 kHz per digit at 100 MHz, 763 Hz full refresh).
module seg7_strobe (
    input  wire        clk,
    input  wire [31:0] value,       // digit 0 (rightmost) = value[3:0]
    output reg  [6:0]  seg_n,       // {CG,CF,CE,CD,CC,CB,CA}, active low
    output wire        dp_n,
    output reg  [7:0]  an_n         // active low
);
    reg [16:0] cnt = 17'd0;
    always @(posedge clk) cnt <= cnt + 17'd1;

    wire [2:0] sel = cnt[16:14];
    reg  [3:0] nib;
    always @* begin
        nib  = value[sel*4 +: 4];
        an_n = ~(8'b1 << sel);
    end

    // active-high pattern {g,f,e,d,c,b,a}
    reg [6:0] pat;
    always @* begin
        case (nib)
            4'h0: pat = 7'h3F;  4'h1: pat = 7'h06;  4'h2: pat = 7'h5B;  4'h3: pat = 7'h4F;
            4'h4: pat = 7'h66;  4'h5: pat = 7'h6D;  4'h6: pat = 7'h7D;  4'h7: pat = 7'h07;
            4'h8: pat = 7'h7F;  4'h9: pat = 7'h6F;  4'hA: pat = 7'h77;  4'hB: pat = 7'h7C;
            4'hC: pat = 7'h39;  4'hD: pat = 7'h5E;  4'hE: pat = 7'h79;  default: pat = 7'h71;
        endcase
        seg_n = ~pat;
    end
    assign dp_n = 1'b1;
endmodule
