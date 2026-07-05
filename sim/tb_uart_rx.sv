`timescale 1ns / 1ps

module tb_uart_rx;

    localparam int  CLK_HZ = 50_000_000;
    localparam int  BAUD   = 115_200;
    localparam real BIT_NS = 1.0e9 / BAUD;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;
    logic       rx = 1'b1;
    logic [7:0] data;
    logic       valid;
    logic       frame_err;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (.*);

    always #10 clk = ~clk;

    int         n_valid = 0;
    int         n_frame_err = 0;
    int         errors = 0;
    int         v, f;
    logic [7:0] last_byte;

    always @(posedge clk) begin
        if (valid) begin
            n_valid++;
            last_byte = data;
        end
        if (frame_err) n_frame_err++;
    end

    task automatic send_byte(input logic [7:0] b, input real bit_ns, input logic stop_bit);
        rx = 1'b0;
        #(bit_ns);
        for (int i = 0; i < 8; i++) begin
            rx = b[i];
            #(bit_ns);
        end
        rx = stop_bit;
        #(bit_ns);
        rx = 1'b1;
        #(bit_ns);
    endtask

    task automatic check_byte(input logic [7:0] b, input real bit_ns);
        int n_before = n_valid;
        send_byte(b, bit_ns, 1'b1);
        if (n_valid != n_before + 1 || last_byte !== b) begin
            $display("FAIL: sent %02h at %0.1f ns/bit, got %0d strobes, last %02h",
                     b, bit_ns, n_valid - n_before, last_byte);
            errors++;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        for (int b = 0; b < 256; b++) check_byte(8'(b), BIT_NS);

        check_byte(8'h55, BIT_NS * 1.025);
        check_byte(8'hAA, BIT_NS * 1.025);
        check_byte(8'hA5, BIT_NS * 1.025);
        check_byte(8'h55, BIT_NS / 1.025);
        check_byte(8'hAA, BIT_NS / 1.025);
        check_byte(8'h5A, BIT_NS / 1.025);

        begin
            v = n_valid;
            f = n_frame_err;
            send_byte(8'h3C, BIT_NS, 1'b0);
            #(BIT_NS * 2);
            if (n_frame_err != f + 1 || n_valid != v) begin
                $display("FAIL: framing error not flagged (ferr %0d, valid %0d)", n_frame_err - f, n_valid - v);
                errors++;
            end
            check_byte(8'hC3, BIT_NS);
        end

        begin
            v = n_valid;
            f = n_frame_err;
            rx = 1'b0;
            #(BIT_NS / 4);
            rx = 1'b1;
            #(BIT_NS * 12);
            if (n_valid != v || n_frame_err != f) begin
                $display("FAIL: start-bit glitch produced output");
                errors++;
            end
            check_byte(8'h81, BIT_NS);
        end

        if (errors == 0) $display("PASS tb_uart_rx (%0d bytes received)", n_valid);
        else             $display("FAIL tb_uart_rx: %0d errors", errors);
        $finish;
    end

endmodule
