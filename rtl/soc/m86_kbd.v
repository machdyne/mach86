/*
 * Mach86 SoC -- the keyboard controller (8042), ports 60h and 64h,
 * with port 92h, and a keyboard fed from a serial line.
 *
 * Sources: IBM AT technical reference (the 8042 interface); behaviour
 * as in the reference model, sim/pc.c. What is here: the output
 * buffer and interrupt 1, the command byte, the commands the BIOS and
 * DOS use (20h, 60h, AAh, ABh, ADh, AEh, D0h, D1h, FEh), the
 * keyboard's own reset, identify, LED and rate commands, the A20 gate
 * and the reset request. Not here: the mouse port, translation
 * control, the input buffer full flag (a write is taken at once).
 *
 * key_valid, key: a character received on the serial console. It is
 * turned into the set-1 scancodes of the key presses that type it on
 * a US keyboard: Ctrl or Shift down if needed, the key down, the key
 * up, Shift or Ctrl up. The table is the one the model uses for its
 * test scripts. A character arriving while the queue is short of
 * room for a whole sequence is dropped.
 *
 * sc_valid, sc_data, sc_ready: scancodes from a real keyboard
 * (m86_usbkbd.v), a byte at a time, taken when sc_ready. Both can be
 * used at once; a serial character does not start in the middle of a
 * two-byte scancode only by luck, so do not type on both together.
 */
