/*
 * Mach86 SoC -- a serial port for the console: 8 data bits, no
 * parity, one stop bit, at a fixed rate.
 *
 * The transmitter has a 16-byte queue; tx_full says there is no room.
 * The receiver gives each byte as a one-cycle pulse; a byte with a
 * bad stop bit is dropped.
 */
module m86_uart #(
    parameter CLK_HZ = 24000000,
    parameter BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       tx_valid,
    input  wire [7:0] tx_data,
    output wire       tx_full,
    output reg        rx_valid,
    output reg  [7:0] rx_data,
    output reg        txd = 1'b1,  // the line idles high from power-on
    input  wire       rxd
);
    localparam integer DIV = CLK_HZ / BAUD;

    // ---- transmit ----
    reg [7:0]  fifo [0:15];
    reg [3:0]  f_head;
    reg [4:0]  f_count;
    reg [15:0] t_div;
    reg [3:0]  t_bits;              // bits left, start and stop included
    reg [8:0]  t_sh;

    assign tx_full = f_count[4];
    wire f_push = tx_valid && !tx_full;
    wire f_pop  = (t_bits == 4'd0) && (f_count != 5'd0);

    always @(posedge clk) begin
        if (f_push)
            fifo[f_head + f_count[3:0]] <= tx_data;
        if (f_pop) begin
            t_sh   <= {fifo[f_head], 1'b0};     // start bit first
            t_bits <= 4'd10;
            t_div  <= DIV - 1;
            f_head <= f_head + 4'd1;
        end
        f_count <= f_count + {4'd0, f_push} - {4'd0, f_pop};

        if (t_bits != 4'd0) begin
            txd <= t_sh[0];
            if (t_div == 16'd0) begin
                t_div  <= DIV - 1;
                t_sh   <= {1'b1, t_sh[8:1]};    // then ones: the stop bit
                t_bits <= t_bits - 4'd1;
            end else
                t_div <= t_div - 16'd1;
        end else
            txd <= 1'b1;

        if (rst) begin
            f_head <= 4'd0; f_count <= 5'd0; t_bits <= 4'd0; txd <= 1'b1;
        end
    end

    // ---- receive ----
    reg [2:0]  r_sync;
    reg [15:0] r_div;
    reg [3:0]  r_bits;
    reg [7:0]  r_sh;
    reg        r_busy;
    wire       r_in = r_sync[2];

    always @(posedge clk) begin
        r_sync   <= {r_sync[1:0], rxd};
        rx_valid <= 1'b0;
        if (!r_busy) begin
            if (!r_in) begin                    // a start bit begins
                r_busy <= 1'b1;
                r_div  <= DIV / 2;              // to the middle of it
                r_bits <= 4'd0;
            end
        end else if (r_div != 16'd0)
            r_div <= r_div - 16'd1;
        else begin
            r_div  <= DIV - 1;
            r_bits <= r_bits + 4'd1;
            if (r_bits == 4'd0) begin
                if (r_in)
                    r_busy <= 1'b0;             // it was noise
            end else if (r_bits <= 4'd8)
                r_sh <= {r_in, r_sh[7:1]};
            else begin
                r_busy <= 1'b0;
                if (r_in) begin
                    rx_valid <= 1'b1;
                    rx_data  <= r_sh;
                end
            end
        end
        if (rst) begin
            r_busy <= 1'b0; rx_valid <= 1'b0; r_sync <= 3'b111;
        end
    end
endmodule
