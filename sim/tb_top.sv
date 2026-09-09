`timescale 1ns / 1ps
`include "vectors.svh"

// End-to-end test against vectors from host/gen_vectors.py.
module tb_top;

    localparam real BIT_NS = 1.0e9 / 115_200;

    logic       clk = 1'b0;
    logic [1:0] KEY = 2'b10;
    logic [9:0] SW = '0;
    logic       rx = 1'b1;
    wire  [9:0] LEDR;
    wire  [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;

    de10_lite_top #(
        .TIMEOUT_MS  (20),
        .ACTIVITY_MS (1),
        .LINK_MS     (1000)
    ) dut (
        .MAX10_CLK1_50 (clk),
        .KEY           (KEY),
        .SW            (SW),
        .GPIO_UART_RX  (rx),
        .LEDR          (LEDR),
        .HEX0 (HEX0), .HEX1 (HEX1), .HEX2 (HEX2),
        .HEX3 (HEX3), .HEX4 (HEX4), .HEX5 (HEX5)
    );

    always #10 clk = ~clk;

    logic [7:0]  stream [0:`N_BYTES-1];
    logic [79:0] trades [0:`N_TRADES-1];

    int errors = 0;
    int trade_idx = 0;
    int n_csum = 0;
    int n_gap = 0;

    always @(posedge clk) begin
        n_csum += dut.err_checksum;
        n_gap  += dut.err_seq_gap;
        if (dut.trade_valid) begin
            if (trade_idx >= `N_TRADES) begin
                $display("FAIL: unexpected extra trade");
                errors++;
            end else if ({dut.trade_symbol, 7'b0, dut.trade_side, dut.trade_price, dut.trade_qty}
                         !== trades[trade_idx]) begin
                $display("FAIL: trade %0d got sym=%0d side=%0d price=%0d qty=%0d expected %h", trade_idx,
                         dut.trade_symbol, dut.trade_side, dut.trade_price, dut.trade_qty, trades[trade_idx]);
                errors++;
            end
            trade_idx++;
        end
    end

    task automatic send_byte(input logic [7:0] b);
        rx = 1'b0;
        #(BIT_NS);
        for (int i = 0; i < 8; i++) begin
            rx = b[i];
            #(BIT_NS);
        end
        rx = 1'b1;
        #(BIT_NS);
    endtask

    wire [47:0] hex_all = {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0};

    function automatic int seg_to_digit(input logic [6:0] seg);
        case (seg)
            7'b1000000: return 0;
            7'b1111001: return 1;
            7'b0100100: return 2;
            7'b0110000: return 3;
            7'b0011001: return 4;
            7'b0010010: return 5;
            7'b0000010: return 6;
            7'b1111000: return 7;
            7'b0000000: return 8;
            7'b0010000: return 9;
            7'b1111111: return 0;  // blank
            default:    return -1000000000;
        endcase
    endfunction

    function automatic longint display_value();
        longint value = 0;
        for (int i = 5; i >= 0; i--) value = value * 10 + seg_to_digit(hex_all[8*i +: 7]);
        return value;
    endfunction

    task automatic expect_display(input string name, input logic [9:0] switches, input longint expected,
                                  input int dp_hex);
        SW = switches;
        repeat (200) @(posedge clk);
        if (display_value() != expected) begin
            $display("FAIL %s: display shows %0d, expected %0d", name, display_value(), expected);
            errors++;
        end
        for (int i = 0; i < 6; i++) begin
            if (hex_all[8*i + 7] !== (i == dp_hex ? 1'b0 : 1'b1)) begin
                $display("FAIL %s: decimal point on HEX%0d wrong", name, i);
                errors++;
            end
        end
    endtask

    longint last_price [0:3];
    longint last_qty   [0:3];
    int     counts     [0:3];

    initial begin
        $readmemh(`STREAM_HEX, stream);
        $readmemh(`TRADES_HEX, trades);
        for (int s = 0; s < 4; s++) begin
            last_price[s] = 0;
            last_qty[s]   = 0;
            counts[s]     = 0;
        end
        for (int t = 0; t < `N_TRADES; t++) begin
            last_price[trades[t][79:72]] = trades[t][63:32];
            last_qty[trades[t][79:72]]   = trades[t][31:0];
            counts[trades[t][79:72]]++;
        end

        repeat (10) @(posedge clk);
        KEY[0] = 1'b1;
        repeat (10) @(posedge clk);

        for (int i = 0; i < `N_BYTES; i++) send_byte(stream[i]);
        repeat (1000) @(posedge clk);

        if (trade_idx != `N_TRADES) begin
            $display("FAIL: decoded %0d trades, expected %0d", trade_idx, `N_TRADES);
            errors++;
        end
        if (n_csum != `N_CHECKSUM_ERRORS || n_gap != `N_SEQ_GAPS) begin
            $display("FAIL: checksum errors %0d/%0d, seq gaps %0d/%0d",
                     n_csum, `N_CHECKSUM_ERRORS, n_gap, `N_SEQ_GAPS);
            errors++;
        end

        for (int s = 0; s < 4; s++) begin
            expect_display("price dollars", {2'b00, 5'b0, 1'b0, 2'(s)}, (last_price[s] / 100) % 1000000, -1);
            expect_display("price cents",   {2'b00, 5'b0, 1'b1, 2'(s)}, last_price[s] % 1000000, 2);
            expect_display("quantity",      {2'b01, 5'b0, 1'b0, 2'(s)}, (last_qty[s] / 100) % 1000000, 4);
            expect_display("trade count",   {2'b10, 5'b0, 1'b0, 2'(s)}, counts[s], -1);
        end
        expect_display("error count", {2'b11, 8'b0}, `N_ERRORS, -1);

        if (LEDR[4] !== 1'b1)                         begin $display("FAIL: link LED off"); errors++; end
        if (LEDR[8] !== (`N_CHECKSUM_ERRORS > 0))     begin $display("FAIL: checksum LED"); errors++; end
        if (LEDR[7] !== (`N_SEQ_GAPS > 0))            begin $display("FAIL: seq gap LED"); errors++; end

        KEY[1] = 1'b0;
        repeat (10) @(posedge clk);
        KEY[1] = 1'b1;
        expect_display("error count after clear", {2'b11, 8'b0}, 0, -1);
        if (LEDR[9:7] !== 3'b000) begin $display("FAIL: sticky LEDs not cleared"); errors++; end

        if (errors == 0) $display("PASS tb_top (%0d bytes, %0d trades)", `N_BYTES, trade_idx);
        else             $display("FAIL tb_top: %0d errors", errors);
        $finish;
    end

endmodule
