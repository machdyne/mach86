/*
 * Mach86 -- a cache line across two clocks.
 *
 * As m86_xclk.v, between the machine's clock and the DDR3 controller's
 * (Zeitlos's, rtl/ext/zeitlos), but for the cache's use of the memory,
 * which is always a whole line of four words: four words read, 0 to 3,
 * to fill a line, or four written to put a changed line back
 * (rtl/soc/m86_dcache.v). m86_xclk.v carries each word across by
 * itself, about three cycles of each clock a time, and that waiting
 * was most of what a miss cost: 41 to 47 of the machine's cycles for
 * a line read with one DRAM read, 82 to 90 when a changed line went
 * back first (round 40's measurement, docs/soc.md). Here a line
 * crosses once:
 *
 *   - A read of a word whose line is not in this bridge's register
 *     goes across as a request for the line. The far side reads the
 *     four words from the controller one after the other (one DRAM
 *     read, and three answers from the controller's own block
 *     register) and the whole line comes back. The other three words
 *     are then answered here, at once.
 *   - A written word is kept here and acknowledged at once. With the
 *     fourth the line goes across, and the far side writes the four
 *     words one after the other. With the controller's write
 *     combining on (ddr3.v's WCOMBINE) those are one DRAM write, and
 *     no read: without this bridge the words arrive too far apart for
 *     it to combine them, and the line cost four DRAM writes of the
 *     same sixteen bytes, and often a read before them.
 *
 * The cache's side is unchanged: a word at a time (side A, as
 * m86_xclk.v), and the far side is still a Wishbone master of single
 * words (side B). So nothing of Zeitlos's is touched.
 *
 * a_raw says the request is not the cache's (the BIOS's memory port,
 * which trains the DDR3 with single words it must see go to the DRAM
 * and come back): such a word goes across by itself, as in m86_xclk.v,
 * and the line register here is forgotten.
 *
 * What crosses is one level each way, changing once per request,
 * through two flip-flops; address and data are registered before the
 * level changes and not looked at on the other side until two of its
 * cycles later.
 */
