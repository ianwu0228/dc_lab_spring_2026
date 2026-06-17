module button_debouncer #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer DEBOUNCE_MS = 10
) (
    input  wire clk,
    input  wire rst_n,
    input  wire noisy,
    output reg  clean
);

    localparam integer DEBOUNCE_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer COUNTER_WIDTH = 20;

    reg sync_0;
    reg sync_1;
    reg candidate;
    reg [COUNTER_WIDTH-1:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_0 <= 1'b0;
            sync_1 <= 1'b0;
            candidate <= 1'b0;
            counter <= {COUNTER_WIDTH{1'b0}};
            clean <= 1'b0;
        end else begin
            sync_0 <= noisy;
            sync_1 <= sync_0;

            if (sync_1 == clean) begin
                candidate <= sync_1;
                counter <= {COUNTER_WIDTH{1'b0}};
            end else if (sync_1 != candidate) begin
                candidate <= sync_1;
                counter <= {COUNTER_WIDTH{1'b0}};
            end else if (counter >= DEBOUNCE_CYCLES - 1) begin
                clean <= candidate;
                counter <= {COUNTER_WIDTH{1'b0}};
            end else begin
                counter <= counter + 1'b1;
            end
        end
    end

endmodule
