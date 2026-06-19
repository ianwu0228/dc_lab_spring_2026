module platform_tracker_controller #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer INITIAL_CENTER_KEY = 12,
    parameter integer MIN_CENTER_KEY = 2,
    parameter integer MAX_CENTER_KEY = 12,
    parameter integer LOCAL_CENTER_KEY_ID = 2,
    parameter integer STABLE_COUNT = 3,
    parameter integer COOLDOWN_MS = 100,
    parameter integer MIN_TOTAL_Q16 = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,

    input  wire       key75_valid,
    input  wire [2:0] key75_id,
    input  wire [31:0] h75_total_q16,

    input  wire       key45_valid,
    input  wire [2:0] key45_id,
    input  wire [31:0] h45_total_q16,

    input  wire       right_dir_level,
    input  wire       stepper_busy,
    input  wire       stepper_done_pulse,

    output reg        move_pulse,
    output reg        dir_cmd,
    output reg [4:0]  platform_center_key,
    output reg signed [4:0] local75_index,
    output reg signed [4:0] local45_index,
    output reg signed [5:0] center_sum,
    output reg signed [1:0] move_request,
    output reg [2:0]  stable_count,
    output reg [2:0]  debug_block_reason
);

    localparam integer COOLDOWN_CYCLES = (CLK_HZ / 1000) * COOLDOWN_MS;
    localparam [31:0] COOLDOWN_CYCLES_VALUE = COOLDOWN_CYCLES;
    localparam [4:0] INITIAL_CENTER_KEY_VALUE = INITIAL_CENTER_KEY;
    localparam [4:0] MIN_CENTER_KEY_VALUE = MIN_CENTER_KEY;
    localparam [4:0] MAX_CENTER_KEY_VALUE = MAX_CENTER_KEY;
    localparam signed [4:0] LOCAL_CENTER_KEY_ID_VALUE = LOCAL_CENTER_KEY_ID;

    localparam [2:0]
        BLOCK_NONE        = 3'd0,
        BLOCK_DISABLED    = 3'd1,
        BLOCK_WEAK_SIGNAL = 3'd2,
        BLOCK_ORDER       = 3'd3,
        BLOCK_CENTERED    = 3'd4,
        BLOCK_LEFT_LIMIT  = 3'd5,
        BLOCK_RIGHT_LIMIT = 3'd6,
        BLOCK_BUSY        = 3'd7;

    reg [2:0] key75_latched;
    reg [2:0] key45_latched;
    reg       key75_fresh;
    reg       key45_fresh;
    reg [31:0] h75_total_latched;
    reg [31:0] h45_total_latched;
    reg signed [1:0] last_move_request;
    reg [31:0] cooldown_counter;

    wire signed [4:0] candidate_local75 =
        $signed({2'b00, key75_latched}) - LOCAL_CENTER_KEY_ID_VALUE;
    wire signed [4:0] candidate_local45 =
        $signed({2'b00, key45_latched}) - LOCAL_CENTER_KEY_ID_VALUE;
    wire signed [5:0] candidate_center_sum =
        candidate_local75 + candidate_local45;
    wire candidate_order_ok = candidate_local75 <= candidate_local45;
    wire candidate_signal_ok =
        (h75_total_latched >= MIN_TOTAL_Q16) &&
        (h45_total_latched >= MIN_TOTAL_Q16);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key75_latched <= 3'd0;
            key45_latched <= 3'd0;
            key75_fresh <= 1'b0;
            key45_fresh <= 1'b0;
            h75_total_latched <= 32'd0;
            h45_total_latched <= 32'd0;
            last_move_request <= 2'sd0;
            cooldown_counter <= 32'd0;
            move_pulse <= 1'b0;
            dir_cmd <= 1'b0;
            platform_center_key <= INITIAL_CENTER_KEY_VALUE;
            local75_index <= 5'sd0;
            local45_index <= 5'sd0;
            center_sum <= 6'sd0;
            move_request <= 2'sd0;
            stable_count <= 3'd0;
            debug_block_reason <= BLOCK_DISABLED;
        end else begin
            move_pulse <= 1'b0;

            if (key75_valid) begin
                key75_latched <= key75_id;
                h75_total_latched <= h75_total_q16;
                key75_fresh <= 1'b1;
            end

            if (key45_valid) begin
                key45_latched <= key45_id;
                h45_total_latched <= h45_total_q16;
                key45_fresh <= 1'b1;
            end

            if (stepper_done_pulse) begin
                cooldown_counter <= COOLDOWN_CYCLES_VALUE;
            end else if (cooldown_counter != 32'd0) begin
                cooldown_counter <= cooldown_counter - 1'b1;
            end

            if (!enable) begin
                key75_fresh <= 1'b0;
                key45_fresh <= 1'b0;
                stable_count <= 3'd0;
                last_move_request <= 2'sd0;
                move_request <= 2'sd0;
                debug_block_reason <= BLOCK_DISABLED;
            end else if (stepper_busy || cooldown_counter != 32'd0) begin
                stable_count <= 3'd0;
                last_move_request <= 2'sd0;
                move_request <= 2'sd0;
                debug_block_reason <= BLOCK_BUSY;
            end else if (key75_fresh && key45_fresh) begin
                key75_fresh <= 1'b0;
                key45_fresh <= 1'b0;
                local75_index <= candidate_local75;
                local45_index <= candidate_local45;
                center_sum <= candidate_center_sum;

                if (!candidate_signal_ok) begin
                    stable_count <= 3'd0;
                    last_move_request <= 2'sd0;
                    move_request <= 2'sd0;
                    debug_block_reason <= BLOCK_WEAK_SIGNAL;
                end else if (!candidate_order_ok) begin
                    stable_count <= 3'd0;
                    last_move_request <= 2'sd0;
                    move_request <= 2'sd0;
                    debug_block_reason <= BLOCK_ORDER;
                end else if (candidate_center_sum <= -6'sd2) begin
                    move_request <= -2'sd1;

                    if (platform_center_key <= MIN_CENTER_KEY_VALUE) begin
                        stable_count <= 3'd0;
                        last_move_request <= 2'sd0;
                        debug_block_reason <= BLOCK_LEFT_LIMIT;
                    end else begin
                        debug_block_reason <= BLOCK_NONE;
                        if (last_move_request == -2'sd1)
                            stable_count <= stable_count + 1'b1;
                        else
                            stable_count <= 3'd1;
                        last_move_request <= -2'sd1;

                        if ((last_move_request == -2'sd1 &&
                             stable_count >= STABLE_COUNT - 1) ||
                            (STABLE_COUNT <= 1)) begin
                            dir_cmd <= ~right_dir_level;
                            move_pulse <= 1'b1;
                            platform_center_key <= platform_center_key - 1'b1;
                            stable_count <= 3'd0;
                            last_move_request <= 2'sd0;
                        end
                    end
                end else if (candidate_center_sum >= 6'sd2) begin
                    move_request <= 2'sd1;

                    if (platform_center_key >= MAX_CENTER_KEY_VALUE) begin
                        stable_count <= 3'd0;
                        last_move_request <= 2'sd0;
                        debug_block_reason <= BLOCK_RIGHT_LIMIT;
                    end else begin
                        debug_block_reason <= BLOCK_NONE;
                        if (last_move_request == 2'sd1)
                            stable_count <= stable_count + 1'b1;
                        else
                            stable_count <= 3'd1;
                        last_move_request <= 2'sd1;

                        if ((last_move_request == 2'sd1 &&
                             stable_count >= STABLE_COUNT - 1) ||
                            (STABLE_COUNT <= 1)) begin
                            dir_cmd <= right_dir_level;
                            move_pulse <= 1'b1;
                            platform_center_key <= platform_center_key + 1'b1;
                            stable_count <= 3'd0;
                            last_move_request <= 2'sd0;
                        end
                    end
                end else begin
                    stable_count <= 3'd0;
                    last_move_request <= 2'sd0;
                    move_request <= 2'sd0;
                    debug_block_reason <= BLOCK_CENTERED;
                end
            end
        end
    end

endmodule
