/*
 * Mach86 SoC -- the two interrupt controllers (8259A), master at ports
 * 20h/21h and slave at A0h/A1h, cascaded on the master's input 2.
 *
 * Sources: Intel 8259A data sheet; behaviour as in the reference
 * model, sim/pc.c, which is what the BIOS and DOS have been run
 * against. What is here: edge-triggered requests, fully nested
 * priority, the four initialisation words (only the vector base is
 * used), the mask, specific and non-specific end of interrupt, and
 * reading the request or in-service register. Not here: rotation,
 * special mask mode, polling, level triggering.
 *
 * A request is a one-cycle pulse on req. When the CPU takes the
 * interrupt it raises inta for a cycle; vec is valid in that cycle
 * and the controllers move the request to "in service" at its end.
 */
module m86_pic (
    input  wire        clk,
    input  wire        rst,
    input  wire        cs_m,        // ports 20h, 21h
    input  wire        cs_s,        // ports A0h, A1h
    input  wire        a0,
    input  wire        wr,
    input  wire [7:0]  wdata,
    output wire [7:0]  rdata,
    input  wire [15:0] req,
    output wire        irq,
    input  wire        inta,
    output wire [7:0]  vec
);
    reg [7:0] irr [0:1];
    reg [7:0] imr [0:1];
    reg [7:0] isr [0:1];
    reg [7:0] base [0:1];
    reg [1:0] step [0:1];
    reg       icw4 [0:1];
    reg       rdisr [0:1];

    // The highest-priority unmasked request, unless one of the same
    // or higher priority is in service. Bit 3 of the result: found.
    function [3:0] pending(input [7:0] r, input [7:0] s);
        integer n;
        reg stop;
        begin
            pending = 4'd0;
            stop = 1'b0;
            for (n = 0; n < 8; n = n + 1)
                if (!stop) begin
                    if (s[n])
                        stop = 1'b1;
                    else if (r[n]) begin
                        pending = {1'b1, n[2:0]};
                        stop = 1'b1;
                    end
                end
        end
    endfunction

    // The lowest set bit (the highest priority in service).
    function [7:0] lowest(input [7:0] s);
        lowest = s & (~s + 8'd1);
    endfunction

    wire [3:0] ps = pending(irr[1] & ~imr[1], isr[1]);
    // The slave's request is the master's input 2, as a level.
    wire [7:0] irr_m = {irr[0][7:3], ps[3], irr[0][1:0]};
    wire [3:0] pm = pending(irr_m & ~imr[0], isr[0]);

    assign irq = pm[3];
    wire [2:0] sn = ps[3] ? ps[2:0] : 3'd7;
    assign vec = !pm[3] ? {base[0][7:3], 3'd7} :             // spurious
                 (pm[2:0] == 3'd2) ? {base[1][7:3], sn} :
                 {base[0][7:3], pm[2:0]};

    wire       w   = cs_s;                  // which controller
    wire       sel = cs_m || cs_s;
    assign rdata = a0 ? imr[w] : rdisr[w] ? isr[w] : irr[w];

    integer k;
    always @(posedge clk) begin
        // Requests, edge-triggered.
        irr[0] <= irr[0] | req[7:0];
        irr[1] <= irr[1] | req[15:8];

        if (inta && pm[3]) begin
            isr[0] <= isr[0] | (8'd1 << pm[2:0]);
            if (pm[2:0] == 3'd2) begin
                isr[1] <= isr[1] | (8'd1 << sn);
                irr[1] <= (irr[1] | req[15:8]) & ~(8'd1 << sn);
            end else
                irr[0] <= (irr[0] | req[7:0]) & ~(8'd1 << pm[2:0]);
        end

        if (sel && wr) begin
            if (!a0) begin
                if (wdata[4]) begin                     // ICW1
                    step[w] <= 2'd1;
                    icw4[w] <= wdata[0];
                    imr[w] <= 8'd0; isr[w] <= 8'd0; irr[w] <= 8'd0;
                    rdisr[w] <= 1'b0;
                end else if (wdata[4:3] == 2'b01) begin // OCW3
                    if (wdata[1])
                        rdisr[w] <= wdata[0];
                end else if (wdata[5]) begin            // OCW2: end of interrupt
                    if (wdata[6])
                        isr[w] <= isr[w] & ~(8'd1 << wdata[2:0]);
                    else
                        isr[w] <= isr[w] & ~lowest(isr[w]);
                end
            end else begin
                case (step[w])
                    2'd1: begin base[w] <= {wdata[7:3], 3'd0}; step[w] <= 2'd2; end
                    2'd2: step[w] <= icw4[w] ? 2'd3 : 2'd0;
                    2'd3: step[w] <= 2'd0;
                    default: imr[w] <= wdata;
                endcase
            end
        end

        if (rst) begin
            for (k = 0; k < 2; k = k + 1) begin
                irr[k] <= 8'd0; imr[k] <= 8'd0; isr[k] <= 8'd0;
                step[k] <= 2'd0; icw4[k] <= 1'b0; rdisr[k] <= 1'b0;
            end
            base[0] <= 8'h08;
            base[1] <= 8'h70;
        end
    end
endmodule
