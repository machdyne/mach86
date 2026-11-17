/*
 * Mach86 SoC -- the interval timer (8254), ports 40h to 43h.
 *
 * Sources: Intel 8254 data sheet; behaviour as in the reference
 * model, sim/pc.c. Three down-counters clocked 1,193,182 times a
 * second (tick is high for one clock cycle each time). Channel 0
 * raises interrupt 0 each time it reaches zero; channel 2 is gated by
 * port 61h and its output can be read there. What is here: the count
 * written and read low byte, high byte or both; the count latch;
 * modes as far as "counts down and reloads" (mode 0 fires once).
 * With its gate low a channel stops, and in modes 2 and 3 its output
 * is high. Not here: read-back, BCD, the gate restarting a count,
 * exact output waveforms.
 */
module m86_pit (
    input  wire       clk,
    input  wire       rst,
    input  wire       tick,
    input  wire       cs,
    input  wire [1:0] a,
    input  wire       rd,           // one cycle per read
    input  wire       wr,
    input  wire [7:0] wdata,
    output wire [7:0] rdata,
    input  wire       gate2,
    output wire       out2,
    output wire       irq0
);
    wire [7:0] q [0:2];
    wire [2:0] out, zero;
    genvar i;
    generate
        for (i = 0; i < 3; i = i + 1) begin : ch
            m86_pit_ch c (
                .clk(clk), .rst(rst), .tick(tick),
                .gate(i == 2 ? gate2 : 1'b1),
                .wr_count(cs && wr && a == i),
                .wr_ctrl(cs && wr && a == 2'd3 && wdata[7:6] == i),
                .rd(cs && rd && a == i),
                .wdata(wdata), .rdata(q[i]),
                .out(out[i]), .zero(zero[i]));
        end
    endgenerate
    assign rdata = (a == 2'd3) ? 8'hFF : q[a];
    assign out2 = out[2];
    assign irq0 = zero[0];
endmodule

module m86_pit_ch (
    input  wire       clk,
    input  wire       rst,
    input  wire       tick,
    input  wire       gate,
    input  wire       wr_count,
    input  wire       wr_ctrl,
    input  wire       rd,
    input  wire [7:0] wdata,
    output wire [7:0] rdata,
    output reg        out,
    output reg        zero          // one cycle: the count ran out
);
    reg [16:0] reload, remain;
    reg [1:0]  rw;
    reg [2:0]  mode;
    reg        wr_hi, rd_hi, loaded, fired, latched, latch_hi;
    reg [7:0]  wr_lo;
    reg [15:0] latch;

    wire [15:0] value = latched ? latch : remain[15:0];
    wire        hi    = latched ? latch_hi : rd_hi;
    assign rdata = (rw == 2'd3) ? (hi ? value[15:8] : value[7:0]) :
                   (rw == 2'd2) ? value[15:8] : value[7:0];

    wire [15:0] wvalue = (rw == 2'd3) ? {wdata, wr_lo} :
                         (rw == 2'd2) ? {wdata, 8'd0} : {8'd0, wdata};
    wire [16:0] wload  = (wvalue == 16'd0) ? 17'h10000 : {1'b0, wvalue};
    wire [2:0]  wmode  = (wdata[3:1] > 3'd5) ? wdata[3:1] - 3'd4 : wdata[3:1];

    wire [16:0] next = (remain == 17'd1) ? reload : remain - 17'd1;

    always @(posedge clk) begin
        zero <= 1'b0;
        if (tick && loaded && gate) begin
            remain <= next;
            if (remain == 17'd1) begin
                if (mode == 3'd0) begin
                    if (!fired) begin
                        fired <= 1'b1;
                        zero  <= 1'b1;
                    end
                end else
                    zero <= 1'b1;
            end
            if (mode == 3'd3)
                out <= next > {1'b0, reload[16:1]};
            else if (mode != 3'd0)
                out <= next != 17'd1;
            else if (remain == 17'd1)
                out <= 1'b1;
        end

        // With the gate low a rate generator's or square wave's output
        // is high: a speaker bit that programs then switch themselves
        // through port 61h.
        if (!gate && (mode == 3'd2 || mode == 3'd3))
            out <= 1'b1;

        if (rd) begin
            if (rw == 2'd3) begin
                if (latched) begin
                    if (latch_hi) latched <= 1'b0;
                    latch_hi <= !latch_hi;
                end else
                    rd_hi <= !rd_hi;
            end else
                latched <= 1'b0;
        end

        if (wr_ctrl) begin
            if (wdata[5:4] == 2'd0) begin           // latch the count
                latch    <= remain[15:0];
                latched  <= 1'b1;
                latch_hi <= 1'b0;
            end else begin
                rw     <= wdata[5:4];
                mode   <= wmode;
                wr_hi  <= 1'b0;
                rd_hi  <= 1'b0;
                loaded <= 1'b0;
                out    <= (wmode != 3'd0);
            end
        end

        if (wr_count) begin
            if (rw == 2'd3 && !wr_hi) begin
                wr_lo <= wdata;
                wr_hi <= 1'b1;
            end else begin
                wr_hi  <= 1'b0;
                reload <= wload;
                remain <= wload;
                loaded <= 1'b1;
                fired  <= 1'b0;
                if (mode == 3'd0)
                    out <= 1'b0;
            end
        end

        if (rst) begin
            reload <= 17'h10000; remain <= 17'h10000;
            rw <= 2'd3; mode <= 3'd3;
            wr_hi <= 1'b0; rd_hi <= 1'b0; loaded <= 1'b0; fired <= 1'b0;
            latched <= 1'b0; latch_hi <= 1'b0; out <= 1'b0; zero <= 1'b0;
        end
    end
endmodule
