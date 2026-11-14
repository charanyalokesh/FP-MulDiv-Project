
module fp_muldiv (
    input  logic        clk,
    input  logic        reset,
    input  logic        in_valid,
    input  logic        div,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        out_valid,
    output logic [31:0] result
);

    localparam logic [31:0] CANONICAL_NAN = 32'h7FC00000;

    function automatic logic [63:0] round_rne(
        input logic [63:0] value,
        input integer shift,
        input logic extra_sticky
    );
        logic [63:0] q;
        logic guard_bit, sticky_bit;
        logic [63:0] mask;
        begin
            q = 0;
            guard_bit = 0;
            sticky_bit = extra_sticky;
            mask = 0;

            if (shift <= 0)
                q = value << (-shift);
            else if (shift > 64)
                q = 0;
            else begin
                q = value >> shift;
                guard_bit = value[shift-1];

                if (shift > 1) begin
                    mask = (64'h1 << (shift-1)) - 1;
                    sticky_bit = sticky_bit | (|(value & mask));
                end

                if (guard_bit && (sticky_bit || q[0]))
                    q = q + 1;
            end

            round_rne = q;
        end
    endfunction

    function automatic logic [31:0] pack_float(
        input logic sign_bit,
        input logic [63:0] magnitude,
        input integer k,
        input logic extra_sticky
    );
        integer msb;
        integer i;
        integer exponent_value;
        integer shift_amount;

        logic [63:0] rounded;
        logic [23:0] significand;
        logic [7:0] exponent_field;

        begin
            pack_float = {sign_bit, 31'b0};

            if (magnitude != 0) begin
                msb = 0;

                for (i = 0; i < 64; i = i + 1)
                    if (magnitude[i])
                        msb = i;

                exponent_value = msb + k;

                if (exponent_value >= -126) begin
                    shift_amount = msb - 23;

                    rounded = round_rne(
                        magnitude, shift_amount, extra_sticky
                    );

                    if (rounded >= 64'h1000000) begin
                        rounded = rounded >> 1;
                        exponent_value = exponent_value + 1;
                    end

                    if (exponent_value > 127)
                        pack_float = {sign_bit, 8'hFF, 23'b0};
                    else begin
                        significand = rounded[23:0];
                        exponent_field = exponent_value + 127;

                        pack_float = {
                            sign_bit,
                            exponent_field,
                            significand[22:0]
                        };
                    end
                end
                else begin
                    shift_amount = -(k + 149);

                    rounded = round_rne(
                        magnitude, shift_amount, extra_sticky
                    );

                    if (rounded >= 64'h800000)
                        pack_float = {sign_bit, 8'h01, 23'b0};
                    else
                        pack_float = {
                            sign_bit,
                            8'b0,
                            rounded[22:0]
                        };
                end
            end
        end
    endfunction

    function automatic logic [31:0] fp_multiply(
        input logic [31:0] x,
        input logic [31:0] y
    );
        logic sx, sy;
        logic [7:0] ex, ey;
        logic [22:0] fx, fy;
        logic [23:0] mx, my;
        logic [47:0] product;

        integer ax, ay;
        integer scale;

        begin
            sx = x[31];
            sy = y[31];
            ex = x[30:23];
            ey = y[30:23];
            fx = x[22:0];
            fy = y[22:0];

            if ((ex == 255 && fx != 0) ||
                (ey == 255 && fy != 0))
                fp_multiply = CANONICAL_NAN;

            else if ((ex == 255 && ey == 0 && fy == 0) ||
                     (ey == 255 && ex == 0 && fx == 0))
                fp_multiply = CANONICAL_NAN;

            else if (ex == 255 || ey == 255)
                fp_multiply = {sx ^ sy, 8'hFF, 23'b0};

            else if ((ex == 0 && fx == 0) ||
                     (ey == 0 && fy == 0))
                fp_multiply = {sx ^ sy, 31'b0};

            else begin
                mx = (ex == 0) ? {1'b0, fx} : {1'b1, fx};
                my = (ey == 0) ? {1'b0, fy} : {1'b1, fy};

                ax = (ex == 0) ? -126 : ex - 127;
                ay = (ey == 0) ? -126 : ey - 127;

                product = mx * my;
                scale = ax + ay - 46;

                fp_multiply = pack_float(
                    sx ^ sy,
                    {16'b0, product},
                    scale,
                    1'b0
                );
            end
        end
    endfunction

    function automatic logic [31:0] fp_divide(
        input logic [31:0] x,
        input logic [31:0] y
    );
        logic sx, sy;
        logic [7:0] ex, ey;
        logic [22:0] fx, fy;

        logic [23:0] mx, my;
        logic [63:0] numerator;
        logic [63:0] quotient;
        logic [63:0] remainder_value;

        integer ax, ay;
        integer scale;
        integer i;

        begin
            sx = x[31];
            sy = y[31];
            ex = x[30:23];
            ey = y[30:23];
            fx = x[22:0];
            fy = y[22:0];

            if ((ex == 255 && fx != 0) ||
                (ey == 255 && fy != 0))
                fp_divide = CANONICAL_NAN;

            else if ((ex == 255 && ey == 255) ||
                     ((ex == 0 && fx == 0) &&
                      (ey == 0 && fy == 0)))
                fp_divide = CANONICAL_NAN;

            else if (ey == 0 && fy == 0)
                fp_divide = {sx ^ sy, 8'hFF, 23'b0};

            else if (ex == 255)
                fp_divide = {sx ^ sy, 8'hFF, 23'b0};

            else if (ey == 255)
                fp_divide = {sx ^ sy, 31'b0};

            else if (ex == 0 && fx == 0)
                fp_divide = {sx ^ sy, 31'b0};

            else begin
                mx = (ex == 0) ? {1'b0, fx} : {1'b1, fx};
                my = (ey == 0) ? {1'b0, fy} : {1'b1, fy};

                ax = (ex == 0) ? -126 : ex - 127;
                ay = (ey == 0) ? -126 : ey - 127;

                for (i = 0; i < 24; i = i + 1) begin
                    if (!mx[23]) begin
                        mx = mx << 1;
                        ax = ax - 1;
                    end

                    if (!my[23]) begin
                        my = my << 1;
                        ay = ay - 1;
                    end
                end

                numerator = {mx, 40'b0};

                quotient = numerator / my;
                remainder_value = numerator % my;

                scale = ax - ay - 40;

                fp_divide = pack_float(
                    sx ^ sy,
                    quotient,
                    scale,
                    (remainder_value != 0)
                );
            end
        end
    endfunction

    logic [31:0] mul_result;
    logic [31:0] div_result;

    always_comb begin
        mul_result = fp_multiply(a, b);
        div_result = fp_divide(a, b);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            result <= 32'b0;
            out_valid <= 1'b0;
        end
        else begin
            out_valid <= 1'b0;

            if (in_valid) begin
                if (div)
                    result <= div_result;
                else
                    result <= mul_result;

                out_valid <= 1'b1;
            end
        end
    end

endmodule
