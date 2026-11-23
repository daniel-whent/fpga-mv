// Reconfigurable module B: swaps the two 16-bit halves. 0x12345678 in -> 0x56781234 out.
module rp (
    input  wire [31:0] din,
    output wire [31:0] dout
);
    assign dout = {din[15:0], din[31:16]};
endmodule
