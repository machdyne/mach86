/*
 * Mach86 -- a request across two clocks.
 *
 * The machine runs on one clock and the DDR3 controller (Zeitlos's,
 * rtl/ext/zeitlos) on another, 48 MHz, that its PHY makes by dividing
 * the memory's own clock; the two have no fixed relation. This carries
 * one request at a time from the first to the second and its answer
 * back.
 *
 * Side A is the SoC's memory interface (rtl/soc/m86_soc.v, m_ and x_):
 * a_req with a_we, a_addr and a_wdata held until a_ack, which lasts
 * one cycle and carries a_rdata. Side B is a Wishbone master: b_stb
 * (also the cycle signal) held until b_ack.
 *
 * Only two signals cross, one each way, and each is a level that
 * changes once per request, through two flip-flops on the other side.
 * The address and data are registered on the side that makes them
 * before the level changes and are not looked at on the other side
 * until two of its cycles after, so they are steady when sampled.
 *
 * A request costs about three cycles of each clock on top of the
 * memory's own time. That is paid once per word on a cache miss; a
 * bridge that moves a whole line at once would be faster and is the
 * obvious next step if misses turn out to matter.
 */
module m86_xclk #(
    parameter AW = 24
) (
    input  wire          a_clk,
    input  wire          a_rst,
    input  wire          a_req,
    input  wire          a_we,
    input  wire [AW-1:0] a_addr,
    input  wire [31:0]   a_wdata,
    output reg  [31:0]   a_rdata,
    output reg           a_ack,

    input  wire          b_clk,
    input  wire          b_rst,
    output reg           b_stb,
    output wire          b_we,
    output wire [AW-1:0] b_addr,
    output wire [31:0]   b_wdata,
    input  wire [31:0]   b_rdata,
    input  wire          b_ack
);
    // Side A
    reg          a_busy;
    reg          req_t;             // changes: a request
    reg          q_we;
    reg [AW-1:0] q_addr;
    reg [31:0]   q_wdata;
    reg          ack_t;             // (side B) changes: the answer is in r_data
    reg [31:0]   r_data;
    reg          ack_s1, ack_s2, ack_s3;

    always @(posedge a_clk) begin
        ack_s1 <= ack_t;
        ack_s2 <= ack_s1;
        ack_s3 <= ack_s2;
        a_ack  <= 1'b0;
        if (a_rst) begin
            a_busy <= 1'b0;
            req_t  <= 1'b0;
        end else if (!a_busy) begin
            if (a_req && !a_ack) begin
                a_busy  <= 1'b1;
                req_t   <= !req_t;
                q_we    <= a_we;
                q_addr  <= a_addr;
                q_wdata <= a_wdata;
            end
        end else if (ack_s2 != ack_s3) begin
            a_busy  <= 1'b0;
            a_ack   <= 1'b1;
            a_rdata <= r_data;
        end
    end

    // Side B
    reg req_s1, req_s2, req_s3;
    assign b_we    = q_we;
    assign b_addr  = q_addr;
    assign b_wdata = q_wdata;

    always @(posedge b_clk) begin
        req_s1 <= req_t;
        req_s2 <= req_s1;
        req_s3 <= req_s2;
        if (b_rst) begin
            b_stb <= 1'b0;
            ack_t <= 1'b0;
            // A request made while this side was in reset is answered
            // (with nothing) rather than lost: side A would wait for
            // ever otherwise.
            if (req_s2 != req_s3)
                ack_t <= !ack_t;
        end else if (b_stb) begin
            if (b_ack) begin
                b_stb  <= 1'b0;
                r_data <= b_rdata;
                ack_t  <= !ack_t;
            end
        end else if (req_s2 != req_s3)
            b_stb <= 1'b1;
    end

    initial begin
        a_busy = 1'b0; req_t = 1'b0; ack_t = 1'b0; b_stb = 1'b0; a_ack = 1'b0;
        ack_s1 = 1'b0; ack_s2 = 1'b0; ack_s3 = 1'b0;
        req_s1 = 1'b0; req_s2 = 1'b0; req_s3 = 1'b0;
    end
endmodule
