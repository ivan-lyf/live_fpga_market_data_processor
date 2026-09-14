# Live Market Data FPGA Processor

A real-time trade tape on a Terasic **DE10-Lite** (Intel MAX 10). A Python bridge
subscribes to a live exchange WebSocket feed, packs each trade into a compact
binary frame, and streams it over **UART** to the FPGA, where a
**SystemVerilog** parser FSM validates and decodes the frames and drives the
7-segment displays and LEDs.

```
 Coinbase WebSocket            host (Python)                       DE10-Lite (MAX 10)
 ─────────────────            ──────────────                      ───────────────────────────────────────────
  "matches" JSON  ──►  feeds.py ──► bridge.py ──► pyserial ──UART──► uart_rx ──► packet_parser ──► trade_book
                        Trade      TradeMsg +     115200 8N1  GPIO[0]  2FF sync    sync hunt        per-symbol
                                   seq, CHK       USB-UART             mid-bit     LEN check        last px/qty
                                                  adapter              sampling    XOR checksum     tick dir
                                                                                   seq-gap detect   trade count
                                                                                   byte timeout          │
                                                                                                         ▼
                                                                         HEX0-5 ◄── hex7seg ◄── bin2bcd (double dabble)
                                                                         LEDR   ◄── status / sticky error flags
```

## Wire protocol

All multi-byte fields are big-endian.

```
+------+------+------+-------+-------+-----+--------------+-----+
| 0xA5 | 0x5A | TYPE | SEQ_H | SEQ_L | LEN | PAYLOAD[LEN] | CHK |
+------+------+------+-------+-------+-----+--------------+-----+
CHK = XOR of TYPE .. last PAYLOAD byte
```

| TYPE | Name      | LEN | Payload                                                    |
|------|-----------|-----|------------------------------------------------------------|
| 0x01 | TRADE     | 10  | `symbol u8`, `side u8` (0 buy / 1 sell aggressor), `price u32` (cents), `qty u32` (1e-6 units) |
| 0x02 | HEARTBEAT | 0   | —                                                          |

A trade is 17 bytes on the wire, so 115200 baud carries roughly 675 trades/s.
Frames with an unknown TYPE (LEN ≤ 32) are checksum-verified and skipped, which
leaves room to add message types without breaking older bitstreams.

The constants live in `host/protocol.py` and `rtl/mdp_pkg.sv`; keep them in sync.

## Parser FSM

```
SYNC0 ─A5─► SYNC1 ─5A─► TYPE ─► SEQ_HI ─► SEQ_LO ─► LEN ─┬─(LEN=0)────────► CHECK ─► SYNC0
  ▲           │ A5: stay                                 ├─(ok)─► PAYLOAD ─┘
  └─ other ───┘                                          └─(bad LEN)─► SYNC0 (err_length)
```

- **Resync**: hunts for `A5 5A`; `A5 A5 5A` still locks on the second `A5`.
- **Length check** before any payload is accepted: LEN > 32, or a TRADE whose LEN ≠ 10, aborts the frame.
- **Checksum** is folded in byte by byte; a trade is published only when CHK matches.
- **Sequence tracking**: a good frame whose SEQ is not previous + 1 (mod 2¹⁶) raises `err_seq_gap`.
  The host assigns SEQ when it writes to the port, so a gap means bytes were lost on the wire.
- **Inter-byte timeout** (20 ms by default): a stall mid-frame drops the frame instead of
  leaving the parser misaligned with the stream.

## Repository layout

```
rtl/            synthesizable SystemVerilog
  mdp_pkg.sv        protocol constants
  uart_rx.sv        8N1 receiver, 2-flop synchronizer, glitch-rejecting start bit
  packet_parser.sv  framing / validation FSM
  trade_book.sv     per-symbol last price, qty, side, tick direction, count
  bin2bcd.sv        sequential double-dabble converter
  hex7seg.sv        7-segment decoder
  de10_lite_top.sv  board top level
sim/            Icarus Verilog testbenches
host/           Python bridge, feeds, protocol, vector generator
tests/          Python unit tests
quartus/        Quartus project, DE10-Lite pin assignments, timing constraints
```

## Board setup

**Hardware:** DE10-Lite plus any **3.3 V** USB-UART adapter (FTDI, CP2102, CH340).

| Adapter | DE10-Lite                          |
|---------|------------------------------------|
| TXD     | GPIO[0] — 2×20 header pin 1 (`PIN_V10`) |
| GND     | GPIO header GND (pin 12 or 30)     |

Do not use a 5 V adapter; the MAX 10 I/O is 3.3 V.

**Build and program** (Quartus Prime Lite):

```sh
cd quartus
quartus_sh --flow compile market_data
quartus_pgm -m jtag -o "p;output_files/market_data.sof"
```

Or open `quartus/market_data.qpf` in the GUI, compile, and program over the USB-Blaster.

**Controls**

| Input      | Function                                                           |
|------------|--------------------------------------------------------------------|
| `KEY[0]`   | reset                                                              |
| `KEY[1]`   | clear sticky error LEDs and the error counter                      |
| `SW[1:0]`  | symbol id to display (order of `--products`)                       |
| `SW[2]`    | price format: 0 = whole dollars, 1 = `XXXX.XX`                     |
| `SW[9:8]`  | display: `00` price, `01` quantity (`XX.XXXX`), `10` trade count, `11` error count |

| LED       | Meaning                                  |
|-----------|------------------------------------------|
| `LEDR[0]` | trade activity                           |
| `LEDR[1]` | last trade on selected symbol was a buy  |
| `LEDR[2]` | uptick                                   |
| `LEDR[3]` | downtick                                 |
| `LEDR[4]` | link up (a valid frame within 2 s)       |
| `LEDR[5]` | trade for a symbol id ≥ 4 (sticky)       |
| `LEDR[6]` | value wider than the 6-digit window      |
| `LEDR[7]` | sequence gap (sticky)                    |
| `LEDR[8]` | checksum or length error (sticky)        |
| `LEDR[9]` | UART framing error or byte timeout (sticky) |

## Running the host bridge

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

# live Coinbase trades to the board
python -m host.bridge --port /dev/tty.usbserial-XXXX --products BTC-USD,ETH-USD,SOL-USD,LTC-USD

# no board: print frames as hex
python -m host.bridge --dry-run

# no network: synthetic random-walk trades
python -m host.bridge --port /dev/tty.usbserial-XXXX --synthetic --rate 50
```

The bridge sends a heartbeat every second so the link LED stays lit during quiet
markets. When the feed bursts faster than the UART drains, the oldest queued
frames are dropped and counted in the periodic stats line.

## Simulation and tests

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) ≥ 12 and Python ≥ 3.9;
[Verilator](https://verilator.org) is optional for lint.

```sh
make test      # Python unit tests + all three testbenches
make sim-top   # just the end-to-end testbench
make lint      # verilator --lint-only -Wall
```

| Testbench              | Covers |
|------------------------|--------|
| `tb_uart_rx`           | all 256 byte values, ±2.5 % baud error, framing error recovery, start-bit glitch rejection |
| `tb_packet_parser`     | good trades, heartbeat, resync through noise, bad checksum, bad/oversized LEN, unknown types, sequence gaps and wrap, mid-frame timeout, back-to-back bursts |
| `tb_top`               | full design at 50 MHz / 115200 baud: a stream from `host/gen_vectors.py` (trades, line noise, a corrupted frame) is serialised onto the UART pin; every decoded trade is compared against the Python decoder, then the 7-segment output is read back in each display mode and the error LEDs/clear button are checked |
