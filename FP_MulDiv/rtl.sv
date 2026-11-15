
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

    // -------------------------------------------------
    // ROUND TO NEAREST, TIES TO EVEN
    // -------------------------------------------------

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

    // -------------------------------------------------
    // IEEE-754 RESULT PACKING
    // -------------------------------------------------

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

    // -------------------------------------------------
    // FLOATING-POINT MULTIPLICATION
    // -------------------------------------------------

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

    // -------------------------------------------------
    // DIVISION SPECIAL CASES
    // -------------------------------------------------

    function automatic logic [31:0] fp_divide_special(
        input logic [31:0] x,
        input logic [31:0] y
    );
        logic sx, sy;
        logic [7:0] ex, ey;
        logic [22:0] fx, fy;

        begin
            sx = x[31];
            sy = y[31];
            ex = x[30:23];
            ey = y[30:23];
            fx = x[22:0];
            fy = y[22:0];

            if ((ex == 255 && fx != 0) ||
                (ey == 255 && fy != 0))
                fp_divide_special = CANONICAL_NAN;

            else if ((ex == 255 && ey == 255) ||
                     ((ex == 0 && fx == 0) &&
                      (ey == 0 && fy == 0)))
                fp_divide_special = CANONICAL_NAN;

            else if (ey == 0 && fy == 0)
                fp_divide_special = {sx ^ sy, 8'hFF, 23'b0};

            else if (ex == 255)
                fp_divide_special = {sx ^ sy, 8'hFF, 23'b0};

            else if (ey == 255)
                fp_divide_special = {sx ^ sy, 31'b0};

            else
                fp_divide_special = {sx ^ sy, 31'b0};
        end
    endfunction

    // -------------------------------------------------
    // DIVIDER SETUP
    // -------------------------------------------------

    logic [23:0] setup_mx, setup_my;
    logic [63:0] setup_dividend;
    logic [23:0] setup_divisor;
    logic [31:0] setup_special_result;

    logic setup_special;
    logic setup_sign;
    integer setup_ax, setup_ay;
    integer setup_scale;
    integer setup_i;

    always_comb begin
        setup_mx = (a[30:23] == 0)
                   ? {1'b0, a[22:0]}
                   : {1'b1, a[22:0]};

        setup_my = (b[30:23] == 0)
                   ? {1'b0, b[22:0]}
                   : {1'b1, b[22:0]};

        setup_ax = (a[30:23] == 0)
                   ? -126 : a[30:23] - 127;

        setup_ay = (b[30:23] == 0)
                   ? -126 : b[30:23] - 127;

        for (setup_i = 0; setup_i < 24; setup_i = setup_i + 1) begin
            if (!setup_mx[23]) begin
                setup_mx = setup_mx << 1;
                setup_ax = setup_ax - 1;
            end

            if (!setup_my[23]) begin
                setup_my = setup_my << 1;
                setup_ay = setup_ay - 1;
            end
        end

        setup_dividend = {setup_mx, 40'b0};
        setup_divisor = setup_my;
        setup_scale = setup_ax - setup_ay - 40;
        setup_sign = a[31] ^ b[31];

        setup_special =
            ((a[30:23] == 255) && (a[22:0] != 0)) ||
            ((b[30:23] == 255) && (b[22:0] != 0)) ||
            ((a[30:23] == 255) && (b[30:23] == 255)) ||
            ((a[30:23] == 0) && (a[22:0] == 0) &&
             (b[30:23] == 0) && (b[22:0] == 0)) ||
            ((b[30:23] == 0) && (b[22:0] == 0)) ||
            (a[30:23] == 255) ||
            (b[30:23] == 255) ||
            ((a[30:23] == 0) && (a[22:0] == 0));

        setup_special_result = fp_divide_special(a, b);
    end

    // -------------------------------------------------
    // ITERATIVE RESTORING DIVIDER
    // -------------------------------------------------

    logic divider_busy;

    logic [63:0] dividend_reg;
    logic [63:0] quotient_reg;
    logic [23:0] divisor_reg;
    logic [24:0] remainder_reg;

    logic [5:0] bit_count;
    logic [31:0] divider_sign;
    integer divider_scale;

    logic [24:0] remainder_shifted;
    logic [24:0] remainder_next;
    logic [63:0] quotient_next;

    always_comb begin
        remainder_shifted = {
            remainder_reg[23:0],
            dividend_reg[bit_count]
        };

        remainder_next = remainder_shifted;
        quotient_next = quotient_reg;

        if (remainder_shifted >= {1'b0, divisor_reg}) begin
            remainder_next =
                remainder_shifted - {1'b0, divisor_reg};

            quotient_next =
                quotient_reg | (64'h1 << bit_count);
        end
    end

    // -------------------------------------------------
    // MAIN SEQUENTIAL CONTROL
    // -------------------------------------------------

    always_ff @(posedge clk) begin
        if (reset) begin
            result <= 32'b0;
            out_valid <= 1'b0;

            divider_busy <= 1'b0;
            dividend_reg <= 64'b0;
            quotient_reg <= 64'b0;
            divisor_reg <= 24'b0;
            remainder_reg <= 25'b0;
            bit_count <= 6'b0;
            divider_sign <= 32'b0;
            divider_scale <= 0;
        end
        else begin
            out_valid <= 1'b0;

            if (divider_busy) begin
                dividend_reg <= dividend_reg;
                quotient_reg <= quotient_next;
                remainder_reg <= remainder_next;

                if (bit_count == 0) begin
                    result <= pack_float(
                        divider_sign[0],
                        quotient_next,
                        divider_scale,
                        (remainder_next != 0)
                    );

                    out_valid <= 1'b1;
                    divider_busy <= 1'b0;
                end
                else begin
                    bit_count <= bit_count - 1'b1;
                end
            end
            else if (in_valid) begin
                if (!div) begin
                    result <= fp_multiply(a, b);
                    out_valid <= 1'b1;
                end
                else if (setup_special) begin
                    result <= setup_special_result;
                    out_valid <= 1'b1;
                end
                else begin
                    dividend_reg <= setup_dividend;
                    divisor_reg <= setup_divisor;

                    quotient_reg <= 64'b0;
                    remainder_reg <= 25'b0;

                    bit_count <= 6'd63;

                    divider_sign <= {31'b0, setup_sign};
                    divider_scale <= setup_scale;

                    divider_busy <= 1'b1;
                end
            end
        end
    end

endmodule
