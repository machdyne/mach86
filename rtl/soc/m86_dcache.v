/*
 * Mach86 SoC -- the cache between the CPU and the main memory.
 *
 * The CPU reads and writes one, two or four bytes at any address and
 * expects a read answered in the next cycle and a write taken in the
 * cycle it is asked. Main memory (SDRAM, DDR3) gives words, slowly.
 * This holds 2**LINE_BITS lines of 16 bytes, direct-mapped, in four
 * byte lanes like m86_mem.v, so an access at any alignment is one
 * cycle when its line is here.
 *
 *   - A read that hits is answered in the cycle after the request.
 *     The CPU can also say a cycle early what it is about to read
 *     (e_req, e_addr, e_size: the address as it is being worked out,
 *     before the bus's own registers). Then the lookup is made at once
 *     and the answer is there in the very cycle the request appears
 *     on the bus. A read announced and then not asked for (the CPU
 *     found a fault) is dropped: the bus must then be without a read
 *     for that cycle, as the CPU's is.
 *   - A write goes through a queue of four. One that hits is done a
 *     cycle later, one a cycle; the line is marked dirty. st_rdy tells
 *     the CPU when it may start another write (the queue has room for
 *     those already on their way). Reads wait for the queue to empty,
 *     so a read never passes a write.
 *   - A miss fetches the line, four words, after writing back the line
 *     it replaces if that is dirty. Memory is only ever written back
 *     a whole line at a time.
 *   - An access may run over the end of a line into the next; then
 *     both lines must be here.
 *   - The data has a port for reading and one for writing, so a read
 *     can be looked up while the write before it is being done -- but
 *     not in the same words: then it waits a cycle. For the same
 *     reason a read announced in the very cycle a write arrives goes
 *     first, if they share no word, and the write waits in the queue:
 *     "store, then load" is what programs do all the time.
 *
 * The memory side is a word at a time: m_req with m_we, m_addr (word
 * address) and m_wdata until m_ack, which carries m_rdata for a read.
 * It is on the same clock; a bridge to another clock goes outside.
 */
