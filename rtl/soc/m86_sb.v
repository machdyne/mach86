// A Sound Blaster, cut to what games use (docs/sound.md): the DSP of a
// 2.0 at 220h (version 2.01), playing 8-bit samples through DMA
// channel 1, and that one channel of the DMA controller. No recording,
// no compressed formats (they play as plain samples), no mixer chip.
//
// The samples are not fetched by a second master on the memory bus:
// the CPU core fetches each byte itself, between two instructions,
// when dma_req asks (rtl/cpu/m86b_core.v). That way they come through
// the data cache, which may be the only place a sample just written
// is, and nothing is added to the path into the cache. One byte is
// fetched ahead of the one being played.

`default_nettype none

module m86_sb #(
    parameter CLK_HZ = 33157895
) (
    input  wire        clk,
    input  wire        rst,
    // Ports: 220h to 22Fh (cs_dsp), 00h to 0Fh (cs_dma), 83h (cs_page).
    input  wire        cs_dsp,
    input  wire        cs_dma,
    input  wire        cs_page,
    input  wire [3:0]  a,
    input  wire        rd,          // one cycle
    input  wire        wr,
    input  wire [7:0]  wd,
    output reg  [7:0]  q,
    output reg         irq,
    // To the CPU core: fetch the byte at dma_addr.
    output reg         dma_req,
    output wire [23:0] dma_addr,
    input  wire        dma_ack,
    input  wire [7:0]  dma_q,
    // What is playing: an unsigned sample (80h is silence).
    output wire [7:0]  sample
);
    // ---- the DMA channel ----
    reg [15:0] d_addr, d_cnt, d_baddr, d_bcnt;
    reg [7:0]  d_page;
    reg        d_auto, d_mask, d_ff, d_tc;
    assign dma_addr = {d_page, d_addr};

    // ---- the DSP ----
    reg [7:0]  cmd, arg0, tc, dac, test, o0, o1, o_last;
    reg [1:0]  need, o_n;
    reg        have, rst_bit, speaker, active, autoinit, paused;
    reg [15:0] block;
    reg [16:0] left;
    reg        pf_v;                // a byte fetched ahead
`ifdef M86_DBG
    reg        irq_d;
`endif
    reg [7:0]  pf_d;
    assign sample = speaker ? dac : 8'h80;

    // How many bytes follow a command.
    function [1:0] nargs(input [7:0] c);
        casez (c)
            8'h10, 8'h40, 8'hE0, 8'hE4: nargs = 2'd1;
            8'h14, 8'h16, 8'h17, 8'h48, 8'h74, 8'h75, 8'h76, 8'h77, 8'h80, 8'h91: nargs = 2'd2;
            default: nargs = 2'd0;
        endcase
    endfunction

    // A sample every 256 - tc microseconds. (A microsecond: the carry
    // of a 16-bit sum, K a cycle.)
    localparam [15:0] K = (64'd65536 * 64'd1000000 + CLK_HZ / 2) / CLK_HZ;
    reg [15:0] us_acc;
    reg        us;
    reg [7:0]  cnt;
    wire       due = us && (cnt == 8'hFF);

    wire       w_dsp  = wr && cs_dsp && (a == 4'hC);
    wire       go     = w_dsp && ((need == 2'd0) ? (nargs(wd) == 2'd0)
                                                 : (need == 2'd1 || have));
    wire [7:0] c      = (need == 2'd0) ? wd : cmd;      // the command now complete
    wire [7:0] a0     = (need == 2'd1) ? wd : arg0;     // its first byte
    wire [15:0] n     = {wd, arg0};                     // its two bytes
    wire       fetch  = dma_ack && dma_req;

    always @(posedge clk) begin
        {us, us_acc} <= {1'b0, us_acc} + {1'b0, K};
        if (us) cnt <= (cnt == 8'hFF) ? tc : cnt + 8'd1;

        // The byte ahead.
        dma_req <= active && !paused && !d_mask && !pf_v && !fetch;
        if (fetch) begin
            pf_d <= dma_q;
            pf_v <= 1'b1;
            d_addr <= d_addr + 16'd1;
            d_cnt  <= d_cnt - 16'd1;
            if (d_cnt == 16'd0) begin
                d_tc <= 1'b1;
                if (d_auto) begin
                    d_addr <= d_baddr;
                    d_cnt  <= d_bcnt;
                end else
                    d_mask <= 1'b1;
            end
        end
        if (due && active && !paused && pf_v) begin
            dac  <= pf_d;
            pf_v <= 1'b0;
            left <= left - 17'd1;
            if (left == 17'd1) begin
                irq <= 1'b1;
                if (autoinit) left <= {1'b0, block} + 17'd1;
                else          active <= 1'b0;
            end
        end

`ifdef M86_DBG
        if (wr && (cs_dsp || cs_dma || cs_page)) $display("DBG sb write %b%b%b a=%h d=%h", cs_dsp, cs_dma, cs_page, a, wd);
        if (rd && (cs_dsp || cs_dma || cs_page)) $display("DBG sb read  %b%b%b a=%h q=%h", cs_dsp, cs_dma, cs_page, a, q);
        if (fetch) $display("DBG sb fetch %h = %h left=%d", dma_addr, dma_q, left);
        if (irq && !irq_d) $display("DBG sb irq");
        irq_d <= irq;
