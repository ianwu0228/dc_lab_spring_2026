module unsigned_divider #(
    parameter NUM_WIDTH = 48,
    parameter DEN_WIDTH = 32
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [NUM_WIDTH-1:0] numerator,
    input  wire [DEN_WIDTH-1:0] denominator,
    output reg                  busy,
    output reg                  done,
    output reg  [NUM_WIDTH-1:0] quotient
);

    reg [NUM_WIDTH-1:0] dividend;
    reg [DEN_WIDTH-1:0] divisor;
    reg [DEN_WIDTH:0]   remainder;
    reg [5:0]           bit_index;

    wire [DEN_WIDTH:0] shifted_remainder =
        {remainder[DEN_WIDTH-1:0], dividend[bit_index]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dividend <= {NUM_WIDTH{1'b0}};
            divisor   <= {DEN_WIDTH{1'b0}};
            remainder <= {(DEN_WIDTH + 1){1'b0}};
            quotient  <= {NUM_WIDTH{1'b0}};
            bit_index <= 6'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                dividend <= numerator;
                divisor   <= denominator;
                remainder <= {(DEN_WIDTH + 1){1'b0}};
                quotient  <= {NUM_WIDTH{1'b0}};
                bit_index <= NUM_WIDTH - 1;
                busy      <= 1'b1;
            end else if (busy) begin
                if (divisor == {DEN_WIDTH{1'b0}}) begin
                    quotient <= {NUM_WIDTH{1'b1}};
                    remainder <= {(DEN_WIDTH + 1){1'b0}};
                end else if (shifted_remainder >= {1'b0, divisor}) begin
                    remainder <= shifted_remainder - {1'b0, divisor};
                    quotient[bit_index] <= 1'b1;
                end else begin
                    remainder <= shifted_remainder;
                end

                if (bit_index == 0) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    bit_index <= bit_index - 1'b1;
                end
            end
        end
    end

endmodule
