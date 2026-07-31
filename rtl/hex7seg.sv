// Active-low segments: seg[6:0] = g..a, seg[7] = DP.
module hex7seg (
    input  logic [3:0] digit,
    input  logic       blank,
    input  logic       dp,
    output logic [7:0] seg
);

    logic [6:0] pattern;

    always_comb begin
        case (digit)
            4'h0: pattern = 7'b1000000;
            4'h1: pattern = 7'b1111001;
            4'h2: pattern = 7'b0100100;
            4'h3: pattern = 7'b0110000;
            4'h4: pattern = 7'b0011001;
            4'h5: pattern = 7'b0010010;
            4'h6: pattern = 7'b0000010;
            4'h7: pattern = 7'b1111000;
            4'h8: pattern = 7'b0000000;
            4'h9: pattern = 7'b0010000;
            4'hA: pattern = 7'b0001000;
            4'hB: pattern = 7'b0000011;
            4'hC: pattern = 7'b1000110;
            4'hD: pattern = 7'b0100001;
            4'hE: pattern = 7'b0000110;
            default: pattern = 7'b0001110;  // F
        endcase
    end

    assign seg = {~dp, blank ? 7'b1111111 : pattern};

endmodule
