module stepper_drv8825_controller #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer STEP_RATE_HZ = 500,
    parameter integer STEP_PULSE_US = 5,
    parameter integer FIXED_MOVE_STEPS = 200
) (
    input  wire clk,
    input  wire rst_n,

    input  wire enable,
    input  wire dir_cmd,
    input  wire continuous_run,
    input  wire move_pulse,

    output reg  drv_step,
    output reg  drv_dir,
    output wire drv_enable_n,
    output reg  busy,
    output reg  done_pulse
);

    localparam integer STEP_PERIOD_CYCLES = CLK_HZ / STEP_RATE_HZ;
    localparam integer STEP_HIGH_CYCLES =
        (CLK_HZ / 1_000_000) * STEP_PULSE_US;

    reg [31:0] period_counter;
    reg [31:0] pulse_counter;
    reg [31:0] remaining_steps;
    reg        step_high;
    reg        finite_move_active;

    assign drv_enable_n = ~enable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drv_step <= 1'b0;
            drv_dir <= 1'b0;
            busy <= 1'b0;
            done_pulse <= 1'b0;
            period_counter <= 32'd0;
            pulse_counter <= 32'd0;
            remaining_steps <= 32'd0;
            step_high <= 1'b0;
            finite_move_active <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            drv_dir <= dir_cmd;

            if (!enable) begin
                drv_step <= 1'b0;
                busy <= 1'b0;
                period_counter <= 32'd0;
                pulse_counter <= 32'd0;
                remaining_steps <= 32'd0;
                step_high <= 1'b0;
                finite_move_active <= 1'b0;
            end else if (!busy) begin
                drv_step <= 1'b0;
                period_counter <= 32'd0;
                pulse_counter <= 32'd0;
                step_high <= 1'b0;

                if (continuous_run) begin
                    busy <= 1'b1;
                    finite_move_active <= 1'b0;
                    remaining_steps <= 32'd0;
                end else if (move_pulse) begin
                    busy <= 1'b1;
                    finite_move_active <= 1'b1;
                    remaining_steps <= FIXED_MOVE_STEPS;
                end
            end else if (!continuous_run && !finite_move_active) begin
                busy <= 1'b0;
                drv_step <= 1'b0;
                period_counter <= 32'd0;
                pulse_counter <= 32'd0;
                step_high <= 1'b0;
            end else if (step_high) begin
                if (pulse_counter == STEP_HIGH_CYCLES - 1) begin
                    drv_step <= 1'b0;
                    step_high <= 1'b0;
                    pulse_counter <= 32'd0;

                    if (finite_move_active) begin
                        if (remaining_steps <= 32'd1) begin
                            busy <= 1'b0;
                            done_pulse <= 1'b1;
                            remaining_steps <= 32'd0;
                            finite_move_active <= 1'b0;
                        end else begin
                            remaining_steps <= remaining_steps - 1'b1;
                        end
                    end
                end else begin
                    pulse_counter <= pulse_counter + 1'b1;
                end
            end else begin
                if (period_counter == STEP_PERIOD_CYCLES - 1) begin
                    drv_step <= 1'b1;
                    step_high <= 1'b1;
                    period_counter <= 32'd0;
                end else begin
                    period_counter <= period_counter + 1'b1;
                end
            end
        end
    end

endmodule
