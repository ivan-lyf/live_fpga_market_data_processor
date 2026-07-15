// Keep in sync with host/protocol.py.
/* verilator lint_off UNUSEDPARAM */
package mdp_pkg;

    localparam logic [7:0] SYNC0         = 8'hA5;
    localparam logic [7:0] SYNC1         = 8'h5A;

    localparam logic [7:0] MSG_TRADE     = 8'h01;
    localparam logic [7:0] MSG_HEARTBEAT = 8'h02;

    localparam logic [7:0] TRADE_LEN     = 8'd10;
    localparam logic [7:0] MAX_LEN       = 8'd32;

    localparam int         NUM_SYMBOLS   = 4;

endpackage
/* verilator lint_on UNUSEDPARAM */
