/*
 * Mach86 SoC -- a USB mouse, as the HID host reports it, for the CPU.
 *
 * Not a PC's mouse hardware (a serial port or the keyboard
 * controller's second channel): a port of our own, read by our own
 * driver (tests/dos/mouse.asm), which gives programs the interrupt
 * 33h interface they all use. docs/mouse.md has the reasons.
 *
 * The HID host gives a report on its own clock: buttons, and how far
 * the mouse moved since the report before. Here the movement is added
 * up until the driver takes it, and interrupt 12 is raised for every
 * report.
 *
 * Port E3h, read three times: the buttons (bit 0 left, 1 right, 2
 * middle; bit 6: there is more movement than this reading takes, read
 * again; bit 7: a mouse has been seen), then the movement right,
 * then the movement down, each -128 to 127 and taken off what is
 * waiting. Any write starts the three again.
 */
module m86_usbmouse (
    input  wire       clk,
    input  wire       rst,

    input  wire       hid_clk,
    input  wire       ms_report,        // for one cycle of hid_clk
    input  wire [2:0] ms_btn,
    input  wire [7:0] ms_dx,
    input  wire [7:0] ms_dy,

    input  wire       rd,               // a read of the port, for one cycle
    input  wire       wr,
    output reg  [7:0] q,
    output reg        irq
);
    // The report, across the clocks: held, and a toggle.
    reg       rep_t = 1'b0;
    reg [2:0] h_btn;
    reg [7:0] h_dx, h_dy;
    always @(posedge hid_clk)
        if (ms_report) begin
            rep_t <= !rep_t;
            h_btn <= ms_btn; h_dx <= ms_dx; h_dy <= ms_dy;
        end
    reg [2:0] rep_s;
    always @(posedge clk)
        rep_s <= {rep_s[1:0], rep_t};
    wire report = rep_s[2] ^ rep_s[1];

    reg signed [11:0] ax, ay;           // waiting to be taken
    reg [2:0] btn;
    reg       seen;
    reg [1:0] seq;
    reg signed [7:0] tx, ty;            // taken at the first read

    function signed [7:0] clamp(input signed [11:0] v);
        clamp = (v > 12'sd127) ? 8'sd127 : (v < -12'sd128) ? -8'sd128 : v[7:0];
    endfunction
    function signed [11:0] sat(input signed [12:0] v);
        sat = (v > 13'sd2047) ? 12'sd2047 : (v < -13'sd2048) ? -12'sd2048 : v[11:0];
    endfunction

    wire signed [7:0] cx = clamp(ax), cy = clamp(ay);
    // What is waiting after this cycle: less what is taken, more what
    // arrives.
    wire signed [12:0] ax_n = {ax[11], ax} - ((rd && seq == 2'd0) ? {{5{cx[7]}}, cx} : 13'sd0)
                            + (report ? {{5{h_dx[7]}}, h_dx} : 13'sd0);
    wire signed [12:0] ay_n = {ay[11], ay} - ((rd && seq == 2'd0) ? {{5{cy[7]}}, cy} : 13'sd0)
                            + (report ? {{5{h_dy[7]}}, h_dy} : 13'sd0);

    // More is waiting than one reading takes.
    wire more = (ax != {{4{cx[7]}}, cx}) || (ay != {{4{cy[7]}}, cy});

    always @(*)
        q = (seq == 2'd0) ? {seen, more, 3'd0, btn} : (seq == 2'd1) ? tx : ty;

    always @(posedge clk) begin
        irq <= report;
        ax <= sat(ax_n);
        ay <= sat(ay_n);
        if (report) begin
            btn  <= h_btn;
            seen <= 1'b1;
        end
        if (rd) begin
            if (seq == 2'd0) begin
                tx <= cx; ty <= cy;
            end
            seq <= (seq == 2'd2) ? 2'd0 : seq + 2'd1;
        end
        if (wr)
            seq <= 2'd0;
        if (rst) begin
            ax <= 12'sd0; ay <= 12'sd0; btn <= 3'd0; seen <= 1'b0;
            seq <= 2'd0; irq <= 1'b0;
        end
    end
endmodule
