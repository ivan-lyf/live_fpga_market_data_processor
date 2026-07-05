IVERILOG ?= iverilog
VVP      ?= vvp

BUILD := sim/build

# Fail unless the testbench prints PASS.
define run_tb
	$(VVP) -n $(BUILD)/$(1).vvp | tee $(BUILD)/$(1).log
	@grep -q '^PASS' $(BUILD)/$(1).log
endef

.PHONY: all test sim sim-uart clean

all: test

test: sim

sim: sim-uart

$(BUILD):
	mkdir -p $@

sim-uart: | $(BUILD)
	$(IVERILOG) -g2012 -o $(BUILD)/tb_uart_rx.vvp rtl/uart_rx.sv sim/tb_uart_rx.sv
	$(call run_tb,tb_uart_rx)

clean:
	rm -rf $(BUILD)
