/*
 * Mach86 -- video memory in a board's main memory: the display's line
 * buffer and what fills it, and the three-way share of the memory.
 *
 * m86_vga.v keeps the first 64 KB of video memory in block RAM. What
 * is past that (the 640 x 350 and 640 x 480 pictures, a second page
 * of an unchained 256-colour mode) is in the board's memory, word for
 * word: one word is the four planes' bytes. The CPU's side of it goes
 * through a bridge like the cache's. The display cannot wait for
 * memory, so each line's 80 words are read a line ahead into a
 * buffer of two lines, on the memory's clock, and the display reads
 * the buffer on its own.
 *
 * m86_vfetch: vf_t changes (on vclk) to ask for the 80 words from
 * vf_addr into half vf_par. It has a line's time, 31.7 microseconds;
 * Zeitlos's DDR3 controller reads four words in a burst, so a line is
 * twenty bursts. If it is asked again before it is done, it starts
 * the new line: the old one is lost for that picture.
 *
 * m86_wbarb: three Wishbone masters on one memory, one request at a
 * time: the display's reads first, then the VGA's CPU side, then the
 * CPU's cache. The display keeps the memory for its whole line (about
 * a third of a line's time), so that the others cannot make it late.
 */
module m86_vfetch #(
    parameter BURST = 0             // 1: read four words at a time (Wishbone CTI), where
                                    // the memory can: Zeitlos's SDRAM controller
) (
    input  wire        vclk,
    input  wire        vf_t,
    input  wire [15:0] vf_addr,
    input  wire        vf_par,
    input  wire [7:0]  lb_addr,
    output reg  [31:0] lb_q,

    input  wire        mclk,
    input  wire        mrst,
    output reg         wb_stb,
    output wire        wb_lock,         // keep the memory until the line is in
    output wire [2:0]  wb_cti,          // 010: more of this burst to come; 111: its last
    output wire [15:0] wb_adr,
    input  wire [31:0] wb_dat,
    input  wire        wb_ack
);
    reg [31:0] buffer [0:255];
    always @(posedge vclk)
        lb_q <= buffer[lb_addr];

    // The request crosses as a level that changes; the address and
    // the half are steady by the time it is seen.
    reg [2:0]  t_s;
    reg [15:0] base;
    reg        par, busy;
    reg [6:0]  k;
    assign wb_adr = base + {9'd0, k};
    assign wb_lock = busy;
    // A burst is four words from an address that is a multiple of
    // four; what does not fit that is read a word at a time.
    reg        inb;
    reg [1:0]  beat;
    wire       can_burst = (BURST != 0) && (wb_adr[1:0] == 2'b00) && (k <= 7'd76);
    assign wb_cti = !inb ? 3'b000 : (beat == 2'd3) ? 3'b111 : 3'b010;
    always @(posedge mclk) begin
        t_s <= {t_s[1:0], vf_t};
        if (wb_stb && wb_ack) begin
            buffer[{par, k}] <= wb_dat;
            // Within a burst the request stays, with the next address.
            if (!inb || beat == 2'd3) begin
                wb_stb <= 1'b0;
                inb <= 1'b0;
            end
            beat <= beat + 2'd1;
            k <= k + 7'd1;
            if (k == 7'd79)
                busy <= 1'b0;
        end else if (busy && !wb_stb) begin
            wb_stb <= 1'b1;
            inb    <= can_burst;
            beat   <= 2'd0;
        end
        if (t_s[2] != t_s[1]) begin
            base <= vf_addr;
            par  <= vf_par;
            k    <= 7'd0;
            busy <= 1'b1;
            wb_stb <= 1'b0;
            inb <= 1'b0;
        end
        if (mrst) begin
            busy <= 1'b0; wb_stb <= 1'b0; k <= 7'd0; inb <= 1'b0; beat <= 2'd0;
        end
    end
endmodule

module m86_wbarb (
    input  wire        clk,
    input  wire        rst,
    // 0: the display, 1: the VGA's CPU side, 2: the cache
    input  wire        s0_stb,
    input  wire        s0_lock,
    input  wire [2:0]  s0_cti,
    input  wire [26:0] s0_adr,
    output wire        s0_ack,
    input  wire        s1_stb,
    input  wire        s1_we,
    input  wire [3:0]  s1_sel,
    input  wire [26:0] s1_adr,
    input  wire [31:0] s1_dat,
    output wire        s1_ack,
    input  wire        s2_stb,
    input  wire        s2_we,
    input  wire [26:0] s2_adr,
    input  wire [31:0] s2_dat,
    output wire        s2_ack,
    // the memory
    output wire        m_stb,
    output wire        m_we,
    output wire [3:0]  m_sel,
    output wire [2:0]  m_cti,
    output wire [26:0] m_adr,
    output wire [31:0] m_dat,
    input  wire        m_ack
);
    reg       busy;
    reg [1:0] g;
    always @(posedge clk) begin
        if (!busy) begin
            if (s0_stb)      begin g <= 2'd0; busy <= 1'b1; end
            else if (s1_stb) begin g <= 2'd1; busy <= 1'b1; end
            else if (s2_stb) begin g <= 2'd2; busy <= 1'b1; end
        end else if (m_ack && !(g == 2'd0 && s0_lock))
            busy <= 1'b0;
        else if (g == 2'd0 && !s0_lock && !s0_stb)
            busy <= 1'b0;               // the line is in
        if (rst)
            busy <= 1'b0;
    end
    wire stb_g = (g == 2'd0) ? s0_stb : (g == 2'd1) ? s1_stb : s2_stb;
    assign m_stb = busy && stb_g;
    assign m_we  = (g == 2'd1) ? s1_we : (g == 2'd2) ? s2_we : 1'b0;
    assign m_sel = (g == 2'd1) ? s1_sel : 4'b1111;
    assign m_cti = (g == 2'd0) ? s0_cti : 3'b000;
    assign m_adr = (g == 2'd0) ? s0_adr : (g == 2'd1) ? s1_adr : s2_adr;
    assign m_dat = (g == 2'd1) ? s1_dat : s2_dat;
    assign s0_ack = busy && m_ack && (g == 2'd0);
    assign s1_ack = busy && m_ack && (g == 2'd1);
    assign s2_ack = busy && m_ack && (g == 2'd2);
endmodule
