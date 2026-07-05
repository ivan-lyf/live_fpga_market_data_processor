// 8N1 receiver, samples mid-bit.
module uart_rx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD   = 115_200
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid,
    output logic       frame_err
);

    localparam int CLKS_PER_BIT = CLK_HZ / BAUD;
    localparam int CW           = $clog2(CLKS_PER_BIT);

    localparam logic [CW-1:0] BIT_END  = CW'(CLKS_PER_BIT - 1);
    localparam logic [CW-1:0] HALF_END = CW'(CLKS_PER_BIT / 2 - 1);

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;

    logic          rx_meta, rx_sync;
    state_t        state;
    logic [CW-1:0] cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shreg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            cnt       <= '0;
            bit_idx   <= '0;
            shreg     <= '0;
            data      <= '0;
            valid     <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            valid     <= 1'b0;
            frame_err <= 1'b0;

            case (state)
                IDLE: begin
                    cnt <= '0;
                    if (!rx_sync) state <= START;
                end

                START: begin
                    if (cnt == HALF_END) begin
                        cnt     <= '0;
                        bit_idx <= '0;
                        if (rx_sync) state <= IDLE;  // glitch
                        else         state <= DATA;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                DATA: begin
                    if (cnt == BIT_END) begin
                        cnt   <= '0;
                        shreg <= {rx_sync, shreg[7:1]};
                        if (bit_idx == 3'd7) state <= STOP;
                        bit_idx <= bit_idx + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                STOP: begin
                    if (cnt == BIT_END) begin
                        state <= IDLE;
                        if (rx_sync) begin
                            data  <= shreg;
                            valid <= 1'b1;
                        end else begin
                            frame_err <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
