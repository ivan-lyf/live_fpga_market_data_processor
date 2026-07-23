module trade_book #(
    parameter int NUM_SYMBOLS = 4,
    parameter int IW          = $clog2(NUM_SYMBOLS)
) (
    input  logic          clk,
    input  logic          rst_n,

    input  logic          trade_valid,
    input  logic [7:0]    trade_symbol,
    input  logic          trade_side,
    input  logic [31:0]   trade_price,
    input  logic [31:0]   trade_qty,

    input  logic [IW-1:0] sel,
    output logic [31:0]   sel_price,
    output logic [31:0]   sel_qty,
    output logic [31:0]   sel_count,
    output logic          sel_side,
    output logic          sel_uptick,
    output logic          sel_downtick,

    output logic          unmapped
);

    logic [31:0] price_q [0:NUM_SYMBOLS-1];
    logic [31:0] qty_q   [0:NUM_SYMBOLS-1];
    logic [31:0] count_q [0:NUM_SYMBOLS-1];
    logic        side_q  [0:NUM_SYMBOLS-1];
    logic        up_q    [0:NUM_SYMBOLS-1];
    logic        down_q  [0:NUM_SYMBOLS-1];

    wire          in_range = trade_symbol < 8'(NUM_SYMBOLS);
    wire [IW-1:0] id       = trade_symbol[IW-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_SYMBOLS; i++) begin
                price_q[i] <= '0;
                qty_q[i]   <= '0;
                count_q[i] <= '0;
                side_q[i]  <= 1'b0;
                up_q[i]    <= 1'b0;
                down_q[i]  <= 1'b0;
            end
            unmapped <= 1'b0;
        end else begin
            unmapped <= trade_valid && !in_range;

            if (trade_valid && in_range) begin
                if (count_q[id] != 0) begin
                    up_q[id]   <= trade_price > price_q[id];
                    down_q[id] <= trade_price < price_q[id];
                end
                price_q[id] <= trade_price;
                qty_q[id]   <= trade_qty;
                side_q[id]  <= trade_side;
                if (count_q[id] != 32'hFFFF_FFFF) count_q[id] <= count_q[id] + 1'b1;
            end
        end
    end

    assign sel_price    = price_q[sel];
    assign sel_qty      = qty_q[sel];
    assign sel_count    = count_q[sel];
    assign sel_side     = side_q[sel];
    assign sel_uptick   = up_q[sel];
    assign sel_downtick = down_q[sel];

endmodule