`endif
        // The DSP's ports.
        if (wr && cs_dsp && a == 4'h6) begin
            rst_bit <= wd[0];
            if (rst_bit && !wd[0]) begin
                active <= 1'b0; paused <= 1'b0; autoinit <= 1'b0; speaker <= 1'b0;
                need <= 2'd0; irq <= 1'b0; pf_v <= 1'b0; dac <= 8'h80; tc <= 8'hD2;
                o0 <= 8'hAA; o_n <= 2'd1;
            end
        end
        if (w_dsp) begin
            if (need == 2'd0) begin
                cmd  <= wd;
                need <= nargs(wd);
                have <= 1'b0;
            end else if (need == 2'd2 && !have) begin
                arg0 <= wd;
                have <= 1'b1;
            end else
                need <= 2'd0;
            if (need == 2'd1) arg0 <= wd;
        end
        if (go)
            casez (c)
                8'h10: dac <= a0;
                8'h14, 8'h91, 8'h16, 8'h17, 8'h74, 8'h75, 8'h76, 8'h77, 8'h80: begin
                    left <= {1'b0, n} + 17'd1;
                    autoinit <= 1'b0; active <= 1'b1; paused <= 1'b0;
                end
                8'h1C, 8'h90: begin
                    left <= {1'b0, block} + 17'd1;
                    autoinit <= 1'b1; active <= 1'b1; paused <= 1'b0;
                end
                8'h40: tc <= a0;
                8'h48: block <= n;
                8'hD0: paused <= 1'b1;
                8'hD4: paused <= 1'b0;
                8'hD1: speaker <= 1'b1;
                8'hD3: speaker <= 1'b0;
                8'hD8: begin o0 <= {8{speaker}}; o_n <= 2'd1; end
                8'hDA: autoinit <= 1'b0;
                8'hE0: begin o0 <= ~a0; o_n <= 2'd1; end
                8'hE1: begin o0 <= 8'd2; o1 <= 8'd1; o_n <= 2'd2; end
                8'hE4: test <= a0;
                8'hE8: begin o0 <= test; o_n <= 2'd1; end
                8'hF2: irq <= 1'b1;
                8'h20: begin o0 <= 8'h80; o_n <= 2'd1; end
                default: ;
            endcase
        if (rd && cs_dsp && a == 4'hA && o_n != 2'd0) begin
            o_last <= o0;
            o0 <= o1;
            o_n <= o_n - 2'd1;
        end
        if (rd && cs_dsp && a == 4'hE) irq <= 1'b0;

        // The DMA controller's ports.
        if (wr && cs_dma)
            case (a)
                4'h2: begin
                    if (d_ff) d_baddr[15:8] <= wd; else d_baddr[7:0] <= wd;
                    if (d_ff) d_addr[15:8]  <= wd; else d_addr[7:0]  <= wd;
                    d_ff <= !d_ff;
                    pf_v <= 1'b0;
                end
                4'h3: begin
                    if (d_ff) d_bcnt[15:8] <= wd; else d_bcnt[7:0] <= wd;
                    if (d_ff) d_cnt[15:8]  <= wd; else d_cnt[7:0]  <= wd;
                    d_ff <= !d_ff;
                end
                4'hA: if (wd[1:0] == 2'd1) d_mask <= wd[2];
                4'hB: if (wd[1:0] == 2'd1) d_auto <= wd[4];
                4'hC: d_ff <= 1'b0;
                4'hD: begin d_ff <= 1'b0; d_mask <= 1'b1; d_tc <= 1'b0; end
                4'hE: d_mask <= 1'b0;
                4'hF: d_mask <= wd[1];
                default: ;
            endcase
        if (wr && cs_page) d_page <= wd;
        if (rd && cs_dma && (a == 4'h2 || a == 4'h3)) d_ff <= !d_ff;
        if (rd && cs_dma && a == 4'h8) d_tc <= 1'b0;

        if (rst) begin
            active <= 1'b0; paused <= 1'b0; autoinit <= 1'b0; speaker <= 1'b0;
            need <= 2'd0; have <= 1'b0; irq <= 1'b0; pf_v <= 1'b0; dac <= 8'h80;
            tc <= 8'hD2; o_n <= 2'd0; rst_bit <= 1'b0; dma_req <= 1'b0;
            d_mask <= 1'b1; d_ff <= 1'b0; d_tc <= 1'b0; d_auto <= 1'b0;
            us_acc <= 16'd0; us <= 1'b0; cnt <= 8'd0;
        end
    end

    // What a port reads.
    always @* begin
        q = 8'hFF;
        if (cs_dsp)
            case (a)
                4'hA: q = (o_n != 2'd0) ? o0 : o_last;
                4'hC: q = 8'h7F;
                4'hE: q = {o_n != 2'd0, 7'h7F};
                default: q = 8'hFF;
            endcase
        else if (cs_page)
            q = d_page;
        else
            case (a)
                4'h2: q = d_ff ? d_addr[15:8] : d_addr[7:0];
                4'h3: q = d_ff ? d_cnt[15:8] : d_cnt[7:0];
                4'h8: q = {6'd0, d_tc, 1'b0};
                default: q = 8'hFF;
            endcase
    end
endmodule

`default_nettype wire
