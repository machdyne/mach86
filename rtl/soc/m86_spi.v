/*
 * Mach86 SoC -- the SPI port for the SD card, ports E1h and E2h
 * (docs/hwmap.md).
 *
 * E1h: writing a byte sends it, most significant bit first, and
 * receives one; reading returns the byte received. E2h: bit 0 selects
 * the card (drives its select line low); a write with bit 2 set also
 * sets the speed from bit 1 (0: at most 400 kHz, for bringing a card
 * up; 1: fast). Reading E2h gives bit 7 while a byte is on its way
 * and bit 0 as written.
 *
 * SPI mode 0: the clock idles low, data changes on its falling edge
 * and is sampled on its rising edge. The card's output goes through
 * two flip-flops and is taken when the clock falls again, by which
 * time those hold the level it had while the clock was high.
 */
module m86_spi #(
    parameter CLK_HZ  = 24000000,
    parameter SLOW_HZ = 375000,
    parameter FAST_HALF = 2         // clock cycles per half period when fast
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       cs_data,      // port E1h
    input  wire       cs_ctrl,      // port E2h
    input  wire       wr,
    input  wire [7:0] wdata,
    output wire [7:0] rdata,
    output reg        sck,
    output reg        mosi,
    input  wire       miso,
    output wire       ss_n
);
    localparam integer SLOW_HALF = CLK_HZ / (2 * SLOW_HZ);

    reg        sel, fast, busy;
    reg [7:0]  sh, rx;
    reg [3:0]  bits;
    reg [15:0] div;
    reg [1:0]  m_sync;

    assign ss_n  = !sel;
    assign rdata = cs_data ? rx : {busy, 6'd0, sel};

    wire [15:0] half = fast ? FAST_HALF - 1 : SLOW_HALF - 1;

    always @(posedge clk) begin
        m_sync <= {m_sync[0], miso};

        if (busy) begin
            if (div != 16'd0)
                div <= div - 16'd1;
            else begin
                div <= half;
                if (!sck)
                    sck <= 1'b1;                    // the card samples
                else begin
                    sck <= 1'b0;
                    sh  <= {sh[6:0], m_sync[1]};    // and we take its bit
                    mosi <= sh[6];
                    bits <= bits - 4'd1;
                    if (bits == 4'd1) begin
                        busy <= 1'b0;
                        rx   <= {sh[6:0], m_sync[1]};
                        mosi <= 1'b1;
                    end
                end
            end
        end else if (cs_data && wr) begin
            sh   <= wdata;
            mosi <= wdata[7];
            bits <= 4'd8;
            div  <= half;
            busy <= 1'b1;
        end

        if (cs_ctrl && wr) begin
            sel <= wdata[0];
            if (wdata[2])
                fast <= wdata[1];
        end

        if (rst) begin
            sel <= 1'b0; fast <= 1'b0; busy <= 1'b0;
            sck <= 1'b0; mosi <= 1'b1; rx <= 8'hFF;
        end
    end
endmodule
