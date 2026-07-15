`timescale 1ns / 1ps

module tb_packet_parser;

    import mdp_pkg::*;

    localparam int TIMEOUT_CLKS = 1000;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic [7:0]  rx_data = '0;
    logic        rx_valid = 1'b0;

    logic        trade_valid;
    logic [15:0] trade_seq;
    logic [7:0]  trade_symbol;
    logic        trade_side;
    logic [31:0] trade_price;
    logic [31:0] trade_qty;
    logic        pkt_ok, err_checksum, err_length, err_seq_gap, err_timeout;

    packet_parser #(.TIMEOUT_CLKS(TIMEOUT_CLKS)) dut (.*);

    always #10 clk = ~clk;

    int n_trade = 0, n_ok = 0, n_csum = 0, n_len = 0, n_gap = 0, n_timeout = 0;
    int errors = 0;

    always @(posedge clk) begin
        n_trade   += trade_valid;
        n_ok      += pkt_ok;
        n_csum    += err_checksum;
        n_len     += err_length;
        n_gap     += err_seq_gap;
        n_timeout += err_timeout;
    end

    logic [7:0] csum;

    task automatic put(input logic [7:0] b);
        @(negedge clk);
        rx_data  = b;
        rx_valid = 1'b1;
        @(negedge clk);
        rx_valid = 1'b0;
        repeat (3) @(negedge clk);
    endtask

    task automatic put_c(input logic [7:0] b);
        csum = csum ^ b;
        put(b);
    endtask

    task automatic send_header(input logic [7:0] msg_type, input logic [15:0] seq, input logic [7:0] len);
        put(SYNC0);
        put(SYNC1);
        csum = 8'h00;
        put_c(msg_type);
        put_c(seq[15:8]);
        put_c(seq[7:0]);
        put_c(len);
    endtask

    task automatic send_trade(input logic [15:0] seq, input logic [7:0] symbol, input logic side,
                              input logic [31:0] price, input logic [31:0] qty, input logic corrupt);
        send_header(MSG_TRADE, seq, TRADE_LEN);
        put_c(symbol);
        put_c({7'b0, side});
        for (int i = 3; i >= 0; i--) put_c(price[8*i +: 8]);
        for (int i = 3; i >= 0; i--) put_c(qty[8*i +: 8]);
        put(corrupt ? ~csum : csum);
    endtask

    task automatic expect_counts(input string name, input int trades, input int ok, input int csums,
                                 input int lens, input int gaps, input int timeouts);
        if (n_trade != trades || n_ok != ok || n_csum != csums ||
            n_len != lens || n_gap != gaps || n_timeout != timeouts) begin
            $display("FAIL %s: trade=%0d/%0d ok=%0d/%0d csum=%0d/%0d len=%0d/%0d gap=%0d/%0d timeout=%0d/%0d",
                     name, n_trade, trades, n_ok, ok, n_csum, csums, n_len, lens, n_gap, gaps,
                     n_timeout, timeouts);
            errors++;
        end
    endtask

    task automatic expect_trade(input string name, input logic [15:0] seq, input logic [7:0] symbol,
                                input logic side, input logic [31:0] price, input logic [31:0] qty);
        if (trade_seq !== seq || trade_symbol !== symbol || trade_side !== side ||
            trade_price !== price || trade_qty !== qty) begin
            $display("FAIL %s: seq=%0d sym=%0d side=%0d price=%0d qty=%0d", name,
                     trade_seq, trade_symbol, trade_side, trade_price, trade_qty);
            errors++;
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        send_trade(16'd100, 8'd2, 1'b1, 32'd6543210, 32'd1234567, 1'b0);
        expect_counts("single trade", 1, 1, 0, 0, 0, 0);
        expect_trade("single trade", 16'd100, 8'd2, 1'b1, 32'd6543210, 32'd1234567);

        send_header(MSG_HEARTBEAT, 16'd101, 8'd0);
        put(csum);
        expect_counts("heartbeat", 1, 2, 0, 0, 0, 0);

        put(8'h13);
        put(SYNC0);
        send_trade(16'd102, 8'd0, 1'b0, 32'hFFFF_FFFF, 32'd1, 1'b0);
        expect_counts("resync through noise", 2, 3, 0, 0, 0, 0);
        expect_trade("resync through noise", 16'd102, 8'd0, 1'b0, 32'hFFFF_FFFF, 32'd1);

        send_trade(16'd103, 8'd1, 1'b0, 32'd100, 32'd100, 1'b1);
        expect_counts("bad checksum", 2, 3, 1, 0, 0, 0);

        send_trade(16'd104, 8'd1, 1'b0, 32'd200, 32'd300, 1'b0);
        expect_counts("sequence gap", 3, 4, 1, 0, 1, 0);
        expect_trade("sequence gap", 16'd104, 8'd1, 1'b0, 32'd200, 32'd300);

        send_header(8'h7E, 16'd105, 8'd5);
        for (int i = 0; i < 5; i++) put_c(8'(i * 37));
        put(csum);
        expect_counts("unknown type skipped", 3, 5, 1, 0, 1, 0);

        send_header(MSG_TRADE, 16'd106, 8'd9);
        expect_counts("trade with wrong length", 3, 5, 1, 1, 1, 0);

        send_header(8'h03, 16'd106, 8'd40);
        expect_counts("oversized length", 3, 5, 1, 2, 1, 0);

        send_trade(16'd106, 8'd3, 1'b1, 32'd42, 32'd43, 1'b0);
        expect_counts("recover after length errors", 4, 6, 1, 2, 1, 0);

        send_header(MSG_TRADE, 16'd107, TRADE_LEN);
        put_c(8'd1);
        put_c(8'd0);
        repeat (TIMEOUT_CLKS + 10) @(negedge clk);
        expect_counts("mid-frame timeout", 4, 6, 1, 2, 1, 1);

        send_trade(16'd107, 8'd1, 1'b0, 32'd777, 32'd888, 1'b0);
        expect_counts("recover after timeout", 5, 7, 1, 2, 1, 1);

        for (int i = 0; i < 20; i++) send_trade(16'(108 + i), 8'(i % 4), i[0], 32'(1000 + i), 32'(i), 1'b0);
        expect_counts("burst", 25, 27, 1, 2, 1, 1);
        expect_trade("burst", 16'd127, 8'd3, 1'b1, 32'd1019, 32'd19);

        send_trade(16'hFFFF, 8'd0, 1'b0, 32'd1, 32'd1, 1'b0);
        send_trade(16'h0000, 8'd0, 1'b0, 32'd2, 32'd2, 1'b0);
        expect_counts("sequence wrap", 27, 29, 1, 2, 2, 1);

        if (errors == 0) $display("PASS tb_packet_parser");
        else             $display("FAIL tb_packet_parser: %0d errors", errors);
        $finish;
    end

endmodule
