

module i2c_master (
    input  wire       clk_50m,    // 系統 50 MHz 時鐘
    input  wire       rst_n,      // Active-low Reset

    // 與上層 (qmc5883l_ctrl) 的控制介面
    input  wire [2:0] cmd,        // 操作指令
    input  wire       go,         // 觸發指令執行 — 可為 Pulse 或電平，均可正確捕捉
    input  wire [7:0] tx_data,    // 準備寫入的一個 Byte
    output reg  [7:0] rx_data,    // 讀取回來的一個 Byte
    output reg        done,       // 指令完成旗標 (高電平一個 tick_400k 週期)
    output reg        ack_err,    // 發生 NACK 錯誤

    // 與最外層 (top) 的實體接線
    output reg        i2c_scl,
    output reg        sda_out,
    input  wire       sda_in,
    output reg        sda_dir     // 1: FPGA 輸出 (Drive), 0: FPGA 讀取 (Release/Hi-Z)
);

    // =========================================================================
    // 指令定義 (Commands)
    // =========================================================================
    localparam CMD_IDLE       = 3'd0;
    localparam CMD_START      = 3'd1;
    localparam CMD_WRITE      = 3'd2;
    localparam CMD_READ_ACK   = 3'd3;
    localparam CMD_READ_NACK  = 3'd4;
    localparam CMD_STOP       = 3'd5;

    reg go_latch;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            go_latch <= 1'b0;
        end else begin
            if (go)
                go_latch <= 1'b1;           // 捕捉任何寬度的 go 脈衝
            else if (go_accepted)
                go_latch <= 1'b0;           // FSM 接受後清除
        end
    end

    // go_accepted: 當 FSM 在 IDLE 且 tick_400k 有效時拉高一個週期
    wire go_accepted;

    reg [6:0] div_cnt;
    reg       tick_400k;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt   <= 7'd0;
            tick_400k <= 1'b0;
        end 
        else begin
            if (div_cnt == 7'd124) begin    // 50 MHz / 125 = 400 kHz
                div_cnt   <= 7'd0;
                tick_400k <= 1'b1;
            end 
            else begin
                div_cnt   <= div_cnt + 1'b1;
                tick_400k <= 1'b0;
            end
        end
    end

    // =========================================================================
    // 狀態機 (FSM) 狀態編碼
    // =========================================================================
    localparam  S_IDLE        = 5'd0,

                // START condition
                S_STA1        = 5'd1,   // drive SDA high (ensure idle level)
                S_STA2        = 5'd2,   // SDA → low (while SCL high)
                S_STA3        = 5'd3,   // SCL → low (complete START)

                // WRITE byte
                S_WR_DATA     = 5'd4,   // set SDA to current bit
                S_WR_HOLD     = 5'd19,  // FIX 2: one-tick SDA setup guard
                S_WR_SCL_HI   = 5'd5,   // SCL → high
                S_WR_SCL_LO   = 5'd6,   // SCL → low
                S_WR_NEXT     = 5'd7,   // decrement bit counter or go to ACK

                // ACK check (after WRITE)
                S_ACK_SCL_HI  = 5'd8,   // FIX 1: raise SCL first
                S_ACK_SAMPLE  = 5'd20,  // FIX 1: now sample sda_in, SCL → low

                // READ byte
                S_RD_SCL_HI   = 5'd9,   // SCL → high
                S_RD_SAMPLE   = 5'd10,  // sample SDA, SCL → low
                S_RD_NEXT     = 5'd11,  // decrement bit counter or send M-ACK/NACK
                S_RD_MACK_HI  = 5'd12,  // SCL → high (master ACK/NACK clock)
                S_RD_MACK_LO  = 5'd13,  // SCL → low, latch rx_data

                // STOP condition
                S_STP0        = 5'd21,  // FIX 4: force SCL low before SDA
                S_STP1        = 5'd14,  // SDA → low (while SCL low)
                S_STP2        = 5'd15,  // SCL → high
                S_STP3        = 5'd16,  // SDA → high (STOP complete)

                // Completion
                S_DONE        = 5'd18;  // pulse done, return to IDLE

    // =========================================================================
    // FSM registers
    // =========================================================================
    reg [4:0] state;
    reg [2:0] bit_cnt;
    reg [2:0] saved_cmd;
    reg [7:0] shift_reg;

    // go_accepted combinatorially from FSM
    assign go_accepted = tick_400k && (state == S_IDLE) && go_latch;

    // =========================================================================
    // FSM — runs on every tick_400k
    // =========================================================================
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            i2c_scl  <= 1'b1;
            sda_out  <= 1'b1;
            sda_dir  <= 1'b1;
            ack_err  <= 1'b0;
            rx_data  <= 8'd0;
            bit_cnt  <= 3'd0;
            shift_reg<= 8'd0;
            saved_cmd<= 3'd0;
        end 
        else if (tick_400k) begin

            case (state)
                // ---------------------------------------------------------
                // IDLE — 等待 go_latch
                // ---------------------------------------------------------
                S_IDLE: begin
						 // Do NOT force SCL/SDA high here.
						 // Keep the previous bus condition so repeated START works correctly.
					 
						 if (go_latch) begin
							  saved_cmd <= cmd;
							  shift_reg <= tx_data;
							  ack_err   <= 1'b0;
					 
							  case (cmd)
									CMD_START:
										 state <= S_STA1;
					 
									CMD_WRITE:
										 begin
											  state <= S_WR_DATA;
											  bit_cnt <= 3'd7;
										 end
					 
									CMD_READ_ACK,
									CMD_READ_NACK:
										 begin
											  state   <= S_RD_SCL_HI;
											  bit_cnt <= 3'd7;
											  sda_dir <= 1'b0;
										 end
					 
									CMD_STOP:
										 state <= S_STP0;
					 
									default:
										 state <= S_IDLE;
							  endcase
						 end
					end


                // ---------------------------------------------------------
                // START condition
                //   SCL high → SDA high → SDA low → SCL low
                // ---------------------------------------------------------
                S_STA1: begin
                    sda_dir <= 1'b1;
                    sda_out <= 1'b1;    // 確保 SDA 先為高
                    i2c_scl <= 1'b1;
                    state   <= S_STA2;
                end
                S_STA2: begin
                    sda_out <= 1'b0;    // SDA 下降沿 (SCL 仍高 → 有效 START)
                    state   <= S_STA3;
                end
                S_STA3: begin
                    i2c_scl <= 1'b0;    // SCL 下降沿，完成 START
                    state   <= S_DONE;
                end

                S_WR_DATA: begin
                    sda_dir <= 1'b1;
                    sda_out <= shift_reg[bit_cnt];  // 放上當前 bit
                    state   <= S_WR_HOLD;           // FIX 2: 等一 tick
                end
                S_WR_HOLD: begin
                    // SDA 穩定，SCL 仍低 — 滿足 t_SU;DAT ≥ 250 ns
                    state <= S_WR_SCL_HI;
                end
                S_WR_SCL_HI: begin
                    i2c_scl <= 1'b1;    // SCL 升起，Slave 採樣 SDA
                    state   <= S_WR_SCL_LO;
                end
                S_WR_SCL_LO: begin
                    i2c_scl <= 1'b0;    // SCL 降下
                    state   <= S_WR_NEXT;
                end
                S_WR_NEXT: begin
                    if (bit_cnt == 3'd0) begin
                        sda_dir <= 1'b0;        // 釋放 SDA，等待 Slave ACK
                        state   <= S_ACK_SCL_HI;
                    end else begin
                        bit_cnt <= bit_cnt - 1'b1;
                        state   <= S_WR_DATA;
                    end
                end

                S_ACK_SCL_HI: begin
                    i2c_scl <= 1'b1;            // SCL 升起，等 Slave 保持 ACK
                    state   <= S_ACK_SAMPLE;
                end
                S_ACK_SAMPLE: begin
                    // SCL 已高至少一個 tick，sda_in 必定穩定
                    if (sda_in == 1'b1)
                        ack_err <= 1'b1;        // NACK — Slave 沒有拉低 SDA
                    i2c_scl <= 1'b0;
                    state   <= S_DONE;
                end

                S_RD_SCL_HI: begin
                    i2c_scl <= 1'b1;            // SCL 升起
                    state   <= S_RD_SAMPLE;
                end
                S_RD_SAMPLE: begin
                    shift_reg[bit_cnt] <= sda_in;   // 採樣當前 bit
                    i2c_scl <= 1'b0;                // SCL 降下
                    state   <= S_RD_NEXT;
                end
                S_RD_NEXT: begin
                    if (bit_cnt == 3'd0) begin
                        // 8 bits 讀完，準備送 Master ACK / NACK
                        sda_dir <= 1'b1;
                        sda_out <= (saved_cmd == CMD_READ_ACK) ? 1'b0 : 1'b1;
                        state   <= S_RD_MACK_HI;
                    end else begin
                        bit_cnt <= bit_cnt - 1'b1;
                        state   <= S_RD_SCL_HI;
                    end
                end
                S_RD_MACK_HI: begin
                    i2c_scl <= 1'b1;    // SCL ↑，Slave 採樣 Master ACK/NACK
                    state   <= S_RD_MACK_LO;
                end
                S_RD_MACK_LO: begin
                    i2c_scl <= 1'b0;
                    rx_data <= shift_reg;   // 將 8 bits 交給上層
                    sda_dir <= 1'b0;        // 回到高阻抗
                    state   <= S_DONE;
                end

                S_STP0: begin
                    sda_dir <= 1'b1;
                    i2c_scl <= 1'b0;    // FIX 4: 明確確保 SCL 為低
                    state   <= S_STP1;
                end
                S_STP1: begin
                    sda_out <= 1'b0;    // SDA 先低 (SCL 低，不構成任何條件)
                    state   <= S_STP2;
                end
                S_STP2: begin
                    i2c_scl <= 1'b1;    // SCL 升起
                    state   <= S_STP3;
                end
                S_STP3: begin
                    sda_out <= 1'b1;    // SDA 升起 → 有效 STOP 條件
                    state   <= S_DONE;
                end

                // ---------------------------------------------------------
                // DONE — 觸發 done 旗標一個 tick，返回 IDLE
                // ---------------------------------------------------------
                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // =========================================================================
    // DONE 脈衝產生器 (確保絕對只維持 1 個 50MHz Clock Cycle)
    // =========================================================================
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
        end 
        else begin
            // 當狀態機在 S_DONE 且 tick_400k 觸發的那一「瞬間」，拉高 done
            if (tick_400k && state == S_DONE) begin
                done <= 1'b1;
            end else begin
                done <= 1'b0; // 下一個 50MHz 週期立刻強制歸零
            end
        end
    end

endmodule
