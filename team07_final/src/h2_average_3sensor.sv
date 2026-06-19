module h2_average_3sensor #(
    parameter integer AVERAGE_SAMPLES = 10
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_valid,

    input  wire [31:0] h2_s1_q16,
    input  wire [31:0] h2_s2_q16,
    input  wire [31:0] h2_s3_q16,

    output reg         valid,
    output reg  [31:0] avg_s1_q16,
    output reg  [31:0] avg_s2_q16,
    output reg  [31:0] avg_s3_q16
);

    reg [31:0] window_s1 [0:AVERAGE_SAMPLES-1];
    reg [31:0] window_s2 [0:AVERAGE_SAMPLES-1];
    reg [31:0] window_s3 [0:AVERAGE_SAMPLES-1];

    reg [63:0] sum_s1;
    reg [63:0] sum_s2;
    reg [63:0] sum_s3;
    reg [7:0]  write_index;
    reg [7:0]  sample_count;

    wire window_full = (sample_count == AVERAGE_SAMPLES);
    wire [63:0] removed_s1 = window_full ? {32'd0, window_s1[write_index]} : 64'd0;
    wire [63:0] removed_s2 = window_full ? {32'd0, window_s2[write_index]} : 64'd0;
    wire [63:0] removed_s3 = window_full ? {32'd0, window_s3[write_index]} : 64'd0;
    wire [63:0] next_sum_s1 = sum_s1 + {32'd0, h2_s1_q16} - removed_s1;
    wire [63:0] next_sum_s2 = sum_s2 + {32'd0, h2_s2_q16} - removed_s2;
    wire [63:0] next_sum_s3 = sum_s3 + {32'd0, h2_s3_q16} - removed_s3;
    wire next_sample_fills_window = (sample_count >= AVERAGE_SAMPLES - 1);

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 1'b0;
            avg_s1_q16 <= 32'd0;
            avg_s2_q16 <= 32'd0;
            avg_s3_q16 <= 32'd0;
            sum_s1 <= 64'd0;
            sum_s2 <= 64'd0;
            sum_s3 <= 64'd0;
            write_index <= 8'd0;
            sample_count <= 8'd0;
            for (i = 0; i < AVERAGE_SAMPLES; i = i + 1) begin
                window_s1[i] <= 32'd0;
                window_s2[i] <= 32'd0;
                window_s3[i] <= 32'd0;
            end
        end else begin
            valid <= 1'b0;

            if (sample_valid) begin
                window_s1[write_index] <= h2_s1_q16;
                window_s2[write_index] <= h2_s2_q16;
                window_s3[write_index] <= h2_s3_q16;

                sum_s1 <= next_sum_s1;
                sum_s2 <= next_sum_s2;
                sum_s3 <= next_sum_s3;

                if (write_index == AVERAGE_SAMPLES - 1)
                    write_index <= 8'd0;
                else
                    write_index <= write_index + 1'b1;

                if (!window_full)
                    sample_count <= sample_count + 1'b1;

                if (next_sample_fills_window) begin
                    avg_s1_q16 <= next_sum_s1 / AVERAGE_SAMPLES;
                    avg_s2_q16 <= next_sum_s2 / AVERAGE_SAMPLES;
                    avg_s3_q16 <= next_sum_s3 / AVERAGE_SAMPLES;
                    valid <= 1'b1;
                end
            end
        end
    end

endmodule
