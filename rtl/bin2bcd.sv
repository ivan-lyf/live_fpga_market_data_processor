// Sequential double-dabble, one bit per clock.
module bin2bcd #(
    parameter int W      = 32,
    parameter int DIGITS = 10
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                start,
    input  logic [W-1:0]        bin,
    output logic                busy,
    output logic                done,
    output logic [4*DIGITS-1:0] bcd
);

    localparam int CW = $clog2(W + 1);

    logic [W-1:0]        bin_q;
    /* verilator lint_off UNUSEDSIGNAL */  // top digit's MSB shifts out
    logic [4*DIGITS-1:0] acc, acc_adj;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [CW-1:0]       remaining;

    always_comb begin
        acc_adj = acc;
        for (int d = 0; d < DIGITS; d++) begin
            if (acc[4*d +: 4] >= 4'd5) acc_adj[4*d +: 4] = acc[4*d +: 4] + 4'd3;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_q     <= '0;
            acc       <= '0;
            remaining <= '0;
            busy      <= 1'b0;
            done      <= 1'b0;
            bcd       <= '0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                if (start) begin
                    bin_q     <= bin;
                    acc       <= '0;
                    remaining <= CW'(W);
                    busy      <= 1'b1;
                end
            end else begin
                acc       <= {acc_adj[4*DIGITS-2:0], bin_q[W-1]};
                bin_q     <= bin_q << 1;
                remaining <= remaining - 1'b1;
                if (remaining == CW'(1)) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    bcd  <= {acc_adj[4*DIGITS-2:0], bin_q[W-1]};
                end
            end
        end
    end

endmodule
