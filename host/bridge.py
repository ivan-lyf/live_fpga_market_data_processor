"""Stream live trades to the DE10-Lite over UART."""

from __future__ import annotations

import argparse
import asyncio
import logging
import time
from dataclasses import dataclass
from typing import AsyncIterator, Dict, List, Union

from . import protocol
from .feeds import COINBASE_WS_URL, Trade, coinbase_trades, synthetic_trades

log = logging.getLogger("bridge")

DEFAULT_PRODUCTS = "BTC-USD,ETH-USD,SOL-USD,LTC-USD"


class _Heartbeat:
    pass


HEARTBEAT = _Heartbeat()
QueueItem = Union[protocol.TradeMsg, _Heartbeat]


@dataclass
class Stats:
    trades_in: int = 0
    frames_out: int = 0
    bytes_out: int = 0
    dropped: int = 0
    unmapped: int = 0


class SerialSink:
    def __init__(self, port: str, baud: int) -> None:
        import serial

        self._serial = serial.Serial(port, baud, timeout=0, write_timeout=2)

    def write(self, frame: bytes) -> None:
        self._serial.write(frame)

    def close(self) -> None:
        self._serial.close()


class HexDumpSink:
    def write(self, frame: bytes) -> None:
        print(frame.hex(" "))

    def close(self) -> None:
        pass


def put_drop_oldest(queue: "asyncio.Queue[QueueItem]", item: QueueItem, stats: Stats) -> None:
    if queue.full():
        queue.get_nowait()
        stats.dropped += 1
    queue.put_nowait(item)


async def pump_feed(
    feed: AsyncIterator[Trade],
    symbol_ids: Dict[str, int],
    queue: "asyncio.Queue[QueueItem]",
    stats: Stats,
) -> None:
    async for trade in feed:
        stats.trades_in += 1
        symbol_id = symbol_ids.get(trade.product)
        if symbol_id is None:
            stats.unmapped += 1
            continue
        log.debug("%s %s %s @ %s", trade.product, trade.side, trade.size, trade.price)
        put_drop_oldest(queue, protocol.make_trade_msg(symbol_id, trade.side, trade.price, trade.size), stats)


async def send_heartbeats(queue: "asyncio.Queue[QueueItem]", interval: float, stats: Stats) -> None:
    while True:
        await asyncio.sleep(interval)
        put_drop_oldest(queue, HEARTBEAT, stats)


async def drain(queue: "asyncio.Queue[QueueItem]", sink: Union[SerialSink, HexDumpSink], stats: Stats) -> None:
    # Assign seq at write time so a gap on the FPGA means bytes lost on the wire.
    seq = 0
    while True:
        item = await queue.get()
        if isinstance(item, protocol.TradeMsg):
            frame = protocol.encode_trade(seq, item)
        else:
            frame = protocol.encode_heartbeat(seq)
        await asyncio.to_thread(sink.write, frame)
        seq = (seq + 1) & 0xFFFF
        stats.frames_out += 1
        stats.bytes_out += len(frame)


async def report(stats: Stats, interval: float) -> None:
    last_time = time.monotonic()
    last_frames = stats.frames_out
    while True:
        await asyncio.sleep(interval)
        now = time.monotonic()
        rate = (stats.frames_out - last_frames) / (now - last_time)
        last_time, last_frames = now, stats.frames_out
        log.info(
            "trades_in=%d frames_out=%d (%.1f/s) bytes_out=%d dropped=%d unmapped=%d",
            stats.trades_in, stats.frames_out, rate, stats.bytes_out, stats.dropped, stats.unmapped,
        )


async def run(args: argparse.Namespace) -> None:
    products: List[str] = [p.strip() for p in args.products.split(",") if p.strip()]
    if not 1 <= len(products) <= protocol.NUM_SYMBOLS:
        raise SystemExit(f"--products takes 1..{protocol.NUM_SYMBOLS} products (SW[1:0] selects among them)")
    symbol_ids = {product: i for i, product in enumerate(products)}
    for product, i in symbol_ids.items():
        log.info("SW[1:0]=%d%d -> %s", (i >> 1) & 1, i & 1, product)

    if args.synthetic:
        feed = synthetic_trades(products, args.rate, args.seed)
    else:
        feed = coinbase_trades(products, args.url)
    sink = HexDumpSink() if args.dry_run else SerialSink(args.port, args.baud)

    stats = Stats()
    queue: "asyncio.Queue[QueueItem]" = asyncio.Queue(maxsize=args.queue)
    tasks = [
        asyncio.create_task(pump_feed(feed, symbol_ids, queue, stats)),
        asyncio.create_task(send_heartbeats(queue, args.heartbeat, stats)),
        asyncio.create_task(drain(queue, sink, stats)),
        asyncio.create_task(report(stats, args.stats_interval)),
    ]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
        for task in done:
            task.result()
    finally:
        for task in tasks:
            task.cancel()
        sink.close()


def parse_args(argv: Union[List[str], None] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", help="serial device of the USB-UART adapter")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--products", default=DEFAULT_PRODUCTS, help="comma-separated, max 4 (default: %(default)s)")
    parser.add_argument("--url", default=COINBASE_WS_URL, help="WebSocket feed URL")
    parser.add_argument("--synthetic", action="store_true", help="use generated trades instead of the live feed")
    parser.add_argument("--rate", type=float, default=20.0, help="synthetic trades per second")
    parser.add_argument("--seed", type=int, default=None, help="synthetic feed RNG seed")
    parser.add_argument("--dry-run", action="store_true", help="print frames as hex instead of opening the port")
    parser.add_argument("--heartbeat", type=float, default=1.0, help="heartbeat interval in seconds")
    parser.add_argument("--queue", type=int, default=512, help="max frames buffered ahead of the UART")
    parser.add_argument("--stats-interval", type=float, default=5.0)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    if not args.dry_run and not args.port:
        parser.error("--port is required unless --dry-run is given")
    return args


def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
