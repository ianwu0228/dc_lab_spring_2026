module mag_calibrator (
    input  wire signed [15:0] raw_x,
    input  wire signed [15:0] raw_y,
    input  wire signed [15:0] raw_z,

    input  wire signed [15:0] offset_x,
    input  wire signed [15:0] offset_y,
    input  wire signed [15:0] offset_z,
    input  wire        [31:0] scale_x_q16,
    input  wire        [31:0] scale_y_q16,
    input  wire        [31:0] scale_z_q16,

    output wire signed [15:0] corrected_x,
    output wire signed [15:0] corrected_y,
    output wire signed [15:0] corrected_z,
    output wire signed [31:0] corrected_x_gauss_q16,
    output wire signed [31:0] corrected_y_gauss_q16,
    output wire signed [31:0] corrected_z_gauss_q16
);

    // Apply offset and Q16.16 scale correction, then clamp to signed 16-bit.
    function automatic signed [15:0] correct_axis;
        input signed [15:0] raw_value;
        input signed [15:0] offset_value;
        input        [31:0] scale_value_q16;
        reg signed [16:0] delta;
        reg signed [49:0] scaled_value;
        reg signed [49:0] corrected_value;
        begin
            delta = {raw_value[15], raw_value} -
                    {offset_value[15], offset_value};
            scaled_value = delta * $signed({1'b0, scale_value_q16});
            corrected_value = scaled_value >>> 16;

            if (corrected_value > 50'sd32767)
                correct_axis = 16'sh7FFF;
            else if (corrected_value < -50'sd32768)
                correct_axis = 16'sh8000;
            else
                correct_axis = corrected_value[15:0];
        end
    endfunction

    // QMC5883P +-2 G range: 15000 raw counts per Gauss.
    // 286_331 / 2^16 approximates 2^16 / 15000.
    function automatic signed [31:0] count_to_gauss_q16;
        input signed [15:0] count_value;
        reg signed [47:0] scaled_value;
        begin
            scaled_value = count_value * 32'sd286_331;
            count_to_gauss_q16 = scaled_value >>> 16;
        end
    endfunction

    assign corrected_x = correct_axis(raw_x, offset_x, scale_x_q16);
    assign corrected_y = correct_axis(raw_y, offset_y, scale_y_q16);
    assign corrected_z = correct_axis(raw_z, offset_z, scale_z_q16);

    assign corrected_x_gauss_q16 = count_to_gauss_q16(corrected_x);
    assign corrected_y_gauss_q16 = count_to_gauss_q16(corrected_y);
    assign corrected_z_gauss_q16 = count_to_gauss_q16(corrected_z);

endmodule
