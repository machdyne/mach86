/*
 * Mach86 SoC -- the VGA: video memory, registers, and the display.
 *
 * Sources: the IBM VGA technical reference as it describes the
 * registers and the graphics controller's write and read modes; the
 * 640 x 480 at 60 Hz display timing; the reference model, sim/vga.c,
 * which this follows function for function. docs/video.md says what
 * is here and what is not.
 *
 * The memory is 16,384 words of four bytes, one for each plane (64 KB
 * of block RAM, with one port for the CPU and one for the display).
 * How a CPU address in A0000h-BFFFFh reaches it depends on the mode:
 *
 *   planar (16 colours)       the word at the offset, through the
 *                             graphics controller's write and read
 *                             modes
 *   chained (256 colours)     byte a is plane a mod 4 of word a / 4
 *   odd/even (text, CGA four  byte a is plane a mod 2 of word a / 2
 *   colours)
 *
 * The CPU's side takes an access of one, two or four bytes apart: a
 * cycle for each word of the memory it touches (a planar byte is a
 * word; a chained double word is one, a text cell is one), and for a
 * read one more each. Writes go through a queue of four, and st_rdy
 * tells the CPU when it may start another (leaving room for those
 * already on their way), as the data cache does. A read is answered
 * with ack when its bytes are in.
 *
 * The display is always 640 x 480 at 60 Hz, on vclk. Every mode here
 * has 400 lines (200 shown twice, or 25 rows of 16), in lines 40 to
 * 439. The registers are on the CPU's clock and the display reads
 * them as they are: they change between pictures, when programs
 * change them, and a stray pixel then is what a real VGA shows too.
 */