module m86_kbd #(
    parameter WAIT = 8192           // cycles between bytes offered to the CPU
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       cs60,
    input  wire       cs64,
    input  wire       cs92,
    input  wire       rd,           // one cycle per read
    input  wire       wr,
    input  wire [7:0] wdata,
    output wire [7:0] rdata,
    input  wire       key_valid,
    input  wire [7:0] key,
    input  wire       sc_valid,     // a scancode from a real keyboard
    input  wire [7:0] sc_data,
    output wire       sc_ready,
    output reg        irq1,
    output reg        a20,
    output reg        reset_req     // one cycle: reset the machine
);
    // The queue of bytes on their way to port 60h.
    reg [7:0] queue [0:63];
    reg [5:0] head;
    reg [6:0] count;
    reg [7:0] out;
    reg       obf;
    reg [7:0] cmdbyte;
    reg [7:0] pending;              // a command waiting for its data byte
    reg [15:0] waitc;

    // Up to three bytes of a reply, then up to six of a key, queued a
    // byte a cycle.
    reg [23:0] rsp;
    reg [1:0]  rsp_n;
    reg [2:0]  kstep;               // 0: idle; 1 to 6: the steps of a key
    reg [6:0]  ksc;
    reg        kshift, kctrl;

    function [7:0] scan(input [7:0] ch);    // {shift, scancode}; 0: none
        begin
            case (ch)
                8'h08: scan = {1'b0, 7'h0E};
                8'h09: scan = {1'b0, 7'h0F};
                8'h0D: scan = {1'b0, 7'h1C};
                8'h1B: scan = {1'b0, 7'h01};
                8'h20: scan = {1'b0, 7'h39};
                8'h21: scan = {1'b1, 7'h02};
                8'h22: scan = {1'b1, 7'h28};
                8'h23: scan = {1'b1, 7'h04};
                8'h24: scan = {1'b1, 7'h05};
                8'h25: scan = {1'b1, 7'h06};
                8'h26: scan = {1'b1, 7'h08};
                8'h27: scan = {1'b0, 7'h28};
                8'h28: scan = {1'b1, 7'h0A};
                8'h29: scan = {1'b1, 7'h0B};
                8'h2A: scan = {1'b1, 7'h09};
                8'h2B: scan = {1'b1, 7'h0D};
                8'h2C: scan = {1'b0, 7'h33};
                8'h2D: scan = {1'b0, 7'h0C};
                8'h2E: scan = {1'b0, 7'h34};
                8'h2F: scan = {1'b0, 7'h35};
                8'h30: scan = {1'b0, 7'h0B};
                8'h31: scan = {1'b0, 7'h02};
                8'h32: scan = {1'b0, 7'h03};
                8'h33: scan = {1'b0, 7'h04};
                8'h34: scan = {1'b0, 7'h05};
                8'h35: scan = {1'b0, 7'h06};
                8'h36: scan = {1'b0, 7'h07};
                8'h37: scan = {1'b0, 7'h08};
                8'h38: scan = {1'b0, 7'h09};
                8'h39: scan = {1'b0, 7'h0A};
                8'h3A: scan = {1'b1, 7'h27};
                8'h3B: scan = {1'b0, 7'h27};
                8'h3C: scan = {1'b1, 7'h33};
                8'h3D: scan = {1'b0, 7'h0D};
                8'h3E: scan = {1'b1, 7'h34};
                8'h3F: scan = {1'b1, 7'h35};
                8'h40: scan = {1'b1, 7'h03};
                8'h41: scan = {1'b1, 7'h1E};
                8'h42: scan = {1'b1, 7'h30};
                8'h43: scan = {1'b1, 7'h2E};
                8'h44: scan = {1'b1, 7'h20};
                8'h45: scan = {1'b1, 7'h12};
                8'h46: scan = {1'b1, 7'h21};
                8'h47: scan = {1'b1, 7'h22};
                8'h48: scan = {1'b1, 7'h23};
                8'h49: scan = {1'b1, 7'h17};
                8'h4A: scan = {1'b1, 7'h24};
                8'h4B: scan = {1'b1, 7'h25};
                8'h4C: scan = {1'b1, 7'h26};
                8'h4D: scan = {1'b1, 7'h32};
                8'h4E: scan = {1'b1, 7'h31};
                8'h4F: scan = {1'b1, 7'h18};
                8'h50: scan = {1'b1, 7'h19};
                8'h51: scan = {1'b1, 7'h10};
                8'h52: scan = {1'b1, 7'h13};
                8'h53: scan = {1'b1, 7'h1F};
                8'h54: scan = {1'b1, 7'h14};
                8'h55: scan = {1'b1, 7'h16};
                8'h56: scan = {1'b1, 7'h2F};
                8'h57: scan = {1'b1, 7'h11};
                8'h58: scan = {1'b1, 7'h2D};
                8'h59: scan = {1'b1, 7'h15};
                8'h5A: scan = {1'b1, 7'h2C};
                8'h5B: scan = {1'b0, 7'h1A};
                8'h5C: scan = {1'b0, 7'h2B};
                8'h5D: scan = {1'b0, 7'h1B};
                8'h5E: scan = {1'b1, 7'h07};
                8'h5F: scan = {1'b1, 7'h0C};
                8'h60: scan = {1'b0, 7'h29};
                8'h61: scan = {1'b0, 7'h1E};
                8'h62: scan = {1'b0, 7'h30};
                8'h63: scan = {1'b0, 7'h2E};
                8'h64: scan = {1'b0, 7'h20};
                8'h65: scan = {1'b0, 7'h12};
                8'h66: scan = {1'b0, 7'h21};
                8'h67: scan = {1'b0, 7'h22};
                8'h68: scan = {1'b0, 7'h23};
                8'h69: scan = {1'b0, 7'h17};
                8'h6A: scan = {1'b0, 7'h24};
                8'h6B: scan = {1'b0, 7'h25};
                8'h6C: scan = {1'b0, 7'h26};
                8'h6D: scan = {1'b0, 7'h32};
                8'h6E: scan = {1'b0, 7'h31};
                8'h6F: scan = {1'b0, 7'h18};
                8'h70: scan = {1'b0, 7'h19};
                8'h71: scan = {1'b0, 7'h10};
                8'h72: scan = {1'b0, 7'h13};
                8'h73: scan = {1'b0, 7'h1F};
                8'h74: scan = {1'b0, 7'h14};
                8'h75: scan = {1'b0, 7'h16};
                8'h76: scan = {1'b0, 7'h2F};
                8'h77: scan = {1'b0, 7'h11};
                8'h78: scan = {1'b0, 7'h2D};
                8'h79: scan = {1'b0, 7'h15};
                8'h7A: scan = {1'b0, 7'h2C};
                8'h7B: scan = {1'b1, 7'h1A};
                8'h7C: scan = {1'b1, 7'h2B};
                8'h7D: scan = {1'b1, 7'h1B};
                8'h7E: scan = {1'b1, 7'h29};
                default: scan = 8'h00;
            endcase
        end
    endfunction

    // A control character is Ctrl with its letter; DEL is backspace
    // and line feed is Enter, as terminals send them.
    wire       k_ctrl = (key >= 8'd1 && key <= 8'd26 && key != 8'h08 &&
                         key != 8'h09 && key != 8'h0A && key != 8'h0D);
    wire [7:0] k_ch   = k_ctrl ? key + 8'h60 :
                        (key == 8'h7F) ? 8'h08 :
                        (key == 8'h0A) ? 8'h0D : key;
    wire [7:0] k_scan = scan(k_ch);

    reg        push;
    reg  [7:0] push_d;
    always @(*) begin
        push = 1'b0;
        push_d = rsp[7:0];
        if (rsp_n != 2'd0)
            push = 1'b1;
        else case (kstep)
            3'd1: begin push = kctrl;  push_d = 8'h1D; end
            3'd2: begin push = kshift; push_d = 8'h2A; end
            3'd3: begin push = 1'b1;   push_d = {1'b0, ksc}; end
            3'd4: begin push = 1'b1;   push_d = {1'b1, ksc}; end
            3'd5: begin push = kshift; push_d = 8'hAA; end
            3'd6: begin push = kctrl;  push_d = 8'h9D; end
            default: ;
        endcase
        if (rsp_n == 2'd0 && kstep == 3'd0 && sc_valid) begin
            push = 1'b1;
            push_d = sc_data;
        end
        if (count[6])
            push = 1'b0;            // full: the byte is lost
    end
    assign sc_ready = (rsp_n == 2'd0) && (kstep == 3'd0) && !count[6];

    wire pop = !obf && count != 7'd0 && waitc == 16'd0;

    assign rdata = cs60 ? out :
                   cs64 ? {7'b0001010, obf} :
                          {6'd0, a20, 1'b0};

    task reply1(input [7:0] b0);
        begin rsp <= {16'd0, b0}; rsp_n <= 2'd1; end
    endtask

    always @(posedge clk) begin
        irq1 <= 1'b0;
        reset_req <= 1'b0;
        if (waitc != 16'd0)
            waitc <= waitc - 16'd1;

        // The queue.
        if (push)
            queue[head + count[5:0]] <= push_d;
        if (pop) begin
            out  <= queue[head];
            head <= head + 6'd1;
            obf  <= 1'b1;
            if (cmdbyte[0])
                irq1 <= 1'b1;
        end
        count <= count + {6'd0, push} - {6'd0, pop};

        if (rsp_n != 2'd0) begin
            rsp   <= {8'd0, rsp[23:8]};
            rsp_n <= rsp_n - 2'd1;
        end else if (kstep != 3'd0)
            kstep <= (kstep == 3'd6) ? 3'd0 : kstep + 3'd1;
        else if (key_valid && k_scan[6:0] != 7'd0 && count < 7'd56) begin
            kstep  <= 3'd1;
            ksc    <= k_scan[6:0];
            kshift <= k_scan[7];
            kctrl  <= k_ctrl;
        end

        if (cs60 && rd) begin
            obf   <= 1'b0;
            waitc <= WAIT;
        end

        if (cs60 && wr) begin
            pending <= 8'd0;
            if (pending == 8'h60)
                cmdbyte <= wdata;
            else if (pending == 8'hD1) begin
                a20 <= wdata[1];
                if (!wdata[0])
                    reset_req <= 1'b1;
            end else if (pending == 8'hED || pending == 8'hF3)
                reply1(8'hFA);
            else begin
                // A command to the keyboard itself.
                if (wdata == 8'hFF) begin
                    rsp <= {8'd0, 8'hAA, 8'hFA}; rsp_n <= 2'd2;
                end else if (wdata == 8'hF2) begin
                    rsp <= {8'h41, 8'hAB, 8'hFA}; rsp_n <= 2'd3;
                end else begin
                    reply1(8'hFA);
                    if (wdata == 8'hED || wdata == 8'hF3)
                        pending <= wdata;
                end
            end
        end

        if (cs64 && wr) begin
            case (wdata)
                8'h20: reply1(cmdbyte);
                8'h60, 8'hD1: pending <= wdata;
                8'hAA: reply1(8'h55);
                8'hAB: reply1(8'h00);
                8'hAD: cmdbyte[4] <= 1'b1;
                8'hAE: cmdbyte[4] <= 1'b0;
                8'hD0: reply1({6'b110111, a20, 1'b1});
                8'hFE: reset_req <= 1'b1;
                default: ;
            endcase
        end

        if (cs92 && wr) begin
            a20 <= wdata[1];
            if (wdata[0])
                reset_req <= 1'b1;
        end

        if (rst) begin
            head <= 6'd0; count <= 7'd0; obf <= 1'b0; out <= 8'd0;
            cmdbyte <= 8'h45; pending <= 8'd0; waitc <= 16'd0;
            rsp_n <= 2'd0; kstep <= 3'd0;
            irq1 <= 1'b0; a20 <= 1'b0; reset_req <= 1'b0;
        end
    end
endmodule