module m86_dcache #(
    parameter AW = 26,              // address bits of the memory: 2**AW bytes
    parameter LINE_BITS = 12        // 2**LINE_BITS lines of 16 bytes
) (
    input  wire          clk,
    input  wire          rst,

    // The CPU's side.
    input  wire          req,       // as the CPU's bus: held for a read,
    input  wire          wr,        // one cycle for a write
    input  wire [AW-1:0] addr,
    input  wire [1:0]    size,
    input  wire [31:0]   wdata,
    input  wire          e_req,     // a read that will be on the bus next cycle
    input  wire          e_ok,      // ... and it is for this memory (may come late)
    input  wire [AW-1:0] e_addr,
    input  wire [1:0]    e_size,
    output wire [31:0]   rdata,
    output wire          ack,       // a read is answered
    // The same, but also when an announced read was not asked for
    // after all: for a CPU that knows it did not ask and does not
    // look. It does not wait for the bus's request, which arrives late.
    output wire          ack_any,
    output reg           st_rdy,    // a write may be started

    // The memory's side.
    output reg           m_req,
    output reg           m_we,
    output reg [AW-3:0]  m_addr,
    output reg [31:0]    m_wdata,
    input  wire [31:0]   m_rdata,
    input  wire          m_ack
);
    localparam IB = LINE_BITS;              // index bits
    localparam TB = AW - 4 - IB;            // tag bits
    localparam WB = IB + 2;                 // word index bits

    // ---- the write queue ----
    reg [AW+34-1:0] fifo [0:3];             // {size, addr, data}
    reg [1:0]  f_head;
    reg [2:0]  f_count;
    wire       f_empty = (f_count == 3'd0);
    wire [AW+34-1:0] f_out = fifo[f_head];

    // ---- the operation being checked (stage B) ----
    reg          s_v, s_wr;
    reg          s_early;                   // a read taken early, in its first cycle here
    reg [AW-1:0] s_addr;
    reg [1:0]    s_size;
    reg [31:0]   s_wdata;

    // ---- the state machine for misses ----
    localparam ST_RUN = 3'd0, ST_DIRTY2 = 3'd1, ST_VICTIM = 3'd2,
               ST_EVRD = 3'd3, ST_EVWR = 3'd4, ST_FILL = 3'd5, ST_REPLAY = 3'd6;
    reg [2:0]  st;
    reg [1:0]  k;                           // word of the line
    reg        second;                      // the line being fetched is the access's second
    reg        keep;                        // the line it replaces is being written back

    // ---- stage A: what is looked up this cycle ----
    wire bus_wr = req && wr;
    wire bus_rd = req && !wr;
    wire run    = (st == ST_RUN);
    // The operation in B has finished this cycle (or there is none).
    wire b_done;
    wire s_ok;                              // B holds an operation that stands
    wire a_free = run && (!s_v || b_done);
    // A read starts only when no write is queued or being checked, and
    // it is not the read already being checked.
    wire take_fifo = a_free && !f_empty;
    // A read on the bus that is not the one being checked already.
    wire reg_rd    = bus_rd && !(s_ok && !s_wr);
    // A read may be looked up while a write is being done, but not in
    // a word that the write touches. The same goes for an announced
    // read and a write that arrives with it.
    wire a_clash, e_clash, e_over;
    // An announced read is looked up at once if nothing else is to be:
    // sel_e chooses its address for the memories. That choice is made
    // without the address itself, which arrives late in the cycle;
    // whether the read is then taken (take_erd) may depend on it. It
    // is taken only if it lies within one word: the other kind needs
    // an addition on top of the address, and waits for the bus.
    wire [2:0] e_n   = (e_size == 2'd0) ? 3'd1 : (e_size == 2'd1) ? 3'd2 : 3'd4;
    wire e_fits      = ({1'b0, e_addr[1:0]} + e_n) <= 3'd4;
    wire replay      = (st == ST_REPLAY);
    wire sel_e       = !replay && f_empty && !reg_rd && e_req;
    wire take_rd     = a_free && f_empty && reg_rd && !a_clash;
    wire take_erd    = a_free && sel_e && e_ok && e_fits && !e_clash &&
                       !(bus_wr && e_over);
    // A write that arrives with an announced read goes to the queue.
    wire take_wr     = a_free && f_empty && bus_wr && !e_req;
    // The lookups are made only for an operation entering A: what they
    // gave is kept while a miss is dealt with.
    wire a_load    = a_free || replay;

    wire [AW-1:0] a_addr = replay ? s_addr : take_fifo ? f_out[32 +: AW] :
                           sel_e ? e_addr : addr;
    wire [1:0]    a_size = replay ? s_size : take_fifo ? f_out[AW+32 +: 2] :
                           sel_e ? e_size : size;
    wire [2:0]    a_n    = (a_size == 2'd0) ? 3'd1 : (a_size == 2'd1) ? 3'd2 : 3'd4;
    wire [AW-1:0] a_last = a_addr + {{(AW-3){1'b0}}, a_n} - 1'b1;

    // ---- tags: two lookups, for the first and the last byte ----
    reg  [TB:0]   tags [0:(1<<IB)-1];       // {valid, tag}
    reg  [TB:0]   tq_a, tq_b;
    reg           dirty [0:(1<<IB)-1];
    reg           dq;
    integer i;
    initial begin
        for (i = 0; i < (1 << IB); i = i + 1) begin
            tags[i] = {(TB+1){1'b0}};
            dirty[i] = 1'b0;
        end
    end

    wire [IB-1:0] s_idx_a = s_addr[4 +: IB];
    wire [2:0]    s_n     = (s_size == 2'd0) ? 3'd1 : (s_size == 2'd1) ? 3'd2 : 3'd4;
    wire [AW-1:0] s_last  = s_addr + {{(AW-3){1'b0}}, s_n} - 1'b1;
    wire [IB-1:0] s_idx_b = s_last[4 +: IB];
    wire          s_cross = (s_idx_a != s_idx_b);
    wire          hit_a   = tq_a[TB] && tq_a[TB-1:0] == s_addr[AW-1 -: TB];
    wire          hit_b   = tq_b[TB] && tq_b[TB-1:0] == s_last[AW-1 -: TB];
    wire          hit     = hit_a && hit_b;
    // A read taken early must be on the bus now, or it is dropped.
    wire          s_drop  = s_v && s_early && !bus_rd;
    assign        s_ok    = s_v && !s_drop;

    assign b_done = s_drop || (s_ok && hit && run && !(s_wr && s_cross));
    assign ack    = s_ok && !s_wr && hit && run;
    assign ack_any = s_v && !s_wr && hit && run;
    // Words in common, of 2**WB (the tags are not compared: a clash
    // too many costs a cycle).
    function overlap(input [AW-1:0] a0, input [AW-1:0] a1,
                     input [AW-1:0] b0, input [AW-1:0] b1);
        overlap = (a0[2 +: WB] == b0[2 +: WB]) || (a0[2 +: WB] == b1[2 +: WB]) ||
                  (a1[2 +: WB] == b0[2 +: WB]) || (a1[2 +: WB] == b1[2 +: WB]);
    endfunction
    wire [2:0]    w_n    = (size == 2'd0) ? 3'd1 : (size == 2'd1) ? 3'd2 : 3'd4;
    wire [AW-1:0] w_last = addr + {{(AW-3){1'b0}}, w_n} - 1'b1;
    wire          b_store = s_ok && s_wr;
    assign a_clash = b_store && overlap(addr, w_last, s_addr, s_last);
    // (An announced read is taken only if it lies in one word, so its
    // first byte's word is the only one to compare: no addition on
    // top of an address that arrives late.)
    assign e_clash = b_store && overlap(e_addr, e_addr, s_addr, s_last);
    assign e_over  = overlap(e_addr, e_addr, addr, w_last);

    // The line to bring in, and the one it replaces.
    wire [IB-1:0] f_idx  = second ? s_idx_b : s_idx_a;
    wire [TB-1:0] f_tag  = second ? s_last[AW-1 -: TB] : s_addr[AW-1 -: TB];
    wire [TB:0]   v_tagq = second ? tq_b : tq_a;

    wire          tag_we = (st == ST_FILL) && m_ack && (k == 2'd3);
    // (An announced read lies in one line: no need of a_last, which
    // is an addition later.)
    wire [AW-1:0] x_addr = replay ? s_addr : take_fifo ? f_out[32 +: AW] : addr;
    wire [1:0]    x_size = replay ? s_size : take_fifo ? f_out[AW+32 +: 2] : size;
    wire [2:0]    x_n    = (x_size == 2'd0) ? 3'd1 : (x_size == 2'd1) ? 3'd2 : 3'd4;
    wire [AW-1:0] x_last = x_addr + {{(AW-3){1'b0}}, x_n} - 1'b1;
    wire [IB-1:0] ta_idx = tag_we ? f_idx : sel_e ? e_addr[4 +: IB] : x_addr[4 +: IB];
    wire [IB-1:0] tb_idx = sel_e ? e_addr[4 +: IB] : x_last[4 +: IB];
    always @(posedge clk) begin
        if (tag_we)
            tags[ta_idx] <= {1'b1, f_tag};
        if (a_load) begin
            tq_a <= tags[ta_idx];
            tq_b <= tags[tb_idx];
        end
    end

    // Dirty bits: set by a write that hits, cleared by a fetch.
    wire          store_hit = s_ok && s_wr && hit && run;
    wire          d_we  = store_hit || (st == ST_DIRTY2) || tag_we;
    wire [IB-1:0] d_idx = tag_we ? f_idx : (st == ST_DIRTY2) ? s_idx_b :
                          store_hit ? s_idx_a : f_idx;
    always @(posedge clk) begin
        if (d_we)
            dirty[d_idx] <= !tag_we;
        dq <= dirty[d_idx];
    end

    // ---- the data, in four byte lanes ----
    reg [7:0] lane0 [0:(1<<WB)-1];
    reg [7:0] lane1 [0:(1<<WB)-1];
    reg [7:0] lane2 [0:(1<<WB)-1];
    reg [7:0] lane3 [0:(1<<WB)-1];
    reg [7:0] q0, q1, q2, q3;
    reg [1:0] rot;

    // Reading: a word of the line being written back, or the bytes of
    // the operation being looked up.
    wire [WB-1:0] line_w   = {f_idx, k};
    wire          line_rd  = (st == ST_EVRD);
    // (An announced read lies in one word: all four lanes at e_addr's.)
    wire          rd_e     = sel_e && !line_rd;
    wire [1:0]    xa       = line_rd ? 2'd0 : x_addr[1:0];
    wire [WB-1:0] xw       = line_rd ? line_w : x_addr[2 +: WB];
    wire [WB-1:0] xw1      = xw + 1'b1;
    wire [WB-1:0] ew       = e_addr[2 +: WB];
    wire [1:0]    ra = rd_e ? e_addr[1:0] : xa;
    wire [WB-1:0] r0 = rd_e ? ew : (xa > 2'd0) ? xw1 : xw;
    wire [WB-1:0] r1 = rd_e ? ew : (xa > 2'd1) ? xw1 : xw;
    wire [WB-1:0] r2 = rd_e ? ew : (xa > 2'd2) ? xw1 : xw;
    wire [WB-1:0] r3 = rd_e ? ew : xw;

    // Writing: a word of the line being fetched, or the CPU's bytes.
    wire          fill_we = (st == ST_FILL) && m_ack;
    wire          cpu_wr  = store_hit;
    wire [1:0]    wa       = fill_we ? 2'd0 : s_addr[1:0];
    wire [WB-1:0] ww       = fill_we ? line_w : s_addr[2 +: WB];
    wire [WB-1:0] ww1      = ww + 1'b1;
    wire [WB-1:0] i0 = (wa > 2'd0) ? ww1 : ww;
    wire [WB-1:0] i1 = (wa > 2'd1) ? ww1 : ww;
    wire [WB-1:0] i2 = (wa > 2'd2) ? ww1 : ww;
    wire [WB-1:0] i3 = ww;
    wire [1:0] b0 = 2'd0 - wa, b1 = 2'd1 - wa, b2 = 2'd2 - wa, b3 = 2'd3 - wa;
    wire [31:0]   l_wd    = fill_we ? m_rdata : s_wdata;
    wire [2:0]    l_n     = fill_we ? 3'd4 : s_n;
    wire          l_we    = fill_we || cpu_wr;

    always @(posedge clk) begin
        if (l_we && {1'b0, b0} < l_n) lane0[i0] <= l_wd[8*b0 +: 8];
        if (l_we && {1'b0, b1} < l_n) lane1[i1] <= l_wd[8*b1 +: 8];
        if (l_we && {1'b0, b2} < l_n) lane2[i2] <= l_wd[8*b2 +: 8];
        if (l_we && {1'b0, b3} < l_n) lane3[i3] <= l_wd[8*b3 +: 8];
        if (a_load || line_rd) begin
            q0 <= lane0[r0];
            q1 <= lane1[r1];
            q2 <= lane2[r2];
            q3 <= lane3[r3];
            rot <= ra;
        end
    end
    wire [31:0] q = {q3, q2, q1, q0};
    assign rdata = (rot == 2'd0) ? q :
                   (rot == 2'd1) ? {q[7:0],  q[31:8]} :
                   (rot == 2'd2) ? {q[15:0], q[31:16]} :
                                   {q[23:0], q[31:24]};

    // ---- sequencing ----
    wire push = bus_wr && !take_wr;
    wire pop  = take_fifo;

    always @(posedge clk) begin
        if (push)
            fifo[f_head + f_count[1:0]] <= {size, addr, wdata};
        if (pop)
            f_head <= f_head + 2'd1;
        f_count <= f_count + {2'd0, push} - {2'd0, pop};
        // Room for the writes that may already be on their way.
        st_rdy <= (f_count + {2'd0, push} - {2'd0, pop}) <= 3'd1;

        case (st)
            ST_RUN: begin
                s_early <= 1'b0;
                if (s_ok && !hit) begin
                    // A miss: bring in the first line that is not here.
                    second <= hit_a;
                    st <= ST_VICTIM;
                end else if (s_ok && s_wr && s_cross) begin
                    st <= ST_DIRTY2;        // the second line's dirty bit
                end else begin
                    s_v <= take_fifo || take_wr || take_rd || take_erd;
                    s_early <= !take_fifo && !take_wr && !take_rd && take_erd;
                    s_wr <= take_fifo || take_wr;
                    s_addr <= a_addr;
                    s_size <= a_size;
                    s_wdata <= take_fifo ? f_out[31:0] : wdata;
                end
            end
            ST_DIRTY2: begin
                s_v <= 1'b0;
                st <= ST_RUN;
            end
            ST_VICTIM: begin
                // The dirty bit of the line to be replaced is being read.
                k <= 2'd0;
                st <= ST_EVRD;
            end
            ST_EVRD: begin
                // A word of the old line is being read. It goes back to
                // memory only if the line is valid and dirty (the dirty
                // bit is on dq in the first of these cycles).
                if (k == 2'd0)
                    keep <= v_tagq[TB] && dq;
                if (k == 2'd0 && !(v_tagq[TB] && dq))
                    st <= ST_FILL;
                else
                    st <= ST_EVWR;
            end
            ST_EVWR: begin
                if (m_ack) begin
                    k <= k + 2'd1;
                    st <= (k == 2'd3) ? ST_FILL : ST_EVRD;
                end
            end
            ST_FILL: begin
                if (m_ack) begin
                    k <= k + 2'd1;
                    if (k == 2'd3)
                        st <= ST_REPLAY;
                end
            end
            ST_REPLAY: st <= ST_RUN;        // the operation is looked up again
            default: st <= ST_RUN;
        endcase

        if (rst) begin
            f_head <= 2'd0; f_count <= 3'd0; st_rdy <= 1'b0;
            s_v <= 1'b0; st <= ST_RUN; k <= 2'd0; second <= 1'b0; s_early <= 1'b0;
        end
    end

    // The memory side.
    always @(*) begin
        m_req   = 1'b0;
        m_we    = 1'b0;
        m_addr  = {f_tag, f_idx, k};
        m_wdata = q;
        if (st == ST_EVWR) begin
            m_req  = 1'b1;
            m_we   = 1'b1;
            m_addr = {v_tagq[TB-1:0], f_idx, k};
        end else if (st == ST_FILL) begin
            m_req = 1'b1;
        end
    end
endmodule
