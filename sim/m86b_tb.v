/*
 * Mach86 CPU, design B -- test bench.
 *
 * Runs tests/prog/bloop.asm from reset, through the decoder and then
 * from the decoded-instruction cache, and checks the result and the
 * instruction count. Prints cycles per instruction.
 *
 * With +rom=FILE (a 64 KB image as hex bytes) it runs that program
 * until HLT or +max=CYCLES and reports instructions and cycles.
 */
`timescale 1ns/1ps
module m86b_tb;
    reg clk = 0, rst = 1;
    always #10 clk = ~clk;

    wire        d_req, d_wr, halted;
    wire [31:0] d_addr, d_wdata, dbg_insns;
    wire [1:0]  d_size;
    wire [7:0]  last_exc;
    reg  [7:0]  mem [0:1048575];
    wire [19:0] a = d_addr[19:0];
    wire [31:0] d_rdata = {mem[a + 20'd3], mem[a + 20'd2], mem[a + 20'd1], mem[a]};

    m86b_core dut (
        .clk(clk), .rst(rst),
        .d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_size(d_size),
        .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ack(d_req),
        .slow(8'd0), .dma_req(1'b0), .dma_addr(24'd0), .d_st_rdy(1'b1), .d_io(), .irq(1'b0), .irq_vec(8'd0), .inta(), .step_done(),
        .halted(halted), .last_exc(last_exc), .dbg_insns(dbg_insns));

    always @(posedge clk)
        if (d_req && d_wr) begin
            mem[a] <= d_wdata[7:0];
            if (d_size != 2'd0) mem[a + 20'd1] <= d_wdata[15:8];
            if (d_size == 2'd2) begin
                mem[a + 20'd2] <= d_wdata[23:16];
                mem[a + 20'd3] <= d_wdata[31:24];
            end
        end

    integer cycles = 0, i, max_cycles;
    reg [1023:0] rom;
    always @(posedge clk)
        if (!rst && !halted)
            cycles = cycles + 1;

    wire [15:0] ax = {dut.rf1[0], dut.rf0[0]};
    wire [15:0] dx = {dut.rf1[2], dut.rf0[2]};

    initial begin
        for (i = 0; i < 1048576; i = i + 1)
            mem[i] = 8'h00;
        if (!$value$plusargs("rom=%s", rom))
            rom = "bloop.hex";
        if (!$value$plusargs("max=%d", max_cycles))
            max_cycles = 200000;
        $readmemh(rom, mem, 20'hF0000);
        repeat (3) @(posedge clk);
        rst = 0;
        wait (halted || cycles > max_cycles);
        @(posedge clk);
        $display("instructions %0d, cycles %0d, ax %h, dx %0d, last fault %h",
                 dbg_insns, cycles, ax, dx, last_exc);
        if ($test$plusargs("rom")) begin
            // Another program: report, and leave the checking to the caller.
            $display("halted %0d", halted);
            $finish;
        end
        if (halted && ax == 16'hA314 && dx == 16'd1000 && dbg_insns == 8006) begin
            $display("cycles per instruction: %0d.%02d", cycles / 8006,
                     (cycles * 100 / 8006) % 100);
            $display("m86b: pass");
        end else begin
            $display("m86b: FAIL");
            $fatal;
        end
        $finish;
    end
endmodule
