/*
 * Mach86 SoC -- the sound of a board: the PC speaker and the AdLib
 * added up, as samples for an S/PDIF transmitter (Sergei) and as two
 * one-bit sigma-delta outputs for a resistor and capacitor each
 * (Lakritz). A board uses the outputs it has pins for; the tools
 * remove the rest.
 *
 * aclk must be 48 MHz (m86_spk.v says why); clk is the CPU's clock,
 * on which the AdLib's registers are written. The sigma-delta
 * modulator is Zeitlos's (audio_sd in rtl/ext/zeitlos/audio_out.v),
 * run at aclk: 1,000 times oversampled.
 */
module m86_audio #(
    parameter OPLROM = "opl_rom.hex"
) (
    input  wire        clk,
    input  wire        opl_we,
    input  wire [7:0]  opl_a,
    input  wire [7:0]  opl_d,
    input  wire        spk,             // any clock

    input  wire        aclk,
    input  wire        arst,
    output wire        tick,            // for audio_spdif
    output wire        frame_req,
    output reg  signed [15:0] sample,
    output wire        sd_l,
    output wire        sd_r
);
    wire signed [15:0] s_spk, s_opl;
    m86_spk speaker (
        .aclk(aclk), .arst(arst), .spk(spk),
        .tick(tick), .frame_req(frame_req), .sample(s_spk));
    m86_opl2 #(.ROM(OPLROM)) opl (
        .clk(clk), .we(opl_we), .wa(opl_a), .wd(opl_d),
        .aclk(aclk), .arst(arst), .start(frame_req), .sample(s_opl));

    wire signed [16:0] sum = {s_spk[15], s_spk} + {s_opl[15], s_opl};
    always @(posedge aclk)
        sample <= (sum > 17'sd32767) ? 16'sd32767 :
                  (sum < -17'sd32768) ? -16'sd32768 : sum[15:0];

    audio_sd sdm (.clk(aclk), .rst(arst), .sample(sample), .out(sd_l));
    assign sd_r = sd_l;
endmodule