module m86_vga #(
    parameter FONT = "font.hex",
    parameter VGA_EXT = 0,          // 1: video memory past 64 KB, in the board's memory
    parameter VGA_BRAM = 1          // 0 (with VGA_EXT): no block RAM here, all of it there
) (
    input  wire        clk,
    input  wire        rst,

    // Memory: A0000h-BFFFFh. req and wr as the CPU's bus (a read held
    // until ack, a write for one cycle); addr is the address less
    // A0000h.
    input  wire        req,
    input  wire        wr,
    input  wire [16:0] addr,
    input  wire [1:0]  size,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output reg         ack,
    output wire        st_rdy,
    output wire        idle,            // no write is waiting: the registers may be read

    // Ports 3C0h-3DFh: io_a is the port's low five bits. A read is
    // answered in the same cycle (the SoC registers it, and waits for
    // `idle` first); io_rd is high for the one cycle in which reading
    // has its side effects. A write takes its turn behind the writes
    // to the memory. A write of a word to an index port writes the
    // index and its register.
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire [4:0]  io_a,
    input  wire [15:0] io_wd,
    input  wire        io_word,
    output reg  [7:0]  io_q,

    // Video memory past the first 64 KB (planar words 16,384 and up),
    // when VGA_EXT: a request held until x_ack, as the SoC's memory
    // port; x_sel says which planes a write changes.
    output wire        x_req,
    output wire        x_we,
    output wire [3:0]  x_sel,
    output wire [15:0] x_addr,
    output wire [31:0] x_wdata,
    input  wire [31:0] x_rdata,
    input  wire        x_ack,
    // The display's side of it, on vclk: vf_t changes to ask for the
    // 80 words from vf_addr into half vf_par of the line buffer; the
    // buffer is read at lb_addr, answered the cycle after.
    output reg         vf_t,
    output reg  [15:0] vf_addr,
    output reg         vf_par,
    output wire [7:0]  lb_addr,
    input  wire [31:0] lb_q,

    // The display.
    input  wire        vclk,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         hsync,
    output reg         vsync,
    output reg         de
);
    // A register write, when its turn has come: writes to the ports go
    // through the same queue as writes to the memory, so that a
    // program's order is kept (the memory can be slow; see below).
    wire        rw_do;
    wire [4:0]  rw_a;
    wire [15:0] rw_wd;
    wire        rw_word;

    // ---- registers ----
    reg [7:0] seq_idx, gc_idx, crtc_idx;
    reg [4:0] ac_idx;
    reg       ac_data;                  // the next write to 3C0h is data
    reg       pas;                      // the screen is on
    reg [7:0] misc;
    reg [7:0] seq1, seq2, seq4;
    reg [7:0] gc0, gc1, gc2, gc3, gc4, gc5, gc6, gc7, gc8;
    reg [5:0] pal [0:15];
    reg [7:0] ac10, ac12, ac14;
    reg [7:0] crtc09, crtc0a, crtc0b, crtc0c, crtc0d, crtc0e, crtc0f, crtc13, crtc17;
    reg [7:0] dac_mask, dac_ridx, dac_widx;
    reg [1:0] dac_rsub, dac_wsub;
    reg [5:0] dac_r, dac_g;
    // The other display controller registers are only remembered.
    reg [7:0] crtc_mem [0:31];
    reg [7:0] crtc_q;
    reg [7:0] seq_q, gc_q, ac_q;

    // The colours: 256 of 18 bits, in one block RAM with a port on
    // each clock. The CPU's port writes a colour when its third part
    // arrives, and otherwise reads the one at the read index; the
    // display's port reads.
    reg [17:0] dac [0:255];
    reg [17:0] dac_cq, dac_vq;
    reg [7:0]  dac_va;
    wire       dac_we = rw_do && rw_a == 5'h09 && dac_wsub == 2'd2;
    wire [7:0] dac_ca = dac_we ? dac_widx : dac_ridx;
    always @(posedge clk) begin
        if (dac_we)
            dac[dac_ca] <= {dac_r, dac_g, rw_wd[5:0]};
        else
            dac_cq <= dac[dac_ca];
    end
    always @(posedge vclk)
        dac_vq <= dac[dac_va];

    // Status, from the display's counters.
    reg       v_blank, v_vs;            // on vclk
    reg [1:0] blank_s, vs_s;
    always @(posedge clk) begin
        blank_s <= {blank_s[0], v_blank};
        vs_s    <= {vs_s[0], v_vs};
    end

    always @(*) begin
        case (seq_idx[2:0])
            3'd1: seq_q = seq1;
            3'd2: seq_q = seq2;
            3'd4: seq_q = seq4;
            3'd0: seq_q = 8'h03;
            default: seq_q = 8'h00;
        endcase
        case (gc_idx[3:0])
            4'd0: gc_q = gc0;  4'd1: gc_q = gc1;  4'd2: gc_q = gc2;
            4'd3: gc_q = gc3;  4'd4: gc_q = gc4;  4'd5: gc_q = gc5;
            4'd6: gc_q = gc6;  4'd7: gc_q = gc7;  4'd8: gc_q = gc8;
            default: gc_q = 8'h00;
        endcase
        if (!ac_idx[4])
            ac_q = {2'b00, pal[ac_idx[3:0]]};
        else case (ac_idx[3:0])
            4'd0: ac_q = ac10;
            4'd2: ac_q = ac12;
            4'd4: ac_q = ac14;
            default: ac_q = 8'h00;
        endcase
        crtc_q = crtc_mem[crtc_idx[4:0]];

        case (io_a)
            5'h00: io_q = {2'b00, pas, ac_idx};
            5'h01: io_q = ac_q;
            5'h04: io_q = seq_idx;
            5'h05: io_q = seq_q;
            5'h06: io_q = dac_mask;
            5'h07: io_q = 8'h00;
            5'h08: io_q = dac_widx;
            5'h09: io_q = {2'b00, (dac_rsub == 2'd0) ? dac_cq[17:12] :
                                  (dac_rsub == 2'd1) ? dac_cq[11:6] : dac_cq[5:0]};
            5'h0C: io_q = misc;
            5'h0E: io_q = gc_idx;
            5'h0F: io_q = gc_q;
            5'h14: io_q = crtc_idx;
            5'h15: io_q = crtc_q;
            5'h1A: io_q = {4'h0, vs_s[1], 2'b00, blank_s[1]};
            default: io_q = 8'hFF;
        endcase
    end

    // One register write: which pair, the index, the value.
    task reg_write(input [1:0] which, input [7:0] idx, input [7:0] v);
        begin
            case (which)
                2'd0: case (idx[2:0])
                    3'd1: seq1 <= v;
                    3'd2: seq2 <= v;
                    3'd4: seq4 <= v;
                    default: ;
                endcase
                2'd1: case (idx[3:0])
                    4'd0: gc0 <= v;  4'd1: gc1 <= v;  4'd2: gc2 <= v;
                    4'd3: gc3 <= v;  4'd4: gc4 <= v;  4'd5: gc5 <= v;
                    4'd6: gc6 <= v;  4'd7: gc7 <= v;  4'd8: gc8 <= v;
                    default: ;
                endcase
                default: begin
                    crtc_mem[idx[4:0]] <= v;
                    case (idx[4:0])
                        5'h09: crtc09 <= v;  5'h0A: crtc0a <= v;
                        5'h0B: crtc0b <= v;  5'h0C: crtc0c <= v;
                        5'h0D: crtc0d <= v;  5'h0E: crtc0e <= v;
                        5'h0F: crtc0f <= v;  5'h13: crtc13 <= v;
                        5'h17: crtc17 <= v;
                        default: ;
                    endcase
                end
            endcase
        end
    endtask

    integer i;
    always @(posedge clk) begin
        if (rw_do) case (rw_a)
            5'h00: begin
                if (!ac_data) begin
                    ac_idx <= rw_wd[4:0];
                    pas    <= rw_wd[5];
                end else if (!ac_idx[4])
                    pal[ac_idx[3:0]] <= rw_wd[5:0];
                else case (ac_idx[3:0])
                    4'd0: ac10 <= rw_wd[7:0];
                    4'd2: ac12 <= rw_wd[7:0];
                    4'd4: ac14 <= rw_wd[7:0];
                    default: ;
                endcase
                ac_data <= !ac_data;
            end
            5'h02: misc <= rw_wd[7:0];
            5'h04: begin
                seq_idx <= rw_wd[7:0];
                if (rw_word) reg_write(2'd0, rw_wd[7:0], rw_wd[15:8]);
            end
            5'h05: reg_write(2'd0, seq_idx, rw_wd[7:0]);
            5'h06: dac_mask <= rw_wd[7:0];
            5'h07: begin dac_ridx <= rw_wd[7:0]; dac_rsub <= 2'd0; end
            5'h08: begin dac_widx <= rw_wd[7:0]; dac_wsub <= 2'd0; end
            5'h09: begin
                if (dac_wsub == 2'd0) dac_r <= rw_wd[5:0];
                if (dac_wsub == 2'd1) dac_g <= rw_wd[5:0];
                if (dac_wsub == 2'd2) begin
                    dac_wsub <= 2'd0;
                    dac_widx <= dac_widx + 8'd1;
                end else
                    dac_wsub <= dac_wsub + 2'd1;
            end
            5'h0E: begin
                gc_idx <= rw_wd[7:0];
                if (rw_word) reg_write(2'd1, rw_wd[7:0], rw_wd[15:8]);
            end
            5'h0F: reg_write(2'd1, gc_idx, rw_wd[7:0]);
            5'h14: begin
                crtc_idx <= rw_wd[7:0];
                if (rw_word) reg_write(2'd2, rw_wd[7:0], rw_wd[15:8]);
            end
            5'h15: reg_write(2'd2, crtc_idx, rw_wd[7:0]);
            default: ;
        endcase
        if (io_rd && io_a == 5'h1A)
            ac_data <= 1'b0;
        if (io_rd && io_a == 5'h09) begin
            if (dac_rsub == 2'd2) begin
                dac_rsub <= 2'd0;
                dac_ridx <= dac_ridx + 8'd1;
            end else
                dac_rsub <= dac_rsub + 2'd1;
        end
        if (rst) begin
            // As sim/vga.c's vga_reset: the memory at B8000h as plain
            // bytes, which the BIOS's memory trainer runs in before
            // any mode is set; the screen off.
            seq_idx <= 8'd0; gc_idx <= 8'd0; crtc_idx <= 8'd0;
            ac_idx <= 5'd0; ac_data <= 1'b0; pas <= 1'b0; misc <= 8'd0;
            seq1 <= 8'h00; seq2 <= 8'h03; seq4 <= 8'h02;
            gc0 <= 8'd0; gc1 <= 8'd0; gc2 <= 8'd0; gc3 <= 8'd0; gc4 <= 8'd0;
            gc5 <= 8'h10; gc6 <= 8'h0E; gc7 <= 8'd0; gc8 <= 8'hFF;
            ac10 <= 8'd0; ac12 <= 8'd0; ac14 <= 8'd0;
            crtc09 <= 8'd0; crtc0a <= 8'd0; crtc0b <= 8'd0; crtc0c <= 8'd0;
            crtc0d <= 8'd0; crtc0e <= 8'd0; crtc0f <= 8'd0; crtc13 <= 8'd0;
            crtc17 <= 8'd0;
            dac_mask <= 8'hFF; dac_ridx <= 8'd0; dac_widx <= 8'd0;
            dac_rsub <= 2'd0; dac_wsub <= 2'd0;
        end
    end

    // ---- the memory ----
    reg  [13:0] ca;                     // the CPU's port
    reg  [3:0]  cwe;
    reg  [31:0] cwd;
    reg  [31:0] cq;
    wire [13:0] va;                     // the display's
    reg  [31:0] vq;
    generate if (VGA_BRAM != 0) begin : bram
        reg [7:0] lane0 [0:16383];
        reg [7:0] lane1 [0:16383];
        reg [7:0] lane2 [0:16383];
        reg [7:0] lane3 [0:16383];
        always @(posedge clk) begin
            if (cwe[0]) lane0[ca] <= cwd[7:0];
            if (cwe[1]) lane1[ca] <= cwd[15:8];
            if (cwe[2]) lane2[ca] <= cwd[23:16];
            if (cwe[3]) lane3[ca] <= cwd[31:24];
            cq <= {lane3[ca], lane2[ca], lane1[ca], lane0[ca]};
        end
        always @(posedge vclk)
            vq <= {lane3[va], lane2[va], lane1[va], lane0[va]};
    end else begin : nobram
        // A board without the block RAM to spare: every word is in
        // its memory, and every line comes through the line buffer.
        always @(posedge clk) cq <= 32'd0;
        always @(posedge vclk) vq <= 32'd0;
    end endgenerate

    // ---- the CPU's side ----
    // The access in hand, and a write waiting behind it.
    reg        cur_v, cur_wr, cur_ph;
    reg [16:0] cur_a;
    reg [2:0]  cur_left;                // bytes still to do
    reg [1:0]  cur_k;                   // which byte of the access
    reg [31:0] cur_d;
    reg        cur_io, cur_word;        // it is a write to a port
    reg [51:0] fifo [0:3];              // {port, size, address, data}
    reg [1:0]  f_head;
    reg [2:0]  f_count;
    reg        st_rdy_r;
    reg [31:0] latch;

    assign st_rdy = st_rdy_r;

    wire bus_w = req && wr;
    wire bus_r = req && !wr && !ack;
    function [2:0] count(input [1:0] sz);
        count = (sz == 2'd0) ? 3'd1 : (sz == 2'd1) ? 3'd2 : 3'd4;
    endfunction

    // Where the byte in hand is.
    wire        chained = seq4[3];
    wire        oddeven = !seq4[2];
    reg         in_win;
    reg  [15:0] off;
    always @(*) begin
        case (gc6[3:2])
            2'd0: begin in_win = 1'b1;                 off = cur_a[15:0]; end
            2'd1: begin in_win = !cur_a[16];           off = cur_a[15:0]; end
            2'd2: begin in_win = (cur_a[16:15] == 2'b10); off = {1'b0, cur_a[14:0]}; end
            default: begin in_win = (cur_a[16:15] == 2'b11); off = {1'b0, cur_a[14:0]}; end
        endcase
    end
    wire [13:0] widx = chained ? off[15:2] : oddeven ? off[14:1] : off[13:0];
    wire [1:0]  lane = chained ? off[1:0] : oddeven ? {1'b0, off[0]} : 2'd0;
    wire        direct = chained || oddeven;
    // The word is past the block RAM.
    wire        ext    = (VGA_EXT != 0) && in_win && !cur_io &&
                         (VGA_BRAM == 0 || (!direct && off[15:14] != 2'b00));
    wire [31:0] mq     = ext ? x_rdata : cq;     // the word read
    assign x_req   = cur_v && ext;
    assign x_we    = cur_wr;
    // The step in hand is done in this cycle.
    wire        go     = cur_io || (ext ? x_ack : (cur_wr || cur_ph));
    assign rw_do   = cur_v && cur_io;
    assign rw_a    = cur_a[4:0];
    assign rw_wd   = cur_d[15:0];
    assign rw_word = cur_word;
    assign idle    = !cur_v && (f_count == 3'd0);
    wire [7:0]  wbyte = cur_d[7:0];

    // The graphics controller's write logic, for the four planes.
    wire [2:0]  rot_n = gc3[2:0];
    wire [15:0] rot2  = {wbyte, wbyte} >> rot_n;
    wire [7:0]  rot   = rot2[7:0];
    wire [1:0]  wmode = gc5[1:0];
    wire [7:0]  wmask = (wmode == 2'd3) ? (rot & gc8) : gc8;
    function [7:0] plane(input [7:0] lat, input sr, input en, input bit_p,
                         input [7:0] rot, input [1:0] wmode, input [1:0] fn,
                         input [7:0] mask);
        reg [7:0] src, f;
        begin
            src = (wmode == 2'd0) ? (en ? {8{sr}} : rot) :
                  (wmode == 2'd2) ? {8{bit_p}} : {8{sr}};
            f = (fn == 2'd1) ? (src & lat) :
                (fn == 2'd2) ? (src | lat) :
                (fn == 2'd3) ? (src ^ lat) : src;
            plane = (wmode == 2'd1) ? lat : ((f & mask) | (lat & ~mask));
        end
    endfunction
    wire [31:0] pw = {
        plane(latch[31:24], gc0[3], gc1[3], wbyte[3], rot, wmode, gc3[4:3], wmask),
        plane(latch[23:16], gc0[2], gc1[2], wbyte[2], rot, wmode, gc3[4:3], wmask),
        plane(latch[15:8],  gc0[1], gc1[1], wbyte[1], rot, wmode, gc3[4:3], wmask),
        plane(latch[7:0],   gc0[0], gc1[0], wbyte[0], rot, wmode, gc3[4:3], wmask) };

    // What a planar read returns, from the word just read.
    wire [7:0] same = ~((gc7[0] ? (mq[7:0]   ^ {8{gc2[0]}}) : 8'h00) |
                        (gc7[1] ? (mq[15:8]  ^ {8{gc2[1]}}) : 8'h00) |
                        (gc7[2] ? (mq[23:16] ^ {8{gc2[2]}}) : 8'h00) |
                        (gc7[3] ? (mq[31:24] ^ {8{gc2[3]}}) : 8'h00));
    wire [7:0] rplane = (gc4[1:0] == 2'd0) ? mq[7:0] : (gc4[1:0] == 2'd1) ? mq[15:8] :
                        (gc4[1:0] == 2'd2) ? mq[23:16] : mq[31:24];

    // A step does the bytes of the access that are in one word: all
    // four of a chained double word, both of a text cell; one in the
    // planar layout.
    wire [2:0]  inword = chained ? (3'd4 - {1'b0, off[1:0]}) :
                         oddeven ? (3'd2 - {2'd0, off[0]}) : 3'd1;
    wire [2:0]  n      = (cur_left < inword) ? cur_left : inword;
    wire [31:0] nmask  = (n == 3'd1) ? 32'h000000FF : (n == 3'd2) ? 32'h0000FFFF :
                         (n == 3'd3) ? 32'h00FFFFFF : 32'hFFFFFFFF;
    wire [3:0]  nlanes = (n == 3'd1) ? 4'b0001 : (n == 3'd2) ? 4'b0011 :
                         (n == 3'd3) ? 4'b0111 : 4'b1111;
    wire [31:0] rsrc   = !in_win ? 32'hFFFFFFFF :
                         direct ? (mq >> {lane, 3'b000}) :
                         {24'd0, gc5[3] ? same : rplane};

    assign x_sel   = direct ? (nlanes << lane) : seq2[3:0];
    assign x_addr  = direct ? {2'b00, widx} : off;
    assign x_wdata = direct ? (cur_d << {lane, 3'b000}) : pw;

    always @(*) begin
        ca  = widx;
        cwd = direct ? (cur_d << {lane, 3'b000}) : pw;
        cwe = 4'b0000;
        if (cur_v && cur_wr && in_win && !ext && !cur_io)
            cwe = direct ? (nlanes << lane) : seq2[3:0];
    end

    // The step in hand is the access's last, and done in this cycle.
    wire fin  = cur_v && go && (cur_left == n);
    wire take = !cur_v || fin;
    wire [51:0] f_q = fifo[f_head];
    wire pop  = take && (f_count != 3'd0);
    wire any_w = bus_w || io_wr;
    wire push = any_w && !(take && f_count == 3'd0);

    always @(posedge clk) begin
        ack <= 1'b0;
        if (cur_v) begin
            if (go) begin
                // Bytes written, or bytes read in.
                if (!cur_wr) begin
                    rdata <= rdata | ((rsrc & nmask) << {cur_k, 3'b000});
                    if (!direct && in_win)
                        latch <= mq;
                end
                cur_ph   <= 1'b0;
                cur_a    <= cur_a + {14'd0, n};
                cur_d    <= cur_d >> {n, 3'b000};
                cur_k    <= cur_k + n[1:0];
                cur_left <= cur_left - n;
                if (fin)
                    ack <= !cur_wr;
            end else
                cur_ph <= 1'b1;         // a read: the word is being read
        end
        // What is next: the oldest write that waits, a write that
        // arrives, a read that arrives. (The CPU holds a read until it
        // is answered, so a read waits for the writes before it.)
        if (take) begin
            cur_ph <= 1'b0;
            cur_k  <= 2'd0;
            if (f_count != 3'd0) begin
                cur_v <= 1'b1; cur_wr <= 1'b1; cur_io <= f_q[51];
                cur_a <= f_q[48:32]; cur_d <= f_q[31:0];
                cur_left <= f_q[51] ? 3'd1 : count(f_q[50:49]);
                cur_word <= f_q[49];
            end else if (any_w) begin
                cur_v <= 1'b1; cur_wr <= 1'b1; cur_io <= io_wr;
                cur_a <= io_wr ? {12'd0, io_a} : addr;
                cur_d <= io_wr ? {16'd0, io_wd} : wdata;
                cur_left <= io_wr ? 3'd1 : count(size);
                cur_word <= io_word;
            end else if (bus_r && (!cur_v || cur_wr)) begin
                cur_v <= 1'b1; cur_wr <= 1'b0; cur_io <= 1'b0;
                cur_a <= addr; cur_left <= count(size);
                rdata <= 32'd0;
            end else
                cur_v <= 1'b0;
        end
        if (push)
            fifo[f_head + f_count[1:0]] <= io_wr ? {1'b1, 1'b0, io_word, 12'd0, io_a, 16'd0, io_wd}
                                                 : {1'b0, size, addr, wdata};
        if (pop)
            f_head <= f_head + 2'd1;
        f_count <= f_count + {2'd0, push} - {2'd0, pop};
        // Room for the writes that may already be on their way.
        st_rdy_r <= (f_count + {2'd0, push} - {2'd0, pop}) <= 3'd1;
        if (rst) begin
            cur_v <= 1'b0; ack <= 1'b0; cur_ph <= 1'b0; cur_io <= 1'b0;
            f_head <= 2'd0; f_count <= 3'd0; st_rdy_r <= 1'b0;
        end
    end

    // ---- the display ----
    // 640 x 480: 800 clocks a line, 525 lines.
    reg [9:0] hc = 10'd0, vc = 10'd0;
    wire      line_end = (hc == 10'd799);
    always @(posedge vclk) begin
        if (line_end) begin
            hc <= 10'd0;
            vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1;
        end else
            hc <= hc + 10'd1;
        v_blank <= !((hc < 10'd640) && (vc < 10'd480));
        v_vs    <= (vc >= 10'd490 && vc < 10'd492);
    end

    // The mode, as the registers say.
    wire        graphics = gc6[0];
    wire        m256     = gc5[6];
    wire        cga4     = gc5[5] && !gc5[6];
    wire        cga_addr = !crtc17[0];      // lines alternate between two halves
    wire        half     = seq1[3];         // a pixel is two wide
    wire [15:0] start    = {crtc0c, crtc0d};
    wire [15:0] cursor   = {crtc0e, crtc0f};
    wire        cursor_off = crtc0a[5];

    // The cursor's place and the blink, once a picture.
    initial vf_t = 1'b0;
    reg [5:0]  frame = 6'd0;
    reg [15:0] cur0, cur_pos;
    reg        coff0, coff;
    always @(posedge vclk) begin
        if (hc == 10'd0) begin
            cur0 <= cursor;
            coff0 <= cursor_off;
        end
        if (hc == 10'd0 && vc == 10'd480) begin
            frame <= frame + 6'd1;
            cur_pos <= cur0;
            coff <= coff0;
        end
    end

    // The picture has 350, 400 or 480 lines, by the sync polarities a
    // program sets for them, centred in the 480; a 200-line mode's
    // lines are shown twice.
    wire [9:0]  vlines = (misc[7:6] == 2'b10) ? 10'd350 : (misc[7:6] == 2'b11) ? 10'd480 : 10'd400;
    wire [9:0]  vfirst = (misc[7:6] == 2'b10) ? 10'd65  : (misc[7:6] == 2'b11) ? 10'd0   : 10'd40;
    wire        twice  = crtc09[7] || (crtc09[4:0] == 5'd1);
    wire [9:0]  ty     = vc - vfirst;       // line of the picture
    wire        in_v   = (vc >= vfirst) && (vc < vfirst + vlines);
    wire [8:0]  sy     = twice ? {1'b0, ty[8:1]} : ty[8:0];     // source line
    wire        in_area = (hc < 10'd640) && in_v;
    wire        last_showing = !twice || ty[0];
    wire        before_first = (vfirst == 10'd0) ? (vc == 10'd524) : (vc == vfirst - 10'd1);

    // Stage 0: where the pixel's word is. Planes and 256 colours are
    // addressed by the word (`linear`): row_base is the source line's
    // first word, from the start address, a line length further each
    // line. The CGA's layouts count bytes in two halves.
    wire        linear = graphics && !cga4 && !cga_addr;
    wire        cga    = graphics && (cga4 || cga_addr);
    reg  [15:0] row_base, row_next;
    always @(*) begin
        row_next = row_base;
        if (before_first)
            row_next = linear ? start : 16'd0;
        else if (in_v && last_showing) begin
            if (linear)
                row_next = row_base + {7'd0, crtc13, 1'b0};
            else if (cga && sy[0])
                row_next = row_base + 16'd80;
        end
    end
    reg lpar = 1'b0;                        // which half of the line buffer this line is in
    always @(posedge vclk)
        if (line_end) begin
            row_base <= row_next;
            lpar <= !lpar;
        end

    wire [9:0]  sx     = half ? {1'b0, hc[9:1]} : hc;
    wire [6:0]  col    = (m256 || !half) ? hc[9:3] : {1'b0, hc[9:4]};
    wire [15:0] a_lin  = row_base + {9'd0, col};
    wire [15:0] a_cga4 = row_base + {sy[0], 13'd0} + {9'd0, hc[9:3]};
    wire [15:0] a_cga2 = row_base + {sy[0], 13'd0} + {9'd0, hc[9:3]};
    // Text: the cell at row * 80 + column, from the start address.
    wire [4:0]  trow   = ty[8:4];
    wire [6:0]  tcol   = hc[9:3];
    wire [15:0] tcell   = start + {5'd0, trow, 6'd0} + {7'd0, trow, 4'd0} + {9'd0, tcol};
    assign va = !graphics ? tcell[13:0] :
                cga4 ? a_cga4[14:1] : cga_addr ? a_cga2[13:0] : a_lin[13:0];

    // Words past the block RAM are in the board's memory. The line
    // after this one is asked for at this line's start, if any of it
    // is there, and read from the line buffer when it is shown.
    wire use_lb = (VGA_EXT != 0) &&
                  (VGA_BRAM == 0 || (linear && a_lin[15:14] != 2'b00));
    // The next line: is it shown at all, and where does it begin.
    wire        next_in = before_first || (in_v && ty != vlines - 10'd1);
    wire [9:0]  ty_n    = before_first ? 10'd0 : ty + 10'd1;
    wire        sy0_n   = twice ? ty_n[1] : ty_n[0];
    wire [4:0]  trow_n  = ty_n[8:4];
    wire [15:0] cga_n   = row_next + {sy0_n, 13'd0};
    wire [15:0] line_n  = !graphics ? start + {5'd0, trow_n, 6'd0} + {7'd0, trow_n, 4'd0} :
                          cga4 ? {1'b0, cga_n[15:1]} : cga_addr ? cga_n : row_next;
    wire need   = (VGA_EXT != 0) && next_in &&
                  (VGA_BRAM == 0 ||
                   (linear && (row_next[15:14] != 2'b00 || row_next[13:0] > 14'd16304)));
    always @(posedge vclk)
        if (hc == 10'd4 && need) begin
            vf_addr <= line_n;
            vf_par  <= !lpar;
            vf_t    <= !vf_t;
        end
    // Where a word is in its line: the CGA's four colours are two
    // bytes of a word, so half as many words.
    wire [6:0] lcol = !graphics ? tcol : cga4 ? {1'b0, hc[9:4]} : cga_addr ? hc[9:3] : col;
    assign lb_addr = {lpar, lcol};
    reg  use_lb1;
    wire [31:0] vw = use_lb1 ? lb_q : vq;

    // Stage 1: the word is being read. Stage 2: its pixel is picked
    // (text: the font row is being read). Stage 3: the colour number.
    // Stage 4: the colour is being read. Stage 5: out.
    reg [7:0] font [0:4095];
    reg [7:0] bits;
    initial $readmemh(FONT, font);

    reg [1:0]  ln1;                         // which byte of the word
    reg [2:0]  px1, px2;                    // which pixel of the byte
    reg [3:0]  fy1;
    reg        in1, in2, in3, in4;
    reg        de1, de2, de3, de4, hs1, hs2, hs3, hs4, vs1, vs2, vs3, vs4;
    reg        cu1, cu2;
    reg [7:0]  attr2;
    reg [7:0]  g2;                          // a graphics pixel: colour or number
    reg        g2_256;
    reg [7:0]  idx3;

    wire [7:0] vbyte = (ln1 == 2'd0) ? vw[7:0] : (ln1 == 2'd1) ? vw[15:8] :
                       (ln1 == 2'd2) ? vw[23:16] : vw[31:24];
    wire [2:0] bitn  = 3'd7 - px1;
    wire [3:0] planes = {vw[24 + bitn], vw[16 + bitn], vw[8 + bitn], vw[bitn]} & ac12[3:0];
    wire [1:0] pair  = vbyte >> {~px1[1:0], 1'b0};

    // A 16-colour value through the palette registers.
    function [7:0] attr_colour(input [5:0] p, input [7:0] ac10, input [7:0] ac14);
        attr_colour = {ac14[3:2], ac10[7] ? ac14[1:0] : p[5:4], p[3:0]};
    endfunction

    wire        ink   = (bits[3'd7 - px2] && !(attr2[7] && frame[5])) || cu2;
    wire [3:0]  tcolr = ink ? attr2[3:0] : {1'b0, attr2[6:4]};
    wire [3:0]  c16   = graphics ? g2[3:0] : tcolr;

    always @(posedge vclk) begin
        // 1
        ln1 <= m256 ? hc[2:1] : cga4 ? {1'b0, a_cga4[0]} : 2'd0;
        use_lb1 <= use_lb;
        px1 <= !graphics ? hc[2:0] : cga4 ? {1'b0, hc[2:1]} : sx[2:0];
        fy1 <= ty[3:0];
        in1 <= in_area && pas;
        de1 <= (hc < 10'd640) && (vc < 10'd480);
        hs1 <= !(hc >= 10'd656 && hc < 10'd752);
        vs1 <= !(vc >= 10'd490 && vc < 10'd492);
        cu1 <= (tcell == cur_pos) && !coff && ty[3:0] >= 4'd14 && frame[4] && !graphics;
        // 2
        px2 <= px1;
        in2 <= in1; de2 <= de1; hs2 <= hs1; vs2 <= vs1; cu2 <= cu1;
        attr2 <= vw[15:8];
        bits  <= font[{vw[7:0], fy1}];
        g2    <= m256 ? vbyte : cga4 ? {6'd0, pair} : {4'd0, planes};
        g2_256 <= graphics && m256;
        // 3
        idx3 <= (g2_256 ? g2 : attr_colour(pal[c16], ac10, ac14)) & dac_mask;
        in3 <= in2; de3 <= de2; hs3 <= hs2; vs3 <= vs2;
        // 4: dac_vq is being read at idx3
        in4 <= in3; de4 <= de3; hs4 <= hs3; vs4 <= vs3;
        // 5
        r <= in4 ? {dac_vq[17:12], dac_vq[17:16]} : 8'd0;
        g <= in4 ? {dac_vq[11:6],  dac_vq[11:10]} : 8'd0;
        b <= in4 ? {dac_vq[5:0],   dac_vq[5:4]}   : 8'd0;
        de <= de4; hsync <= hs4; vsync <= vs4;
    end
    always @(*) dac_va = idx3;
endmodule
