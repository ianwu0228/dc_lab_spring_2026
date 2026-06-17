module h2_lut_classifier_3sensor #(
    parameter integer LUT_ENTRIES = 45,
    parameter integer KEY_COUNT = 5,
    parameter integer SCORE_WIDTH = 72,
    parameter integer DIFF_SHIFT = 16,
    parameter         LUT_FILE = "h2_lut_3sensor.mem"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    input  wire [31:0] h2_s1_q16,
    input  wire [31:0] h2_s2_q16,
    input  wire [31:0] h2_s3_q16,

    output reg         busy,
    output reg         valid,
    output reg  [2:0]  key_id,
    output reg  [SCORE_WIDTH-1:0] score
);

    localparam [3:0]
        S_IDLE                 = 4'd0,
        S_LOAD_ENTRY           = 4'd1,
        S_SET_LIVE_PRODUCT     = 4'd2,
        S_CAPTURE_LIVE_PRODUCT = 4'd3,
        S_CAPTURE_LUT_PRODUCT  = 4'd4,
        S_CAPTURE_SQUARE       = 4'd5,
        S_UPDATE_KEY_SCORE     = 4'd6,
        S_NEXT_ENTRY           = 4'd7,
        S_FIND_INIT            = 4'd8,
        S_FIND_NEXT            = 4'd9,
        S_DONE                 = 4'd10;

    localparam [SCORE_WIDTH-1:0] MAX_SCORE = {SCORE_WIDTH{1'b1}};

    reg [159:0] lut_rom [0:LUT_ENTRIES-1];

    initial begin
        $readmemh(LUT_FILE, lut_rom);
    end

    reg [3:0] state;
    reg [7:0] entry_index;
    reg [2:0] sensor_index;
    reg [2:0] find_index;

    reg [31:0] live_s1;
    reg [31:0] live_s2;
    reg [31:0] live_s3;
    reg [31:0] live_total;

    reg [3:0]  entry_key;
    reg [31:0] lut_s1;
    reg [31:0] lut_s2;
    reg [31:0] lut_s3;
    reg [31:0] lut_total;

    reg [31:0] mul_a;
    reg [31:0] mul_b;
    wire [63:0] mul_result = mul_a * mul_b;

    reg [63:0] product_live;
    reg [SCORE_WIDTH-1:0] entry_score;
    reg [SCORE_WIDTH-1:0] key_best [0:KEY_COUNT-1];
    reg [SCORE_WIDTH-1:0] best_score;
    reg [2:0] best_key;

    wire [159:0] current_lut_word = lut_rom[entry_index];

    integer i;

    function automatic [31:0] live_value;
        input [2:0] index;
        begin
            case (index)
                3'd0: live_value = live_s1;
                3'd1: live_value = live_s2;
                default: live_value = live_s3;
            endcase
        end
    endfunction

    function automatic [31:0] lut_value;
        input [2:0] index;
        begin
            case (index)
                3'd0: lut_value = lut_s1;
                3'd1: lut_value = lut_s2;
                default: lut_value = lut_s3;
            endcase
        end
    endfunction

    function automatic [31:0] scaled_abs_diff;
        input [63:0] left_product;
        input [63:0] right_product;
        reg signed [64:0] raw_diff;
        reg signed [64:0] scaled_diff;
        begin
            raw_diff = $signed({1'b0, left_product}) -
                       $signed({1'b0, right_product});
            scaled_diff = raw_diff >>> DIFF_SHIFT;

            if (scaled_diff < 0)
                scaled_diff = -scaled_diff;

            if (|scaled_diff[64:32])
                scaled_abs_diff = 32'hFFFFFFFF;
            else
                scaled_abs_diff = scaled_diff[31:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            entry_index <= 8'd0;
            sensor_index <= 3'd0;
            find_index <= 3'd0;
            live_s1 <= 32'd0;
            live_s2 <= 32'd0;
            live_s3 <= 32'd0;
            live_total <= 32'd0;
            entry_key <= 4'd0;
            lut_s1 <= 32'd0;
            lut_s2 <= 32'd0;
            lut_s3 <= 32'd0;
            lut_total <= 32'd0;
            mul_a <= 32'd0;
            mul_b <= 32'd0;
            product_live <= 64'd0;
            entry_score <= {SCORE_WIDTH{1'b0}};
            best_score <= MAX_SCORE;
            best_key <= 3'd0;
            busy <= 1'b0;
            valid <= 1'b0;
            key_id <= 3'd0;
            score <= {SCORE_WIDTH{1'b0}};
            for (i = 0; i < KEY_COUNT; i = i + 1)
                key_best[i] <= MAX_SCORE;
        end else begin
            valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        live_s1 <= h2_s1_q16;
                        live_s2 <= h2_s2_q16;
                        live_s3 <= h2_s3_q16;
                        live_total <= h2_s1_q16 + h2_s2_q16 + h2_s3_q16;
                        entry_index <= 8'd0;
                        busy <= 1'b1;
                        for (i = 0; i < KEY_COUNT; i = i + 1)
                            key_best[i] <= MAX_SCORE;
                        state <= S_LOAD_ENTRY;
                    end
                end

                S_LOAD_ENTRY: begin
                    entry_key <= current_lut_word[159:156];
                    lut_s1 <= current_lut_word[127:96];
                    lut_s2 <= current_lut_word[95:64];
                    lut_s3 <= current_lut_word[63:32];
                    lut_total <= current_lut_word[31:0];
                    sensor_index <= 3'd0;
                    entry_score <= {SCORE_WIDTH{1'b0}};
                    state <= S_SET_LIVE_PRODUCT;
                end

                S_SET_LIVE_PRODUCT: begin
                    mul_a <= live_value(sensor_index);
                    mul_b <= lut_total;
                    state <= S_CAPTURE_LIVE_PRODUCT;
                end

                S_CAPTURE_LIVE_PRODUCT: begin
                    product_live <= mul_result;
                    mul_a <= lut_value(sensor_index);
                    mul_b <= live_total;
                    state <= S_CAPTURE_LUT_PRODUCT;
                end

                S_CAPTURE_LUT_PRODUCT: begin
                    mul_a <= scaled_abs_diff(product_live, mul_result);
                    mul_b <= scaled_abs_diff(product_live, mul_result);
                    state <= S_CAPTURE_SQUARE;
                end

                S_CAPTURE_SQUARE: begin
                    entry_score <= entry_score +
                        {{(SCORE_WIDTH-64){1'b0}}, mul_result};

                    if (sensor_index == 3'd2) begin
                        state <= S_UPDATE_KEY_SCORE;
                    end else begin
                        sensor_index <= sensor_index + 1'b1;
                        state <= S_SET_LIVE_PRODUCT;
                    end
                end

                S_UPDATE_KEY_SCORE: begin
                    if (entry_key < KEY_COUNT) begin
                        if (entry_score < key_best[entry_key])
                            key_best[entry_key] <= entry_score;
                    end
                    state <= S_NEXT_ENTRY;
                end

                S_NEXT_ENTRY: begin
                    if (entry_index == LUT_ENTRIES - 1) begin
                        state <= S_FIND_INIT;
                    end else begin
                        entry_index <= entry_index + 1'b1;
                        state <= S_LOAD_ENTRY;
                    end
                end

                S_FIND_INIT: begin
                    best_score <= key_best[0];
                    best_key <= 3'd0;
                    find_index <= 3'd1;
                    state <= S_FIND_NEXT;
                end

                S_FIND_NEXT: begin
                    if (find_index < KEY_COUNT) begin
                        if (key_best[find_index] < best_score) begin
                            best_score <= key_best[find_index];
                            best_key <= find_index[2:0];
                        end
                        find_index <= find_index + 1'b1;
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    key_id <= best_key;
                    score <= best_score;
                    valid <= 1'b1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