`default_nettype none
module m86_xline #(
    parameter AW = 24               // word address bits
) (
    input  wire          a_clk,
    input  wire          a_rst,
    input  wire          a_req,
    input  wire          a_we,
    input  wire          a_raw,
    input  wire [AW-1:0] a_addr,
    input  wire [31:0]   a_wdata,
    output wire [31:0]   a_rdata,
    output wire          a_ack,

    input  wire          b_clk,
    input  wire          b_rst,
    output reg           b_stb,
    output wire          b_we,
    output wire [AW-1:0] b_addr,
    output wire [31:0]   b_wdata,
    input  wire [31:0]   b_rdata,
    input  wire          b_ack,
    // The controller's block register, if it shows it: with b_blk_ok
    // in the cycle of a read's b_ack, b_blk is the whole line and the
    // other three words are not asked for. (Tie b_blk_ok low without.)
    input  wire [127:0]  b_blk,
    input  wire          b_blk_ok
);
    // Side A
    reg           a_busy;
    reg           req_t;            // changes: a request
    reg           q_we, q_line;
    reg [AW-1:0]  q_addr;
    reg [127:0]   q_w;              // the line being written (a single word: its low 32 bits)
    reg [127:0]   l_data;           // the line read last
    reg [AW-3:0]  l_tag;
    reg           l_v;
    reg           ack_t;            // (side B) changes: done, and r_line holds what was read
    reg [127:0]   r_line;
    reg           ack_s1, ack_s2, ack_s3;
    reg  [31:0]   a_rdata_r;
    reg           a_ack_r;
    // A word of the line that is here, and a written word that is not
    // the line's last, are answered in the cycle they are asked.
    wire          a_idle = !a_busy && a_req && !a_raw && !a_ack_r;
    wire          a_rhit = a_idle && !a_we && l_v && (l_tag == a_addr[AW-1:2]);
    wire          a_wacc = a_idle && a_we && (a_addr[1:0] != 2'd3);

    function [31:0] word(input [127:0] l, input [1:0] i);
        word = (i == 2'd0) ? l[31:0] : (i == 2'd1) ? l[63:32] :
               (i == 2'd2) ? l[95:64] : l[127:96];
    endfunction

    assign a_ack   = a_ack_r || a_rhit || a_wacc;
    assign a_rdata = a_ack_r ? a_rdata_r : word(l_data, a_addr[1:0]);

    always @(posedge a_clk) begin
        ack_s1 <= ack_t;
        ack_s2 <= ack_s1;
        ack_s3 <= ack_s2;
        a_ack_r <= 1'b0;
        if (a_rst) begin
            a_busy <= 1'b0;
            req_t  <= 1'b0;
            l_v    <= 1'b0;
        end else if (!a_busy) begin
            if (a_req && !a_ack_r) begin
                if (a_raw) begin
                    a_busy <= 1'b1;
                    req_t  <= !req_t;
                    q_we   <= a_we;
                    q_line <= 1'b0;
                    q_addr <= a_addr;
                    q_w[31:0] <= a_wdata;
                    l_v    <= 1'b0;
                end else if (a_we) begin
                    case (a_addr[1:0])
                        2'd0: q_w[31:0]   <= a_wdata;
                        2'd1: q_w[63:32]  <= a_wdata;
                        2'd2: q_w[95:64]  <= a_wdata;
                        default: q_w[127:96] <= a_wdata;
                    endcase
                    l_v <= 1'b0;
                    if (a_addr[1:0] == 2'd3) begin
                        a_busy <= 1'b1;
                        req_t  <= !req_t;
                        q_we   <= 1'b1;
                        q_line <= 1'b1;
                        q_addr <= a_addr;
                    end
                end else if (!a_rhit) begin
                    a_busy <= 1'b1;
                    req_t  <= !req_t;
                    q_we   <= 1'b0;
                    q_line <= 1'b1;
                    q_addr <= a_addr;
                end
            end
        end else if (ack_s2 != ack_s3) begin
            a_busy  <= 1'b0;
            a_ack_r <= 1'b1;
            if (q_line && !q_we) begin
                l_data    <= r_line;
                l_tag     <= q_addr[AW-1:2];
                l_v       <= 1'b1;
                a_rdata_r <= word(r_line, q_addr[1:0]);
            end else
                a_rdata_r <= r_line[31:0];
        end
    end

    // Side B: one word, or the line's four, one after the other.
    reg       req_s1, req_s2, req_s3;
    reg       b_run;
    reg [1:0] b_i;
    assign b_we    = q_we;
    assign b_addr  = q_line ? {q_addr[AW-1:2], b_i} : q_addr;
    assign b_wdata = q_line ? word(q_w, b_i) : q_w[31:0];

    always @(posedge b_clk) begin
        req_s1 <= req_t;
        req_s2 <= req_s1;
        req_s3 <= req_s2;
        if (b_rst) begin
            b_stb <= 1'b0;
            b_run <= 1'b0;
            b_i   <= 2'd0;
            // A request made while this side was in reset is answered
            // (with nothing) rather than lost: side A would wait for
            // ever otherwise.
            if (req_s2 != req_s3)
                ack_t <= !ack_t;
        end else if (b_stb) begin
            if (b_ack) begin
                b_stb <= 1'b0;
                if (!q_line)
                    r_line[31:0] <= b_rdata;
                else case (b_i)
                    2'd0: r_line[31:0]   <= b_rdata;
                    2'd1: r_line[63:32]  <= b_rdata;
                    2'd2: r_line[95:64]  <= b_rdata;
                    default: r_line[127:96] <= b_rdata;
                endcase
                if (q_line && !q_we && b_blk_ok)
                    r_line <= b_blk;
                if (!q_line || b_i == 2'd3 || (!q_we && b_blk_ok)) begin
                    b_run <= 1'b0;
                    b_i   <= 2'd0;
                    ack_t <= !ack_t;
                end else
                    b_i <= b_i + 2'd1;
            end
        end else if (b_run)
            b_stb <= 1'b1;              // the next word
        else if (req_s2 != req_s3) begin
            b_stb <= 1'b1;
            b_run <= 1'b1;
            b_i   <= 2'd0;
        end
    end

    initial begin
        a_busy = 1'b0; req_t = 1'b0; ack_t = 1'b0; b_stb = 1'b0; a_ack_r = 1'b0;
        b_run = 1'b0; b_i = 2'd0; l_v = 1'b0;
        ack_s1 = 1'b0; ack_s2 = 1'b0; ack_s3 = 1'b0;
        req_s1 = 1'b0; req_s2 = 1'b0; req_s3 = 1'b0;
    end
endmodule
