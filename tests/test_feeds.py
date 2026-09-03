import asyncio
import itertools
import unittest
from decimal import Decimal

from host import bridge, protocol
from host.feeds import Trade, parse_coinbase_message, synthetic_trade_stream


class CoinbaseParseTest(unittest.TestCase):
    def test_match_reports_taker_side(self):
        msg = {
            "type": "match",
            "trade_id": 1,
            "side": "buy",
            "size": "0.00120000",
            "price": "64123.45",
            "product_id": "BTC-USD",
            "sequence": 99,
            "time": "2026-01-01T00:00:00.000000Z",
        }
        self.assertEqual(parse_coinbase_message(msg), Trade("BTC-USD", "sell", Decimal("64123.45"), Decimal("0.0012")))
        msg["side"] = "sell"
        self.assertEqual(parse_coinbase_message(msg).side, "buy")

    def test_ignores_other_messages(self):
        self.assertIsNone(parse_coinbase_message({"type": "subscriptions", "channels": []}))
        self.assertIsNone(parse_coinbase_message({"type": "heartbeat"}))


class SyntheticFeedTest(unittest.TestCase):
    def test_deterministic_and_encodable(self):
        products = ["BTC-USD", "ETH-USD", "SOL-USD", "LTC-USD"]
        a = list(itertools.islice(synthetic_trade_stream(products, seed=1), 200))
        b = list(itertools.islice(synthetic_trade_stream(products, seed=1), 200))
        self.assertEqual(a, b)
        for trade in a:
            self.assertIn(trade.product, products)
            self.assertGreater(trade.price, 0)
            self.assertGreater(trade.size, 0)
            msg = protocol.make_trade_msg(products.index(trade.product), trade.side, trade.price, trade.size)
            self.assertLess(msg.price, protocol.U32_MAX)


class BridgeTest(unittest.TestCase):
    def test_queue_drops_oldest_when_full(self):
        async def scenario():
            queue = asyncio.Queue(maxsize=2)
            stats = bridge.Stats()
            for i in range(4):
                bridge.put_drop_oldest(queue, i, stats)
            return [queue.get_nowait(), queue.get_nowait()], stats.dropped

        items, dropped = asyncio.run(scenario())
        self.assertEqual(items, [2, 3])
        self.assertEqual(dropped, 2)

    def test_drain_assigns_consecutive_sequence_numbers(self):
        class Capture:
            def __init__(self):
                self.data = bytearray()

            def write(self, frame):
                self.data += frame

        async def scenario():
            queue = asyncio.Queue()
            sink = Capture()
            stats = bridge.Stats()
            queue.put_nowait(protocol.TradeMsg(0, 0, 100, 1))
            queue.put_nowait(bridge.HEARTBEAT)
            queue.put_nowait(protocol.TradeMsg(1, 1, 200, 2))
            task = asyncio.create_task(bridge.drain(queue, sink, stats))
            while stats.frames_out < 3:
                await asyncio.sleep(0.01)
            task.cancel()
            return sink.data

        decoder = protocol.Decoder()
        frames = decoder.feed(bytes(asyncio.run(scenario())))
        self.assertEqual([f.seq for f in frames], [0, 1, 2])
        self.assertEqual(decoder.seq_gaps, 0)

    def test_port_required_without_dry_run(self):
        with self.assertRaises(SystemExit):
            bridge.parse_args([])
        self.assertTrue(bridge.parse_args(["--dry-run"]).dry_run)


if __name__ == "__main__":
    unittest.main()
