/*
 * Mach86 SoC -- a byte-addressed memory in four lanes.
 *
 * Reads and writes one, two or four bytes at any address in one
 * cycle, which is what the CPU's data bus asks for. Lane L holds the
 * bytes whose address is L modulo 4, so the four bytes of an access
 * are always in four different lanes, whatever its alignment. Each
 * lane is a plain synchronous memory that maps to block RAM.
 *
 * A read is registered: the data for the address given in one cycle
 * is on rdata in the next, bytes in address order from bit 0. An
 * access that runs off the end wraps to the start.
 *
 * INIT0 to INIT3, if given, are hex files of one byte a line for the
 * four lanes (tools/lanes.py makes them from a binary).
 */
module m86_mem #(
    parameter AW = 16,              // address bits: 2**AW bytes
    parameter BYTES = 1 << AW,      // a multiple of four, at most 2**AW
    parameter INIT0 = "",
    parameter INIT1 = "",
    parameter INIT2 = "",
    parameter INIT3 = ""
) (
    input  wire          clk,
    input  wire [AW-1:0] addr,
    input  wire          we,
    input  wire [1:0]    wsize,     // 0, 1, 2: one, two, four bytes
    input  wire [31:0]   wdata,
    output wire [31:0]   rdata
);
    localparam N = BYTES / 4;

    reg [7:0] lane0 [0:N-1];
    reg [7:0] lane1 [0:N-1];
    reg [7:0] lane2 [0:N-1];
    reg [7:0] lane3 [0:N-1];
    reg [7:0] q0, q1, q2, q3;
    reg [1:0] rot;

    initial begin
        if (INIT0 != "") $readmemh(INIT0, lane0);
        if (INIT1 != "") $readmemh(INIT1, lane1);
        if (INIT2 != "") $readmemh(INIT2, lane2);
        if (INIT3 != "") $readmemh(INIT3, lane3);
    end

    wire [1:0]    a  = addr[1:0];
    wire [AW-3:0] w  = addr[AW-1:2];
    wire [AW-3:0] w1 = w + 1'b1;
    wire [2:0]    n  = (wsize == 2'd0) ? 3'd1 : (wsize == 2'd1) ? 3'd2 : 3'd4;

    // Lane L takes byte (L - a) mod 4 of the access, at the next word
    // if the access has wrapped past lane 3.
    wire [1:0] b0 = 2'd0 - a, b1 = 2'd1 - a, b2 = 2'd2 - a, b3 = 2'd3 - a;
    wire [AW-3:0] i0 = (a > 2'd0) ? w1 : w;
    wire [AW-3:0] i1 = (a > 2'd1) ? w1 : w;
    wire [AW-3:0] i2 = (a > 2'd2) ? w1 : w;
    wire [AW-3:0] i3 = w;

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

    // Byte i of the access came from lane (a + i) mod 4.
    wire [31:0] q = {q3, q2, q1, q0};
    assign rdata = (rot == 2'd0) ? q :
                   (rot == 2'd1) ? {q[7:0],  q[31:8]} :
                   (rot == 2'd2) ? {q[15:0], q[31:16]} :
                                   {q[23:0], q[31:24]};
endmodule
