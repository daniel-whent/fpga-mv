// Reconfigurable module A: pass-through. The display shows exactly what software wrote.
module rp (
    input  wire [31:0] din,
    output wire [31:0] dout
);
    assign dout = din;
endmodule
