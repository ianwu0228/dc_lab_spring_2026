module h2_lut_classifier_3sensor #(
    parameter integer LUT_ENTRIES = 45,
    parameter integer KEY_COUNT = 5,
    parameter integer SCORE_WIDTH = 72,
    parameter integer RATIO_FRAC_BITS = 30,
    parameter integer LOG_FRAC_BITS = 16,
    parameter integer STRENGTH_WEIGHT_NUM = 3277,
    parameter integer STRENGTH_WEIGHT_SHIFT = 16,
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
        S_IDLE              = 4'd0,
        S_START_DIV         = 4'd1,
        S_WAIT_DIV          = 4'd2,
        S_PREPARE_LOG       = 4'd3,
        S_LOAD_ENTRY        = 4'd4,
        S_SET_COMPONENT     = 4'd5,
        S_CAPTURE_COMPONENT = 4'd6,
        S_UPDATE_KEY_SCORE  = 4'd7,
        S_NEXT_ENTRY        = 4'd8,
        S_FIND_INIT         = 4'd9,
        S_FIND_NEXT         = 4'd10,
        S_DONE              = 4'd11;

    localparam [31:0] LN2_Q16 = 32'd45426;
    localparam [SCORE_WIDTH-1:0] MAX_SCORE = {SCORE_WIDTH{1'b1}};

    reg [159:0] lut_rom [0:LUT_ENTRIES-1];

    initial begin
        $readmemh(LUT_FILE, lut_rom);
    end

    reg [3:0] state;
    reg [7:0] entry_index;
    reg [1:0] ratio_index;
    reg [1:0] component_index;
    reg [2:0] find_index;

    reg [31:0] live_s1;
    reg [31:0] live_s2;
    reg [31:0] live_s3;
    reg [31:0] live_total;
    reg [31:0] live_f1_q30;
    reg [31:0] live_f2_q30;
    reg [31:0] live_f3_q30;
    reg [31:0] live_ln_total_q16;

    reg [3:0]  entry_key;
    reg [31:0] lut_f1_q30;
    reg [31:0] lut_f2_q30;
    reg [31:0] lut_f3_q30;
    reg [31:0] lut_ln_total_q16;
    reg [SCORE_WIDTH-1:0] entry_score;
    reg [SCORE_WIDTH-1:0] key_best [0:KEY_COUNT-1];
    reg [SCORE_WIDTH-1:0] best_score;
    reg [2:0] best_key;

    reg        divider_start;
    reg [63:0] divider_numerator;
    wire       divider_busy;
    wire       divider_done;
    wire [63:0] divider_quotient;

    reg [31:0] square_operand;
    wire [63:0] square_result = {32'd0, square_operand} * {32'd0, square_operand};

    wire [159:0] current_lut_word = lut_rom[entry_index];

    integer i;

    unsigned_divider #(
        .NUM_WIDTH (64),
        .DEN_WIDTH (32)
    ) u_ratio_divider (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (divider_start),
        .numerator   (divider_numerator),
        .denominator (live_total),
        .busy        (divider_busy),
        .done        (divider_done),
        .quotient    (divider_quotient)
    );

    function automatic [63:0] ratio_numerator;
        input [31:0] value;
        begin
            ratio_numerator = {32'd0, value} << RATIO_FRAC_BITS;
        end
    endfunction

    function automatic [31:0] clamp_ratio_q30;
        input [63:0] quotient;
        begin
            if (|quotient[63:32])
                clamp_ratio_q30 = 32'hFFFFFFFF;
            else
                clamp_ratio_q30 = quotient[31:0];
        end
    endfunction

    function automatic [31:0] abs_diff32;
        input [31:0] a;
        input [31:0] b;
        begin
            abs_diff32 = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    function automatic [5:0] floor_log2_32;
        input [31:0] value;
        integer bit_index;
        begin
            floor_log2_32 = 6'd0;
            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1) begin
                if (value[bit_index])
                    floor_log2_32 = bit_index;
            end
        end
    endfunction

    function automatic [31:0] ln_mantissa_q16;
        input [3:0] index;
        begin
            case (index)
                4'd0:  ln_mantissa_q16 = 32'd0;
                4'd1:  ln_mantissa_q16 = 32'd3973;
                4'd2:  ln_mantissa_q16 = 32'd7688;
                4'd3:  ln_mantissa_q16 = 32'd11262;
                4'd4:  ln_mantissa_q16 = 32'd14624;
                4'd5:  ln_mantissa_q16 = 32'd17821;
                4'd6:  ln_mantissa_q16 = 32'd20870;
                4'd7:  ln_mantissa_q16 = 32'd23783;
                4'd8:  ln_mantissa_q16 = 32'd26572;
                4'd9:  ln_mantissa_q16 = 32'd29248;
                4'd10: ln_mantissa_q16 = 32'd31818;
                4'd11: ln_mantissa_q16 = 32'd34292;
                4'd12: ln_mantissa_q16 = 32'd36675;
                4'd13: ln_mantissa_q16 = 32'd38974;
                4'd14: ln_mantissa_q16 = 32'd41197;
                default: ln_mantissa_q16 = 32'd43346;
            endcase
        end
    endfunction

    function automatic [31:0] ln_total_q16;
        input [31:0] value;
        reg [5:0] exponent;
        reg [31:0] normalized;
        begin
            if (value == 32'd0) begin
                ln_total_q16 = 32'd0;
            end else begin
                exponent = floor_log2_32(value);
                normalized = value << (6'd31 - exponent);
                ln_total_q16 = (exponent * LN2_Q16) +
                               ln_mantissa_q16(normalized[30:27]);
            end
        end
    endfunction

    function automatic [SCORE_WIDTH-1:0] extend64;
        input [63:0] value;
        begin
            extend64 = {{(SCORE_WIDTH-64){1'b0}}, value};
        end
    endfunction

    function automatic [SCORE_WIDTH-1:0] weighted_strength_score;
        input [63:0] strength_score_q30;
        reg [SCORE_WIDTH+15:0] weighted_strength;
        begin
            weighted_strength = extend64(strength_score_q30) * STRENGTH_WEIGHT_NUM;
            weighted_strength_score = weighted_strength >> STRENGTH_WEIGHT_SHIFT;
        end
    endfunction

    function automatic [31:0] live_ratio_for_component;
        input [1:0] index;
        begin
            case (index)
                2'd0: live_ratio_for_component = live_f1_q30;
                2'd1: live_ratio_for_component = live_f2_q30;
                2'd2: live_ratio_for_component = live_f3_q30;
                default: live_ratio_for_component = live_ln_total_q16;
            endcase
        end
    endfunction

    function automatic [31:0] lut_ratio_for_component;
        input [1:0] index;
        begin
            case (index)
                2'd0: lut_ratio_for_component = lut_f1_q30;
                2'd1: lut_ratio_for_component = lut_f2_q30;
                2'd2: lut_ratio_for_component = lut_f3_q30;
                default: lut_ratio_for_component = lut_ln_total_q16;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            entry_index <= 8'd0;
            ratio_index <= 2'd0;
            component_index <= 2'd0;
            find_index <= 3'd0;
            live_s1 <= 32'd0;
            live_s2 <= 32'd0;
            live_s3 <= 32'd0;
            live_total <= 32'd0;
            live_f1_q30 <= 32'd0;
            live_f2_q30 <= 32'd0;
            live_f3_q30 <= 32'd0;
            live_ln_total_q16 <= 32'd0;
            entry_key <= 4'd0;
            lut_f1_q30 <= 32'd0;
            lut_f2_q30 <= 32'd0;
            lut_f3_q30 <= 32'd0;
            lut_ln_total_q16 <= 32'd0;
            entry_score <= {SCORE_WIDTH{1'b0}};
            best_score <= MAX_SCORE;
            best_key <= 3'd0;
            divider_start <= 1'b0;
            divider_numerator <= 64'd0;
            square_operand <= 32'd0;
            busy <= 1'b0;
            valid <= 1'b0;
            key_id <= 3'd0;
            score <= {SCORE_WIDTH{1'b0}};
            for (i = 0; i < KEY_COUNT; i = i + 1)
                key_best[i] <= MAX_SCORE;
        end else begin
            valid <= 1'b0;
            divider_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        live_s1 <= h2_s1_q16;
                        live_s2 <= h2_s2_q16;
                        live_s3 <= h2_s3_q16;
                        live_total <= h2_s1_q16 + h2_s2_q16 + h2_s3_q16;
                        live_f1_q30 <= 32'd0;
                        live_f2_q30 <= 32'd0;
                        live_f3_q30 <= 32'd0;
                        live_ln_total_q16 <= 32'd0;
                        entry_index <= 8'd0;
                        ratio_index <= 2'd0;
                        busy <= 1'b1;
                        for (i = 0; i < KEY_COUNT; i = i + 1)
                            key_best[i] <= MAX_SCORE;
                        state <= S_START_DIV;
                    end
                end

                S_START_DIV: begin
                    if (live_total == 32'd0) begin
                        live_f1_q30 <= 32'd0;
                        live_f2_q30 <= 32'd0;
                        live_f3_q30 <= 32'd0;
                        state <= S_PREPARE_LOG;
                    end else begin
                        case (ratio_index)
                            2'd0: divider_numerator <= ratio_numerator(live_s1);
                            2'd1: divider_numerator <= ratio_numerator(live_s2);
                            default: divider_numerator <= ratio_numerator(live_s3);
                        endcase
                        divider_start <= 1'b1;
                        state <= S_WAIT_DIV;
                    end
                end

                S_WAIT_DIV: begin
                    if (divider_done) begin
                        case (ratio_index)
                            2'd0: live_f1_q30 <= clamp_ratio_q30(divider_quotient);
                            2'd1: live_f2_q30 <= clamp_ratio_q30(divider_quotient);
                            default: live_f3_q30 <= clamp_ratio_q30(divider_quotient);
                        endcase

                        if (ratio_index == 2'd2) begin
                            state <= S_PREPARE_LOG;
                        end else begin
                            ratio_index <= ratio_index + 1'b1;
                            state <= S_START_DIV;
                        end
                    end
                end

                S_PREPARE_LOG: begin
                    live_ln_total_q16 <= ln_total_q16(live_total);
                    state <= S_LOAD_ENTRY;
                end

                S_LOAD_ENTRY: begin
                    entry_key <= current_lut_word[159:156];
                    lut_f1_q30 <= current_lut_word[127:96];
                    lut_f2_q30 <= current_lut_word[95:64];
                    lut_f3_q30 <= current_lut_word[63:32];
                    lut_ln_total_q16 <= current_lut_word[31:0];
                    component_index <= 2'd0;
                    entry_score <= {SCORE_WIDTH{1'b0}};
                    state <= S_SET_COMPONENT;
                end

                S_SET_COMPONENT: begin
                    square_operand <= abs_diff32(
                        live_ratio_for_component(component_index),
                        lut_ratio_for_component(component_index)
                    );
                    state <= S_CAPTURE_COMPONENT;
                end

                S_CAPTURE_COMPONENT: begin
                    if (component_index == 2'd3) begin
                        entry_score <= entry_score +
                            weighted_strength_score(
                                square_result >> (2 * LOG_FRAC_BITS - RATIO_FRAC_BITS)
                            );
                        state <= S_UPDATE_KEY_SCORE;
                    end else begin
                        entry_score <= entry_score +
                            extend64(square_result >> RATIO_FRAC_BITS);
                        component_index <= component_index + 1'b1;
                        state <= S_SET_COMPONENT;
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
                    busy <= 1'b0;
                end
            endcase
        end
    end

endmodule
