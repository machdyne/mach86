/*
 * Mach86 -- test bench for the cache (rtl/soc/m86_dcache.v).
 *
 * Random reads and writes of one, two and four bytes at any address,
 * driven the way the CPU drives its bus (a read held until answered,
 * a write for one cycle and only when st_rdy allows), against a
 * memory behind the cache that answers after a random delay. Every
 * read is compared with a plain copy of what was written; at the end
 * the copy is compared with the cache and the memory together.
 *
 * The cache is small (16 lines) and the address space 4 KB, so lines
 * are replaced constantly and accesses often straddle two lines.
 */
`timescale 1ns/1ps
module m86_dcache_tb;
    parameter AW = 12, LB = 4, OPS = 200000;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg           req = 0, wr = 0;
    reg  [AW-1:0] addr = 0;
    reg  [1:0]    size = 0;
    reg  [31:0]   wdata = 0;
    // A read may be announced a cycle before it is on the bus.
    reg           e_req = 0;
    reg  [AW-1:0] e_addr = 0;
    reg  [1:0]    e_size = 0;
    wire [31:0]   rdata;
    wire          ack, st_rdy;
    wire          m_req, m_we;
    wire [AW-3:0] m_addr;
    wire [31:0]   m_wdata;
    reg  [31:0]   m_rdata;
    reg           m_ack = 0;

    m86_dcache #(.AW(AW), .LINE_BITS(LB)) dut (
        .clk(clk), .rst(rst), .req(req), .wr(wr), .addr(addr), .size(size),
        .wdata(wdata), .e_req(e_req), .e_ok(1'b1), .e_addr(e_addr), .e_size(e_size),
        .rdata(rdata), .ack(ack), .st_rdy(st_rdy),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack));

    // The memory: words, a random delay.
    reg [31:0] mem [0:(1<<(AW-2))-1];
    integer    delay = 0;
    always @(posedge clk) begin
        m_ack <= 0;
        if (m_req && !m_ack) begin
            if (delay == 0) begin
                m_ack <= 1;
                if (m_we) mem[m_addr] <= m_wdata;
                else m_rdata <= mem[m_addr];
                delay <= $random & 3;
            end else
                delay <= delay - 1;
        end
    end

    // What every byte should be.
    reg [7:0] ref [0:(1<<AW)-1];
    integer   i, n, errors = 0, reads = 0, writes = 0, gap;
    reg [31:0] want, mask;
    reg [AW-1:0] a;
    reg [1:0]    sz, pre_sz;
    reg [AW-1:0] pre_a;
    reg          pre_v = 0;

    initial begin
        for (i = 0; i < (1 << (AW-2)); i = i + 1) mem[i] = $random;
        for (i = 0; i < (1 << AW); i = i + 1)
            ref[i] = mem[i >> 2] >> (8 * (i & 3));
        repeat (4) @(posedge clk);
        rst <= 0;
        @(posedge clk);
        for (n = 0; n < OPS; n = n + 1) begin
            a = $random;
            // Stay inside the memory, and often near a line's end.
            if (($random & 3) == 0) a = (a & ~12'hF) | (12 + ($random & 3));
            if (a > (1 << AW) - 4) a = a - 4;
            sz = ($random & 3) % 3;
            if (pre_v) begin
                a = pre_a; sz = pre_sz;     // the read announced during a write
            end
            size <= sz;
            addr <= a;
            wdata <= $random;
            if (!pre_v && ($random & 1)) begin
                // A write: one cycle, when allowed. The CPU may
                // announce its next read in that same cycle.
                while (!st_rdy) @(posedge clk);
                req <= 1; wr <= 1;
                if ($random & 1) begin
                    pre_v = 1;
                    pre_sz = ($random & 3) % 3;
                    pre_a = $random;
                    if ($random & 1) pre_a = a + ($random & 7) - 4;   // near the write
                    if (pre_a > (1 << AW) - 4) pre_a = pre_a - 4;
                    e_req <= 1; e_addr <= pre_a; e_size <= pre_sz;
                end
                @(posedge clk);
                e_req <= 0;
                for (i = 0; i < (1 << size); i = i + 1)
                    ref[addr + i] = wdata >> (8 * i);
                writes = writes + 1;
                req <= 0; wr <= 0;
            end else begin
                // A read: mostly announced a cycle early, as the CPU
                // does; sometimes announced and then not made.
                if (pre_v)
                    pre_v = 0;              // announced already
                else if ($random & 3) begin
                    e_req <= 1; e_addr <= a; e_size <= sz;
                    @(posedge clk);
                    e_req <= 0;
                    if (($random & 7) == 0) begin
                        // Announced and not made (the CPU found a
                        // fault): the bus is idle, then the read is
                        // made after all, the ordinary way.
                        @(posedge clk);
                        if ($random & 1) @(posedge clk);
                    end
                end
                req <= 1; wr <= 0;
                @(posedge clk);
                while (!ack) @(posedge clk);
                want = 0;
                for (i = 0; i < (1 << size); i = i + 1)
                    want = want | (ref[addr + i] << (8 * i));
                mask = (size == 0) ? 32'hFF : (size == 1) ? 32'hFFFF : 32'hFFFFFFFF;
                if ((rdata & mask) !== want) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("read %0d of %h size %0d: got %h, want %h",
                                 n, addr, 1 << size, rdata & mask, want);
                end
                reads = reads + 1;
                req <= 0;
            end
            // Sometimes back to back, sometimes a pause.
            gap = $random & 3;
            if (gap == 3) repeat (2) @(posedge clk);
        end
        // (A read announced with the last write and never made: the CPU
        // leaves the bus idle for a cycle then, and the cache relies
        // on it -- a different read straight away would be taken for
        // the one announced.)
        if (pre_v) @(posedge clk);
        // Everything written must be in the cache or the memory: read it all.
        for (n = 0; n < (1 << AW); n = n + 1) begin
            addr <= n; size <= 0; req <= 1; wr <= 0;
            @(posedge clk);
            while (!ack) @(posedge clk);
            if (rdata[7:0] !== ref[n]) errors = errors + 1;
            req <= 0;
        end
        $display("dcache: %0d reads, %0d writes, %0d errors", reads, writes, errors);
        if (errors == 0) $display("dcache: pass");
        else begin $display("dcache: FAIL"); $fatal; end
        $finish;
    end

    initial begin
        #400000000;
        $display("dcache: FAIL (stuck)");
        $fatal;
    end
endmodule
