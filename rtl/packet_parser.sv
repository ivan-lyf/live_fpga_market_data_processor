// A5 5A | TYPE | SEQ_H SEQ_L | LEN | PAYLOAD[LEN] | CHK (XOR of TYPE..PAYLOAD)
module packet_parser #(
    parameter int TIMEOUT_CLKS = 1_000_000
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  rx_data,
    input  logic        rx_valid,

    output logic        trade_valid,
    output logic [15:0] trade_seq,
    output logic [7:0]  trade_symbol,
    output logic        trade_side,    // 0 = buy, 1 = sell
    output logic [31:0] trade_price,   // cents
    output logic [31:0] trade_qty,     // 1e-6 units

    output logic        pkt_ok,
    output logic        err_checksum,
    output logic        err_length,
    output logic        err_seq_gap,
    output logic        err_timeout
);

    import mdp_pkg::*;

    typedef enum logic [2:0] {
        S_SYNC0, S_SYNC1, S_TYPE, S_SEQ_HI, S_SEQ_LO, S_LEN, S_PAYLOAD, S_CHECK
    } state_t;

    localparam int            TW       = $clog2(TIMEOUT_CLKS);
    localparam logic [TW-1:0] GAP_LAST = TW'(TIMEOUT_CLKS - 1);

    state_t        state;
    logic [7:0]    msg_type;
    logic [15:0]   seq;
    logic [7:0]    len;
    logic [7:0]    idx;
    logic [7:0]    csum;
    logic [79:0]   payload;
    logic [15:0]   last_seq;
    logic          have_seq;
    logic [TW-1:0] gap;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_SYNC0;
            msg_type     <= '0;
            seq          <= '0;
            len          <= '0;
            idx          <= '0;
            csum         <= '0;
            payload      <= '0;
            last_seq     <= '0;
            have_seq     <= 1'b0;
            gap          <= '0;
            trade_valid  <= 1'b0;
            trade_seq    <= '0;
            trade_symbol <= '0;
            trade_side   <= 1'b0;
            trade_price  <= '0;
            trade_qty    <= '0;
            pkt_ok       <= 1'b0;
            err_checksum <= 1'b0;
            err_length   <= 1'b0;
            err_seq_gap  <= 1'b0;
            err_timeout  <= 1'b0;
        end else begin
            trade_valid  <= 1'b0;
            pkt_ok       <= 1'b0;
            err_checksum <= 1'b0;
            err_length   <= 1'b0;
            err_seq_gap  <= 1'b0;
            err_timeout  <= 1'b0;

            if (rx_valid || state == S_SYNC0) gap <= '0;
            else                              gap <= gap + 1'b1;

            if (!rx_valid && state != S_SYNC0 && gap == GAP_LAST) begin
                err_timeout <= 1'b1;
                state       <= S_SYNC0;
            end else if (rx_valid) begin
                case (state)
                    S_SYNC0: begin
                        if (rx_data == SYNC0) state <= S_SYNC1;
                    end

                    S_SYNC1: begin
                        if (rx_data == SYNC1)      state <= S_TYPE;
                        else if (rx_data != SYNC0) state <= S_SYNC0;
                    end

                    S_TYPE: begin
                        msg_type <= rx_data;
                        csum     <= rx_data;
                        state    <= S_SEQ_HI;
                    end

                    S_SEQ_HI: begin
                        seq[15:8] <= rx_data;
                        csum      <= csum ^ rx_data;
                        state     <= S_SEQ_LO;
                    end

                    S_SEQ_LO: begin
                        seq[7:0] <= rx_data;
                        csum     <= csum ^ rx_data;
                        state    <= S_LEN;
                    end

                    S_LEN: begin
                        len  <= rx_data;
                        csum <= csum ^ rx_data;
                        idx  <= '0;
                        if (rx_data > MAX_LEN ||
                            (msg_type == MSG_TRADE && rx_data != TRADE_LEN)) begin
                            err_length <= 1'b1;
                            state      <= S_SYNC0;
                        end else if (rx_data == 8'd0) begin
                            state <= S_CHECK;
                        end else begin
                            state <= S_PAYLOAD;
                        end
                    end

                    S_PAYLOAD: begin
                        csum <= csum ^ rx_data;
                        if (idx < TRADE_LEN) payload <= {payload[71:0], rx_data};
                        idx <= idx + 1'b1;
                        if (idx == len - 8'd1) state <= S_CHECK;
                    end

                    S_CHECK: begin
                        state <= S_SYNC0;
                        if (rx_data == csum) begin
                            pkt_ok   <= 1'b1;
                            last_seq <= seq;
                            have_seq <= 1'b1;
                            if (have_seq && seq != last_seq + 16'd1) err_seq_gap <= 1'b1;

                            if (msg_type == MSG_TRADE) begin
                                trade_valid  <= 1'b1;
                                trade_seq    <= seq;
                                trade_symbol <= payload[79:72];
                                trade_side   <= payload[64];
                                trade_price  <= payload[63:32];
                                trade_qty    <= payload[31:0];
                            end
                        end else begin
                            err_checksum <= 1'b1;
                        end
                    end

                    default: state <= S_SYNC0;
                endcase
            end
        end
    end

endmodule
