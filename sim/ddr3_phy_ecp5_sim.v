/*
 * Mach86 -- simulation only: a module with the name and ports of
 * Zeitlos's ECP5 DDR3 PHY (rtl/ext/zeitlos/ddr3_phy_ecp5.v) around
 * Zeitlos's behavioural PHY (ddr3_phy_sim.v), so that the real
 * rtl/ext/zeitlos/ddr3.v -- controller and registers -- can be
 * simulated against the DRAM model without the FPGA's I/O cells.
 *
 * The tuning inputs do nothing here: the behavioural PHY always reads
 * correctly. Training itself cannot be simulated this way.
 */
`timescale 1ps/1ps
module ddr3_phy_ecp5 (
    input  wire         clk_i,
    input  wire         eclk_i,
    input  wire         rst_i,
    input  wire         ddrdel_i,
    input  wire         pause_i,
    input  wire         phy_rst_i,
    input  wire         ctl_reset_n_i,
    input  wire         ctl_cke_i,
    input  wire         ctl_odt_i,
    input  wire         ctl_cs_n_i,
    input  wire         ctl_ras_n_i,
    input  wire         ctl_cas_n_i,
    input  wire         ctl_we_n_i,
    input  wire [15:0]  ctl_a_i,
    input  wire [2:0]   ctl_ba_i,
    input  wire         ctl_wren_i,
    input  wire [127:0] ctl_wdata_i,
    input  wire [15:0]  ctl_wmask_i,
    input  wire         ctl_rden_i,
    output wire         ctl_rvalid_o,
    output wire [127:0] ctl_rdata_o,
    input  wire [2:0]   cfg_wr_delay_i,
    input  wire [2:0]   cfg_rd_gate0_i,
    input  wire [2:0]   cfg_rd_gate1_i,
    input  wire [2:0]   cfg_rdclksel0_i,
    input  wire [2:0]   cfg_rdclksel1_i,
    input  wire [3:0]   cfg_rd_off0_i,
    input  wire [3:0]   cfg_rd_off1_i,
    output wire [1:0]   sts_datavalid_o,
    output reg  [1:0]   sts_burstdet_o,
    input  wire         sts_clear_i,
    output wire [15:0]  ddr3_a,
    output wire [2:0]   ddr3_ba,
    output wire         ddr3_ras_n,
    output wire         ddr3_cas_n,
    output wire         ddr3_we_n,
    output wire         ddr3_cs_n,
    output wire         ddr3_cke,
    output wire         ddr3_odt,
    output wire         ddr3_reset_n,
    output wire [1:0]   ddr3_dm,
    inout  wire [15:0]  ddr3_dq,
    inout  wire [1:0]   ddr3_dqs_p,
    output wire         ddr3_clk_p
);
    assign ddr3_clk_p = eclk_i;
    assign sts_datavalid_o = 2'b11;
    initial sts_burstdet_o = 2'b11;

    ddr3_phy_sim #(.TCK_PS(10417), .CL(6), .CWL(6)) phy (
        .clk_i(clk_i), .ck_i(eclk_i), .rst_i(rst_i),
        .ctl_reset_n_i(ctl_reset_n_i), .ctl_cke_i(ctl_cke_i),
        .ctl_odt_i(ctl_odt_i), .ctl_cs_n_i(ctl_cs_n_i),
        .ctl_ras_n_i(ctl_ras_n_i), .ctl_cas_n_i(ctl_cas_n_i),
        .ctl_we_n_i(ctl_we_n_i), .ctl_a_i(ctl_a_i), .ctl_ba_i(ctl_ba_i),
        .ctl_wren_i(ctl_wren_i), .ctl_wdata_i(ctl_wdata_i),
        .ctl_wmask_i(ctl_wmask_i), .ctl_rden_i(ctl_rden_i),
        .ctl_rvalid_o(ctl_rvalid_o), .ctl_rdata_o(ctl_rdata_o),
        .ddr_reset_n(ddr3_reset_n), .ddr_cke(ddr3_cke), .ddr_odt(ddr3_odt),
        .ddr_cs_n(ddr3_cs_n), .ddr_ras_n(ddr3_ras_n), .ddr_cas_n(ddr3_cas_n),
        .ddr_we_n(ddr3_we_n), .ddr_a(ddr3_a), .ddr_ba(ddr3_ba),
        .ddr_dm(ddr3_dm), .ddr_dq(ddr3_dq), .ddr_dqs(ddr3_dqs_p));
endmodule
