/*
 * Mach86 -- a top for finding out what clock a CPU core alone can run
 * at (make fmax-c). Not a machine: the core's inputs come from a shift
 * register and its outputs are folded into one, so that the FPGA's
 * pins do not limit it and nothing is optimised away. The inputs are
 * registers here, where in the SoC they come out of the data cache's
 * logic: the figure is the core's own, an upper bound for the machine.
 */
module m86_fmax #(
    parameter PH    = 3,
    parameter UCODE = "ucode.hex",
    parameter ATTR  = "attr.hex"
) (
    input  wire clk,
    input  wire rst_n,
    input  wire si,
    output reg  so
);
    reg  [79:0] in;
    reg         rst;
    always @(posedge clk) begin
        in  <= {in[78:0], si};
        rst <= !rst_n;
    end
    wire        d_req, d_wr, e_req, d_io, dma_ack, inta, halted, step_done;
    wire [31:0] d_addr, d_wdata, e_addr, x_rd, dbg_insns;
    wire [1:0]  d_size, e_size;
    wire [7:0]  dma_q, last_exc;
    m86c_core #(.PH(PH), .UCODE(UCODE), .ATTR(ATTR)) cpu (
        .clk(clk), .rst(rst),
        .d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata),
        .d_rdata(in[31:0]), .d_ack(in[32]), .d_st_rdy(in[33]),
        .e_req(e_req), .e_addr(e_addr), .e_size(e_size), .d_io(d_io), .x_rd(x_rd),
        .dma_req(in[34]), .dma_addr(in[58:35]), .dma_ack(dma_ack), .dma_q(dma_q),
        .slow(in[66:59]), .irq(in[67]), .irq_vec(in[75:68]), .inta(inta),
        .halted(halted), .step_done(step_done), .last_exc(last_exc), .dbg_insns(dbg_insns));
    // The outputs, registered and folded.
    reg [181:0] out;
    always @(posedge clk) begin
        out <= {d_req, d_wr, e_req, d_io, dma_ack, inta, halted, step_done, d_addr, d_wdata,
                e_addr, x_rd, dbg_insns[7:0], d_size, e_size, dma_q, last_exc};
        so  <= ^out;
    end
endmodule
