/*
 * Mach86 CPU -- arithmetic and logic unit.
 *
 * Sources: I386-PRM ch. 17 (flag results of ADD, ADC, SUB, SBB, AND,
 * OR, XOR, CMP, INC, DEC).
 *
 * Combinational. `size` is the operand size in bytes: 1, 2 or 4.
 * Operands must be zero-extended to 32 bits.
 */
module m86_alu (
    input  wire [3:0]  op,      // 0-7: ADD OR ADC SBB AND SUB XOR CMP; 8 INC; 9 DEC
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        cin,
    input  wire [2:0]  size,
    output reg  [31:0] res,
    output reg         cf,
    output reg         of,
    output reg         af,
    output wire        zf,
    output wire        sf,
    output wire        pf
);
    wire        is_add = (op == 4'd0) || (op == 4'd2) || (op == 4'd8);
    wire        is_sub = (op == 4'd3) || (op == 4'd5) || (op == 4'd7) || (op == 4'd9);
    wire        use_c  = (op == 4'd2) || (op == 4'd3);
    wire [31:0] bb     = (op == 4'd8 || op == 4'd9) ? 32'd1 : b;
    wire        c      = use_c & cin;

    wire [32:0] sum  = {1'b0, a} + {1'b0, bb} + {32'd0, c};
    wire [32:0] diff = {1'b0, a} - {1'b0, bb} - {32'd0, c};
    wire [32:0] w    = is_add ? sum : diff;

    reg  [31:0] r;
    always @* begin
        case (op)
            4'd1:    r = a | bb;
            4'd4:    r = a & bb;
            4'd6:    r = a ^ bb;
            // 10: B's lower half sign-extended to the operand size.
            // 11: every bit a copy of A's sign bit. No flags are defined.
            4'd10:   r = (size == 3'd2) ? {16'd0, {8{bb[7]}}, bb[7:0]}
                                        : {{16{bb[15]}}, bb[15:0]};
            4'd11:   r = {32{(size == 3'd2) ? a[15] : a[31]}};
            // 12: A rotated right one place through the carry.
            4'd12:   r = (size == 3'd1) ? {24'd0, cin, a[7:1]} :
                         (size == 3'd2) ? {16'd0, cin, a[15:1]} : {cin, a[31:1]};
            default: r = w[31:0];
        endcase
    end

    wire [31:0] x_add = (a ^ r) & (bb ^ r);
    wire [31:0] x_sub = (a ^ bb) & (a ^ r);
    wire [31:0] x     = is_add ? x_add : x_sub;

    reg msb;
    always @* begin
        case (size)
            3'd1: begin res = {24'd0, r[7:0]};  cf = w[8];  of = x[7];  msb = r[7];  end
            3'd2: begin res = {16'd0, r[15:0]}; cf = w[16]; of = x[15]; msb = r[15]; end
            default: begin res = r;             cf = w[32]; of = x[31]; msb = r[31]; end
        endcase
        af = a[4] ^ bb[4] ^ r[4];
        if (!is_add && !is_sub) begin
            cf = 1'b0;
            of = 1'b0;
            af = 1'b0;
        end
        if (op == 4'd12) begin
            cf = a[0];
            of = msb ^ ((size == 3'd1) ? r[6] : (size == 3'd2) ? r[14] : r[30]);
        end
    end

    assign zf = (res == 32'd0);
    assign sf = msb;
    assign pf = ~^r[7:0];
endmodule
