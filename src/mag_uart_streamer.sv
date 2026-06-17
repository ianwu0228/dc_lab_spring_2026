module mag_uart_streamer #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD_RATE = 115_200,
    parameter integer FRAME_HZ = 80
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] h75_s1_q16,
    input  wire [31:0] h75_s2_q16,
    input  wire [31:0] h75_s3_q16,
    input  wire [31:0] h45_s1_q16,
    input  wire [31:0] h45_s2_q16,
    input  wire [31:0] h45_s3_q16,
    input  wire [4:0]  key75_global,
    input  wire [4:0]  key45_global,
    input  wire [1:0]  press_buttons,

    output wire        uart_txd
);

    localparam integer FRAME_PERIOD = CLOCK_HZ / FRAME_HZ;
    localparam [1:0]
        S_WAIT      = 2'd0,
        S_SEND      = 2'd1,
        S_WAIT_DONE = 2'd2;

    // H2 line:
    // "H2,75,XXXXXXXX,XXXXXXXX,XXXXXXXX,45,XXXXXXXX,XXXXXXXX,XXXXXXXX\r\n"
    // KEY line:
    // "KEY,75,xx,p75,45,yy,p45\r\n"
    localparam [6:0] H2_LINE_LENGTH = 7'd64;
    localparam [6:0] KEY_LINE_LENGTH = 7'd21;

    reg [22:0] frame_counter;
    reg [1:0]  state;
    reg [6:0]  char_index;
    reg        tx_start;
    reg [7:0]  tx_data;

    reg [31:0] snap_h75_s1_q16, snap_h75_s2_q16, snap_h75_s3_q16;
    reg [31:0] snap_h45_s1_q16, snap_h45_s2_q16, snap_h45_s3_q16;
    reg [4:0]  snap_key75_global, snap_key45_global;
    reg [1:0]  snap_press_buttons;
    reg        send_key_line;

    wire tx_busy;
    wire tx_done;
    wire frame_counter_done = (frame_counter == FRAME_PERIOD - 1);

    uart_tx #(
        .CLOCK_HZ  (CLOCK_HZ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .start (tx_start),
        .data  (tx_data),
        .txd   (uart_txd),
        .busy  (tx_busy),
        .done  (tx_done)
    );

    function automatic [7:0] hex_to_ascii;
        input [3:0] hex;
        begin
            if (hex < 4'd10)
                hex_to_ascii = "0" + hex;
            else
                hex_to_ascii = "A" + (hex - 4'd10);
        end
    endfunction

    function automatic [31:0] h2_value_for_index;
        input [2:0] value_index;
        begin
            case (value_index)
                3'd0: h2_value_for_index = snap_h75_s1_q16;
                3'd1: h2_value_for_index = snap_h75_s2_q16;
                3'd2: h2_value_for_index = snap_h75_s3_q16;
                3'd3: h2_value_for_index = snap_h45_s1_q16;
                3'd4: h2_value_for_index = snap_h45_s2_q16;
                default: h2_value_for_index = snap_h45_s3_q16;
            endcase
        end
    endfunction

    function automatic [7:0] h2_hex_char;
        input [2:0] value_index;
        input [2:0] nibble_index;
        reg [31:0] value;
        begin
            value = h2_value_for_index(value_index);
            case (nibble_index)
                3'd0: h2_hex_char = hex_to_ascii(value[31:28]);
                3'd1: h2_hex_char = hex_to_ascii(value[27:24]);
                3'd2: h2_hex_char = hex_to_ascii(value[23:20]);
                3'd3: h2_hex_char = hex_to_ascii(value[19:16]);
                3'd4: h2_hex_char = hex_to_ascii(value[15:12]);
                3'd5: h2_hex_char = hex_to_ascii(value[11:8]);
                3'd6: h2_hex_char = hex_to_ascii(value[7:4]);
                default: h2_hex_char = hex_to_ascii(value[3:0]);
            endcase
        end
    endfunction

    function automatic [7:0] h2_line_char;
        input [6:0] index;
        reg [6:0] offset;
        begin
            case (index)
                7'd0:  h2_line_char = "H";
                7'd1:  h2_line_char = "2";
                7'd2:  h2_line_char = ",";
                7'd3:  h2_line_char = "7";
                7'd4:  h2_line_char = "5";
                7'd5:  h2_line_char = ",";
                7'd14: h2_line_char = ",";
                7'd23: h2_line_char = ",";
                7'd32: h2_line_char = ",";
                7'd33: h2_line_char = "4";
                7'd34: h2_line_char = "5";
                7'd35: h2_line_char = ",";
                7'd44: h2_line_char = ",";
                7'd53: h2_line_char = ",";
                7'd62: h2_line_char = 8'h0D;
                7'd63: h2_line_char = 8'h0A;
                default: begin
                    if (index < 7'd14) begin
                        offset = index - 7'd6;
                        h2_line_char = h2_hex_char(3'd0, offset[2:0]);
                    end else if (index < 7'd23) begin
                        offset = index - 7'd15;
                        h2_line_char = h2_hex_char(3'd1, offset[2:0]);
                    end else if (index < 7'd32) begin
                        offset = index - 7'd24;
                        h2_line_char = h2_hex_char(3'd2, offset[2:0]);
                    end else if (index < 7'd44) begin
                        offset = index - 7'd36;
                        h2_line_char = h2_hex_char(3'd3, offset[2:0]);
                    end else if (index < 7'd53) begin
                        offset = index - 7'd45;
                        h2_line_char = h2_hex_char(3'd4, offset[2:0]);
                    end else begin
                        offset = index - 7'd54;
                        h2_line_char = h2_hex_char(3'd5, offset[2:0]);
                    end
                end
            endcase
        end
    endfunction

    function automatic [7:0] decimal_tens_ascii;
        input [4:0] value;
        begin
            decimal_tens_ascii = (value >= 5'd10) ? "1" : "0";
        end
    endfunction

    function automatic [7:0] decimal_ones_ascii;
        input [4:0] value;
        begin
            decimal_ones_ascii = "0" + ((value >= 5'd10) ? (value - 5'd10) : value);
        end
    endfunction

    function automatic [7:0] key_line_char;
        input [6:0] index;
        begin
            case (index)
                7'd0:  key_line_char = "K";
                7'd1:  key_line_char = "E";
                7'd2:  key_line_char = "Y";
                7'd3:  key_line_char = ",";
                7'd4:  key_line_char = "7";
                7'd5:  key_line_char = "5";
                7'd6:  key_line_char = ",";
                7'd7:  key_line_char = decimal_tens_ascii(snap_key75_global);
                7'd8:  key_line_char = decimal_ones_ascii(snap_key75_global);
                7'd9:  key_line_char = ",";
                7'd10: key_line_char = snap_press_buttons[0] ? "1" : "0";
                7'd11: key_line_char = ",";
                7'd12: key_line_char = "4";
                7'd13: key_line_char = "5";
                7'd14: key_line_char = ",";
                7'd15: key_line_char = decimal_tens_ascii(snap_key45_global);
                7'd16: key_line_char = decimal_ones_ascii(snap_key45_global);
                7'd17: key_line_char = ",";
                7'd18: key_line_char = snap_press_buttons[1] ? "1" : "0";
                7'd19: key_line_char = 8'h0D;
                default: key_line_char = 8'h0A;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_counter <= 23'd0;
            state <= S_WAIT;
            char_index <= 7'd0;
            tx_start <= 1'b0;
            tx_data <= 8'd0;
            snap_h75_s1_q16 <= 32'd0;
            snap_h75_s2_q16 <= 32'd0;
            snap_h75_s3_q16 <= 32'd0;
            snap_h45_s1_q16 <= 32'd0;
            snap_h45_s2_q16 <= 32'd0;
            snap_h45_s3_q16 <= 32'd0;
            snap_key75_global <= 5'd0;
            snap_key45_global <= 5'd0;
            snap_press_buttons <= 2'd0;
            send_key_line <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (state)
                S_WAIT: begin
                    if (frame_counter_done) begin
                        frame_counter <= 23'd0;
                        char_index <= 7'd0;
                        snap_h75_s1_q16 <= h75_s1_q16;
                        snap_h75_s2_q16 <= h75_s2_q16;
                        snap_h75_s3_q16 <= h75_s3_q16;
                        snap_h45_s1_q16 <= h45_s1_q16;
                        snap_h45_s2_q16 <= h45_s2_q16;
                        snap_h45_s3_q16 <= h45_s3_q16;
                        snap_key75_global <= key75_global;
                        snap_key45_global <= key45_global;
                        snap_press_buttons <= press_buttons;
                        send_key_line <= ~send_key_line;
                        state <= S_SEND;
                    end else begin
                        frame_counter <= frame_counter + 1'b1;
                    end
                end

                S_SEND: begin
                    if (!tx_busy) begin
                        tx_data <= send_key_line ?
                            key_line_char(char_index) :
                            h2_line_char(char_index);
                        tx_start <= 1'b1;
                        state <= S_WAIT_DONE;
                    end
                end

                S_WAIT_DONE: begin
                    if (tx_done) begin
                        if ((!send_key_line && char_index == H2_LINE_LENGTH - 1'b1) ||
                            (send_key_line && char_index == KEY_LINE_LENGTH - 1'b1)) begin
                            state <= S_WAIT;
                            char_index <= 7'd0;
                        end else begin
                            char_index <= char_index + 1'b1;
                            state <= S_SEND;
                        end
                    end
                end

                default: state <= S_WAIT;
            endcase
        end
    end

endmodule
