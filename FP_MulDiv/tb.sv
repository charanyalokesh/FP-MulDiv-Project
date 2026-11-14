
`timescale 1ns/1ps

module tb_fp_muldiv;

    logic clk;
    logic reset;
    logic in_valid;
    logic div;
    logic [31:0] a, b;
    logic out_valid;
    logic [31:0] result;

    integer failed_tests = 0;

    fp_muldiv dut (
        .clk(clk),
        .reset(reset),
        .in_valid(in_valid),
        .div(div),
        .a(a),
        .b(b),
        .out_valid(out_valid),
        .result(result)
    );

    always #5 clk = ~clk;

    task automatic run_test(
        input logic operation,
        input logic [31:0] operand_a,
        input logic [31:0] operand_b,
        input logic [31:0] expected,
        input integer test_number
    );
        integer cycles;
        begin
            @(negedge clk);

            div = operation;
            a = operand_a;
            b = operand_b;
            in_valid = 1'b1;

            @(posedge clk);
            #1;
            in_valid = 1'b0;

            cycles = 0;

            while (!out_valid && cycles < 64) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end

            if (!out_valid) begin
                failed_tests = failed_tests + 1;
                $display("TEST %0d FAILED: Timeout", test_number);
            end
            else if (result === expected) begin
                $display(
                    "TEST %0d PASSED: Result = %h",
                    test_number, result
                );
            end
            else begin
                failed_tests = failed_tests + 1;
                $display(
                    "TEST %0d FAILED: Expected = %h, Got = %h",
                    test_number, expected, result
                );
            end

            @(negedge clk);
        end
    endtask

    initial begin
        clk = 0;
        reset = 1;
        in_valid = 0;
        div = 0;
        a = 0;
        b = 0;

        repeat (2) @(posedge clk);
        reset = 0;

        // Multiplication tests
        run_test(0, 32'h3F800000, 32'h40000000, 32'h40000000, 1);
        run_test(0, 32'h40400000, 32'h40000000, 32'h40C00000, 2);

        // Division tests
        run_test(1, 32'h40C00000, 32'h40000000, 32'h40400000, 3);
        run_test(1, 32'h40800000, 32'h40000000, 32'h40000000, 4);

        // Special-case multiplication tests
        run_test(0, 32'h00000000, 32'h3F800000, 32'h00000000, 5);
        run_test(0, 32'h80000000, 32'h40000000, 32'h80000000, 6);
        run_test(0, 32'h7F800000, 32'h00000000, 32'h7FC00000, 7);
        run_test(0, 32'h7F800000, 32'h3F800000, 32'h7F800000, 8);

        // Special-case division tests
        run_test(1, 32'h3F800000, 32'h00000000, 32'h7F800000, 9);
        run_test(1, 32'h00000000, 32'h00000000, 32'h7FC00000, 10);
        run_test(1, 32'h7F800000, 32'h7F800000, 32'h7FC00000, 11);
        run_test(1, 32'h3F800000, 32'h7F800000, 32'h00000000, 12);

        // Subnormal and rounding tests
        run_test(0, 32'h00000001, 32'h3F800000, 32'h00000001, 13);
        run_test(0, 32'h00800000, 32'h3F000000, 32'h00400000, 14);
        run_test(1, 32'h00000001, 32'h40000000, 32'h00000000, 15);

        // Non-exact division: 1.0 / 3.0
        run_test(1, 32'h3F800000, 32'h40400000, 32'h3EAAAAAB, 16);

        // Overflow: maximum finite value * 2.0
        run_test(0, 32'h7F7FFFFF, 32'h40000000, 32'h7F800000, 17);

        // Underflow: smallest subnormal * 0.5
        run_test(0, 32'h00000001, 32'h3F000000, 32'h00000000, 18);

        $display("--------------------------------");
        $display("Total tests: 18");
        $display("Failed tests: %0d", failed_tests);

        if (failed_tests != 0)
            $fatal(1, "%0d tests failed", failed_tests);
        else
            $display("ALL TESTS PASSED");

        $finish;
    end

endmodule
