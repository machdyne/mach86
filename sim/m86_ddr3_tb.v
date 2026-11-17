/*
 * Mach86 -- test bench for the main memory path on a DDR3 board:
 *
 *   cache (rtl/soc/m86_dcache.v)
 *     -> clock crossing (rtl/soc/m86_xclk.v), 31.5 MHz to 48 MHz
 *       -> Zeitlos's DDR3 controller and registers (rtl/ext/zeitlos/ddr3.v)
 *         -> Zeitlos's behavioural PHY and DRAM model, which checks the
 *            DDR3 protocol and timing
 *
 * and a second crossing to the controller's registers, as the BIOS's
 * trainer uses them. The stimulus is that of sim/m86_dcache_tb.v:
 * random reads and writes of one, two and four bytes at any address,
 * driven the way the CPU drives its bus, checked against a plain copy.
 * The two clocks are unrelated, as on the board.
 *
 * What this does NOT cover is the real PHY (rtl/ext/zeitlos/
 * ddr3_phy_ecp5.v) and so the training: those are proven on Zeitlos's
 * hardware and can only be tried on ours.
 */
`timescale 1ps/1ps
module m86_ddr3_tb;
    parameter AW = 12, LB = 4, OPS = 20000;
    reg clk = 0, rst = 1;
    always #15873 clk = ~clk;               // 31.5 MHz

    // The memory's clocks: 96 MHz, and half of it rising with it.
    reg ck = 0, clk48 = 0, rst48 = 1;
    always #5208 ck = ~ck;
    initial begin
        @(negedge ck);
        forever begin
            @(posedge ck) clk48 = 1'b1;
            @(posedge ck) clk48 = 1'b0;
        end
    end

    reg           req = 0, wr = 0;
    reg  [AW-1:0] addr = 0;
    reg  [1:0]    size = 0;
    reg  [31:0]   wdata = 0;
    wire [31:0]   rdata;
    wire          ack, st_rdy;
    wire          m_req, m_we;
    wire [AW-3:0] m_addr;
    wire [31:0]   m_wdata;
    wire [31:0]   m_rdata;
    wire          m_ack;

    m86_dcache #(.AW(AW), .LINE_BITS(LB)) dut (
        .clk(clk), .rst(rst), .req(req), .wr(wr), .addr(addr), .size(size),
        .wdata(wdata), .e_req(1'b0), .e_ok(1'b1), .e_addr({AW{1'b0}}), .e_size(2'd0),
        .rdata(rdata), .ack(ack), .st_rdy(st_rdy),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack));

    wire        wb_stb, wb_we, wb_ack;
    wire [23:0] wb_adr;
    wire [31:0] wb_dat_w, wb_dat_r;
    m86_xclk #(.AW(24)) xm (
        .a_clk(clk), .a_rst(rst), .a_req(m_req), .a_we(m_we),
        .a_addr({{(26-AW){1'b0}}, m_addr}), .a_wdata(m_wdata),
        .a_rdata(m_rdata), .a_ack(m_ack),
        .b_clk(clk48), .b_rst(rst48), .b_stb(wb_stb), .b_we(wb_we),
        .b_addr(wb_adr), .b_wdata(wb_dat_w), .b_rdata(wb_dat_r), .b_ack(wb_ack));

    reg         x_req = 0, x_we = 0;
    reg  [1:0]  x_addr = 0;
    reg  [31:0] x_wdata = 0;
    wire [31:0] x_rdata;
    wire        x_ack;
    wire        rg_stb, rg_we, rg_ack;
    wire [1:0]  rg_adr;
    wire [31:0] rg_dat_w, rg_dat_r;
    m86_xclk #(.AW(2)) xr (
        .a_clk(clk), .a_rst(rst), .a_req(x_req), .a_we(x_we),
        .a_addr(x_addr), .a_wdata(x_wdata), .a_rdata(x_rdata), .a_ack(x_ack),
        .b_clk(clk48), .b_rst(rst48), .b_stb(rg_stb), .b_we(rg_we),
        .b_addr(rg_adr), .b_wdata(rg_dat_w), .b_rdata(rg_dat_r), .b_ack(rg_ack));

    wire [15:0] d_a;
    wire [2:0]  d_ba;
    wire        d_ras_n, d_cas_n, d_we_n, d_cs_n, d_cke, d_odt, d_reset_n, d_ck;
    wire [1:0]  d_dm, d_dqs;
    wire [15:0] d_dq;
    ddr3 #(.ROW_BITS(15), .TRFC_NS(260), .WCOMBINE(0)) mem (
        .clk_i(clk48), .rst_i(rst48),
        .eclk_i(ck), .ddrdel_i(1'b0), .pause_i(1'b0), .phy_rst_i(rst48),
        .phy_ready_i(1'b1), .pll_locked_i(1'b1),
        .wb_adr_i({3'b000, wb_adr}), .wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_r),
        .wb_we_i(wb_we), .wb_sel_i(4'b1111), .wb_stb_i(wb_stb),
        .wb_cyc_i(wb_stb), .wb_ack_o(wb_ack),
        .reg_adr_i(rg_adr), .reg_dat_i(rg_dat_w), .reg_dat_o(rg_dat_r),
        .reg_we_i(rg_we), .reg_stb_i(rg_stb), .reg_cyc_i(rg_stb),
        .reg_ack_o(rg_ack),
        .ddr3_a(d_a), .ddr3_ba(d_ba), .ddr3_ras_n(d_ras_n),
        .ddr3_cas_n(d_cas_n), .ddr3_we_n(d_we_n), .ddr3_cs_n(d_cs_n),
        .ddr3_cke(d_cke), .ddr3_odt(d_odt), .ddr3_reset_n(d_reset_n),
        .ddr3_dm(d_dm), .ddr3_dq(d_dq), .ddr3_dqs_p(d_dqs), .ddr3_clk_p(d_ck));
    // The power-on waits, shortened (Zeitlos's test bench does the same).
    defparam mem.ctrl.INIT_DIV = 1000;

    ddr3_model #(.ROW_BITS(15), .COL_BITS(10), .BANK_BITS(3), .ROW_ALIAS(6),
                 .TCK_PS(10417)) dram (
        .ck(d_ck), .reset_n(d_reset_n), .cke(d_cke), .cs_n(d_cs_n),
        .ras_n(d_ras_n), .cas_n(d_cas_n), .we_n(d_we_n), .a(d_a), .ba(d_ba),
        .dm(d_dm), .dq(d_dq), .dqs(d_dqs));

    // A register of the controller, as the BIOS reaches it.
    reg [31:0] xq;
    task reg_op(input w, input [1:0] a, input [31:0] v);
    begin
        x_we <= w; x_addr <= a; x_wdata <= v; x_req <= 1;
        @(posedge clk);
        while (!x_ack) @(posedge clk);
        xq = x_rdata;
        x_req <= 0;
        @(posedge clk);
    end
    endtask

    // What every byte should be.
    reg [7:0] ref [0:(1<<AW)-1];
    integer   i, n, errors = 0, reads = 0, writes = 0, gap;
    reg [31:0] want, mask;
    reg [AW-1:0] a;

    initial begin
        repeat (8) @(posedge clk48);
        rst48 = 0;
        repeat (4) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        // The registers: the status says who it is; wait for the DRAM.
        reg_op(0, 2'd0, 0);
        if (xq[31:16] !== 16'hdd30) begin
            $display("ddr3: status %h, no controller there", xq);
            errors = errors + 1;
        end
        while (!xq[0]) reg_op(0, 2'd0, 0);
        $display("ddr3: status %h", xq);
        reg_op(1, 2'd1, 32'h09573231);          // a tune value: takes a while
        reg_op(0, 2'd1, 0);
        if (xq !== 32'h09573231) begin
            $display("ddr3: tune reads %h", xq); errors = errors + 1;
        end
        reg_op(1, 2'd2, 32'd1);                 // hold refresh, and let go
        reg_op(0, 2'd2, 0);
        if (xq !== 32'd1) begin
            $display("ddr3: control reads %h", xq); errors = errors + 1;
        end
        reg_op(1, 2'd2, 32'd0);

        // The memory holds nothing yet: fill it, a whole line at a time.
        for (n = 0; n < (1 << AW); n = n + 4) begin
            while (!st_rdy) @(posedge clk);
            addr <= n; size <= 2; wdata <= $random; req <= 1; wr <= 1;
            @(posedge clk);
            for (i = 0; i < 4; i = i + 1)
                ref[addr + i] = wdata >> (8 * i);
            req <= 0; wr <= 0;
        end
        @(posedge clk);
        for (n = 0; n < OPS; n = n + 1) begin
            a = $random;
            // Stay inside the memory, and often near a line's end.
            if (($random & 3) == 0) a = (a & ~12'hF) | (12 + ($random & 3));
            if (a > (1 << AW) - 4) a = a - 4;
            size <= ($random & 3) % 3;
            addr <= a;
            wdata <= $random;
            if ($random & 1) begin
                // A write: one cycle, when allowed.
                while (!st_rdy) @(posedge clk);
                req <= 1; wr <= 1;
                @(posedge clk);
                for (i = 0; i < (1 << size); i = i + 1)
                    ref[addr + i] = wdata >> (8 * i);
                writes = writes + 1;
                req <= 0; wr <= 0;
            end else begin
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
        // Everything written must be in the cache or the memory: read it all.
        for (n = 0; n < (1 << AW); n = n + 1) begin
            addr <= n; size <= 0; req <= 1; wr <= 0;
            @(posedge clk);
            while (!ack) @(posedge clk);
            if (rdata[7:0] !== ref[n]) errors = errors + 1;
            req <= 0;
        end
        // The DRAM model counts what the controller did wrong.
        if (dram.errors != 0) begin
            $display("ddr3: the DRAM model complained %0d times", dram.errors);
            errors = errors + dram.errors;
        end
        $display("ddr3: %0d reads, %0d writes, %0d errors", reads, writes, errors);
        if (errors == 0) $display("ddr3: pass");
        else begin $display("ddr3: FAIL"); $fatal; end
        $finish;
    end

    initial begin
        #64000000000000;
        $display("ddr3: FAIL (stuck)");
        $fatal;
    end
endmodule
