// DE10-Lite top level. Switch and LED map is in the README.
/* verilator lint_off SYNCASYNCNET */
module de10_lite_top #(
    parameter int CLK_HZ      = 50_000_000,
    parameter int BAUD        = 115_200,
    parameter int TIMEOUT_MS  = 20,
    parameter int ACTIVITY_MS = 50,
    parameter int LINK_MS     = 2_000
) (
    input  logic       MAX10_CLK1_50,
    input  logic [1:0] KEY,
    input  logic [9:0] SW,
    input  logic       GPIO_UART_RX,   // GPIO[0]
    output logic [9:0] LEDR,
    output logic [7:0] HEX0,
    output logic [7:0] HEX1,
    output logic [7:0] HEX2,
    output logic [7:0] HEX3,
    output logic [7:0] HEX4,
    output logic [7:0] HEX5
);

    import mdp_pkg::*;

    localparam int CLKS_PER_MS = CLK_HZ / 1000;

    localparam logic [1:0] MODE_PRICE  = 2'b00;
    localparam logic [1:0] MODE_QTY    = 2'b01;
    localparam logic [1:0] MODE_COUNT  = 2'b10;
    localparam logic [1:0] MODE_ERRORS = 2'b11;

    wire clk  = MAX10_CLK1_50;
    wire key0 = KEY[0];

    logic [1:0] rst_pipe;
    always_ff @(posedge clk or negedge key0) begin
        if (!key0) rst_pipe <= 2'b00;
        else       rst_pipe <= {rst_pipe[0], 1'b1};
    end
    wire rst_n = rst_pipe[1];

    /* verilator lint_off UNUSEDSIGNAL */  // SW[7:3] reserved
    logic [9:0] sw_meta, sw_q;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0] clr_pipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_meta  <= '0;
            sw_q     <= '0;
            clr_pipe <= '0;
        end else begin
            sw_meta  <= SW;
            sw_q     <= sw_meta;
            clr_pipe <= {clr_pipe[0], ~KEY[1]};
        end
    end
    wire clear_errors = clr_pipe[1];

    logic [7:0] rx_data;
    logic       rx_valid, rx_frame_err;

    uart_rx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD)
    ) u_uart_rx (
        .clk       (clk),
        .rst_n     (rst_n),
        .rx        (GPIO_UART_RX),
        .data      (rx_data),
        .valid     (rx_valid),
        .frame_err (rx_frame_err)
    );

    logic        trade_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] trade_seq;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  trade_symbol;
    logic        trade_side;
    logic [31:0] trade_price, trade_qty;
    logic        pkt_ok, err_checksum, err_length, err_seq_gap, err_timeout;

    packet_parser #(
        .TIMEOUT_CLKS (TIMEOUT_MS * CLKS_PER_MS)
    ) u_parser (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .trade_valid  (trade_valid),
        .trade_seq    (trade_seq),
        .trade_symbol (trade_symbol),
        .trade_side   (trade_side),
        .trade_price  (trade_price),
        .trade_qty    (trade_qty),
        .pkt_ok       (pkt_ok),
        .err_checksum (err_checksum),
        .err_length   (err_length),
        .err_seq_gap  (err_seq_gap),
        .err_timeout  (err_timeout)
    );

    logic [31:0] sel_price, sel_qty, sel_count;
    logic        sel_side, sel_uptick, sel_downtick, unmapped;

    trade_book #(
        .NUM_SYMBOLS (NUM_SYMBOLS)
    ) u_book (
        .clk          (clk),
        .rst_n        (rst_n),
        .trade_valid  (trade_valid),
        .trade_symbol (trade_symbol),
        .trade_side   (trade_side),
        .trade_price  (trade_price),
        .trade_qty    (trade_qty),
        .sel          (sw_q[1:0]),
        .sel_price    (sel_price),
        .sel_qty      (sel_qty),
        .sel_count    (sel_count),
        .sel_side     (sel_side),
        .sel_uptick   (sel_uptick),
        .sel_downtick (sel_downtick),
        .unmapped     (unmapped)
    );

    wire any_error = err_checksum | err_length | err_seq_gap | err_timeout | rx_frame_err;

    logic [31:0] err_count;
    logic        sticky_gap, sticky_frame, sticky_line, sticky_unmapped;
    logic [31:0] activity_cnt, link_cnt;

    localparam logic [31:0] ACTIVITY_CLKS = 32'(ACTIVITY_MS * CLKS_PER_MS);
    localparam logic [31:0] LINK_CLKS     = 32'(LINK_MS * CLKS_PER_MS);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_count    <= '0;
            sticky_gap   <= 1'b0;
            sticky_frame <= 1'b0;
            sticky_line     <= 1'b0;
            sticky_unmapped <= 1'b0;
            activity_cnt    <= '0;
            link_cnt        <= LINK_CLKS;
        end else begin
            if (clear_errors) begin
                err_count       <= '0;
                sticky_gap      <= 1'b0;
                sticky_frame    <= 1'b0;
                sticky_line     <= 1'b0;
                sticky_unmapped <= 1'b0;
            end else begin
                if (any_error && err_count != 32'hFFFF_FFFF) err_count <= err_count + 1'b1;
                if (err_seq_gap)                 sticky_gap      <= 1'b1;
                if (err_checksum || err_length)  sticky_frame    <= 1'b1;
                if (rx_frame_err || err_timeout) sticky_line     <= 1'b1;
                if (unmapped)                    sticky_unmapped <= 1'b1;
            end

            if (trade_valid)            activity_cnt <= ACTIVITY_CLKS;
            else if (activity_cnt != 0) activity_cnt <= activity_cnt - 1'b1;

            if (pkt_ok)                     link_cnt <= '0;
            else if (link_cnt != LINK_CLKS) link_cnt <= link_cnt + 1'b1;
        end
    end

    wire [1:0] mode       = sw_q[9:8];
    wire       show_cents = sw_q[2];

    logic [31:0] disp_value;
    logic [3:0]  disp_lo;    // BCD digit shown on HEX0
    logic [2:0]  disp_dp;    // HEX index with the decimal point
    logic        disp_dp_en;

    always_comb begin
        disp_value = sel_price;
        disp_lo    = 4'd2;
        disp_dp    = 3'd0;
        disp_dp_en = 1'b0;
        case (mode)
            MODE_PRICE: begin
                if (show_cents) begin
                    disp_lo    = 4'd0;
                    disp_dp    = 3'd2;
                    disp_dp_en = 1'b1;
                end
            end
            MODE_QTY: begin
                disp_value = sel_qty;
                disp_dp    = 3'd4;
                disp_dp_en = 1'b1;
            end
            MODE_COUNT: begin
                disp_value = sel_count;
                disp_lo    = 4'd0;
            end
            MODE_ERRORS: begin
                disp_value = err_count;
                disp_lo    = 4'd0;
            end
            default: ;
        endcase
    end

    logic        conv_busy, conv_done;
    logic [39:0] conv_bcd;

    bin2bcd #(
        .W      (32),
        .DIGITS (10)
    ) u_bin2bcd (
        .clk   (clk),
        .rst_n (rst_n),
        .start (!conv_busy),
        .bin   (disp_value),
        .busy  (conv_busy),
        .done  (conv_done),
        .bcd   (conv_bcd)
    );

    // Keep digits and decimal point from the same sample.
    logic [3:0]  pend_lo, shown_lo;
    logic [2:0]  pend_dp, shown_dp;
    logic        pend_dp_en, shown_dp_en;
    logic [39:0] shown_bcd;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend_lo     <= '0;
            pend_dp     <= '0;
            pend_dp_en  <= 1'b0;
            shown_lo    <= '0;
            shown_dp    <= '0;
            shown_dp_en <= 1'b0;
            shown_bcd   <= '0;
        end else begin
            if (!conv_busy) begin
                pend_lo    <= disp_lo;
                pend_dp    <= disp_dp;
                pend_dp_en <= disp_dp_en;
            end
            if (conv_done) begin
                shown_bcd   <= conv_bcd;
                shown_lo    <= pend_lo;
                shown_dp    <= pend_dp;
                shown_dp_en <= pend_dp_en;
            end
        end
    end

    logic [3:0] digit    [0:5];
    logic       blank    [0:5];
    logic       dp       [0:5];
    logic       overflow;
    logic [7:0] hex      [0:5];

    always_comb begin
        logic leading;
        for (int i = 0; i < 6; i++) begin
            digit[i] = shown_bcd[4*(int'(shown_lo) + i) +: 4];
            dp[i]    = shown_dp_en && (shown_dp == 3'(i));
        end

        // Blank leading zeros, keeping the units digit and the DP digit.
        leading = 1'b1;
        for (int i = 5; i >= 0; i--) begin
            leading  = leading && (digit[i] == 4'd0) && (i > 0) &&
                       !(shown_dp_en && shown_dp >= 3'(i));
            blank[i] = leading;
        end

        overflow = 1'b0;
        for (int d = 0; d < 10; d++) begin
            if (d >= int'(shown_lo) + 6 && shown_bcd[4*d +: 4] != 4'd0) overflow = 1'b1;
        end
    end

    for (genvar i = 0; i < 6; i++) begin : g_hex
        hex7seg u_seg (
            .digit (digit[i]),
            .blank (blank[i]),
            .dp    (dp[i]),
            .seg   (hex[i])
        );
    end

    assign HEX0 = hex[0];
    assign HEX1 = hex[1];
    assign HEX2 = hex[2];
    assign HEX3 = hex[3];
    assign HEX4 = hex[4];
    assign HEX5 = hex[5];

    assign LEDR[0] = activity_cnt != 0;
    assign LEDR[1] = sel_count != 0 && !sel_side;
    assign LEDR[2] = sel_uptick;
    assign LEDR[3] = sel_downtick;
    assign LEDR[4] = link_cnt != LINK_CLKS;
    assign LEDR[5] = sticky_unmapped;
    assign LEDR[6] = overflow;
    assign LEDR[7] = sticky_gap;
    assign LEDR[8] = sticky_frame;
    assign LEDR[9] = sticky_line;

endmodule
/* verilator lint_on SYNCASYNCNET */
