IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR ?= verilator

BUILD := sim/build

RTL := rtl/mdp_pkg.sv \
       rtl/uart_rx.sv \
       rtl/packet_parser.sv \
       rtl/trade_book.sv \
       rtl/bin2bcd.sv \
       rtl/hex7seg.sv \
       rtl/de10_lite_top.sv

# Fail unless the testbench prints PASS.
define run_tb
	$(VVP) -n $(BUILD)/$(1).vvp | tee $(BUILD)/$(1).log
	@grep -q '^PASS' $(BUILD)/$(1).log
endef

.PHONY: all test sim sim-uart sim-parser lint clean

all: test

test: sim

sim: sim-uart sim-parser

$(BUILD):
	mkdir -p $@

sim-uart: | $(BUILD)
	$(IVERILOG) -g2012 -o $(BUILD)/tb_uart_rx.vvp rtl/uart_rx.sv sim/tb_uart_rx.sv
	$(call run_tb,tb_uart_rx)

sim-parser: | $(BUILD)
	$(IVERILOG) -g2012 -o $(BUILD)/tb_packet_parser.vvp rtl/mdp_pkg.sv rtl/packet_parser.sv sim/tb_packet_parser.sv
	$(call run_tb,tb_packet_parser)

lint:
	$(VERILATOR) --lint-only -Wall --top-module de10_lite_top $(RTL)

clean:
	rm -rf $(BUILD)
