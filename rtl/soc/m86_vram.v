/*
 * Mach86 SoC -- the text screen's memory, B8000h to B8FFFh.
 *
 * The CPU's side is m86_mem.v's: four byte lanes, one, two or four
 * bytes at any address in a cycle. The display's side reads one
 * character vcell, {attribute, character}, on its own clock: vcell c is
 * the two bytes at 2c, so it is lanes 0 and 1 or lanes 2 and 3 at
 * index c / 2.
 */
module m86_vram (
    input  wire        clk,
    input  wire [11:0] addr,
    input  wire        we,
    input  wire [1:0]  wsize,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,

    input  wire        vclk,
    input  wire [10:0] vcell,
    output wire [15:0] vcell_q       // a cycle later
);
    reg [7:0] lane0 [0:1023];
    reg [7:0] lane1 [0:1023];
    reg [7:0] lane2 [0:1023];
    reg [7:0] lane3 [0:1023];
    reg [7:0] q0, q1, q2, q3;
    reg [1:0] rot;

    wire [1:0] a  = addr[1:0];
    wire [9:0] w  = addr[11:2];
    wire [9:0] w1 = w + 1'b1;
    wire [2:0] n  = (wsize == 2'd0) ? 3'd1 : (wsize == 2'd1) ? 3'd2 : 3'd4;
    wire [1:0] b0 = 2'd0 - a, b1 = 2'd1 - a, b2 = 2'd2 - a, b3 = 2'd3 - a;
    wire [9:0] i0 = (a > 2'd0) ? w1 : w;
    wire [9:0] i1 = (a > 2'd1) ? w1 : w;
    wire [9:0] i2 = (a > 2'd2) ? w1 : w;
    wire [9:0] i3 = w;

    always @(posedge clk) begin
        if (we && {1'b0, b0} < n) lane0[i0] <= wdata[8*b0 +: 8];
        if (we && {1'b0, b1} < n) lane1[i1] <= wdata[8*b1 +: 8];
        if (we && {1'b0, b2} < n) lane2[i2] <= wdata[8*b2 +: 8];
        if (we && {1'b0, b3} < n) lane3[i3] <= wdata[8*b3 +: 8];
        q0 <= lane0[i0];
        q1 <= lane1[i1];
        q2 <= lane2[i2];
        q3 <= lane3[i3];
        rot <= a;
    end

    wire [31:0] q = {q3, q2, q1, q0};
    assign rdata = (rot == 2'd0) ? q :
                   (rot == 2'd1) ? {q[7:0],  q[31:8]} :
                   (rot == 2'd2) ? {q[15:0], q[31:16]} :
                                   {q[23:0], q[31:24]};

    // The display's side.
    reg [7:0] v0, v1, v2, v3;
    reg       vodd;
    always @(posedge vclk) begin
        v0 <= lane0[vcell[10:1]];
        v1 <= lane1[vcell[10:1]];
        v2 <= lane2[vcell[10:1]];
        v3 <= lane3[vcell[10:1]];
        vodd <= vcell[0];
    end
    assign vcell_q = vodd ? {v3, v2} : {v1, v0};
endmodule
