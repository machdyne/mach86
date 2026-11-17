/*
 * Mach86 -- test bench for the FM synthesiser: the RTL against the
 * reference model, sample for sample. The script of register writes
 * and the samples the model made of it are read from files
 * (+script=, +expect=); a write is made while the synthesiser rests,
 * then the script's number of samples.
 */
`timescale 1ns / 1ps
module m86_opl2_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, we = 0, start = 0;
    reg [7:0] wa = 0, wd = 0;
    wire signed [15:0] sample;
    m86_opl2 #(.ROM("../output/opl/opl_rom.hex")) dut (
        .clk(clk), .we(we), .wa(wa), .wd(wd),
        .aclk(clk), .arst(rst), .start(start), .sample(sample));

    reg [15:0] expect_mem [0:(1 << 20) - 1];
    reg [1023:0] sname, ename;
    integer fd, r, n, reg_, val, i, got = 0, errors = 0, nonzero = 0;

    // One sample: start, and wait for the 18 operators.
    task one;
        begin
            @(posedge clk); start <= 1;
            @(posedge clk); start <= 0;
            // What it shows now is the sample before.
            @(posedge clk);
            if (got > 0) begin
                if (sample !== expect_mem[got - 1]) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("sample %0d: %0d, the model has %0d", got - 1, sample,
                                 $signed(expect_mem[got - 1]));
                end
                if (sample != 0) nonzero = nonzero + 1;
            end
            got = got + 1;
            repeat (270) @(posedge clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("script=%s", sname) || !$value$plusargs("expect=%s", ename)) begin
            $display("usage: +script=FILE +expect=FILE");
            $finish;
        end
        $readmemh(ename, expect_mem);
        repeat (5) @(posedge clk);
        rst = 0;
        fd = $fopen(sname, "r");
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%x %x %x\n", n, reg_, val);
            if (r == 3) begin
                @(posedge clk); we <= 1; wa <= reg_; wd <= val;
                @(posedge clk); we <= 0;
                for (i = 0; i < n; i = i + 1) one;
            end
        end
        one;                                    // the last sample out
        $display("opl: %0d samples compared, %0d not silent, %0d differ",
                 got - 1, nonzero, errors);
        if (errors == 0 && nonzero > (got - 1) / 2) $display("opl: pass");
        else $display("opl: FAIL");
        $finish;
    end
endmodule
