import unittest
from decimal import Decimal

from host import protocol
from host.protocol import Decoder, TradeMsg


class EncodeTest(unittest.TestCase):
    def test_trade_frame_layout(self):
        frame = protocol.encode_trade(0x1234, TradeMsg(symbol_id=2, side=1, price=6_543_210, qty=1_234_567))
        body = bytes([0x01, 0x12, 0x34, 0x0A, 0x02, 0x01]) + (6_543_210).to_bytes(4, "big") + (
            1_234_567
        ).to_bytes(4, "big")
        self.assertEqual(frame, b"\xA5\x5A" + body + bytes([protocol.checksum(body)]))
        self.assertEqual(len(frame), 17)

    def test_heartbeat_frame(self):
        self.assertEqual(protocol.encode_heartbeat(1), bytes([0xA5, 0x5A, 0x02, 0x00, 0x01, 0x00, 0x03]))

    def test_sequence_truncated_to_16_bits(self):
        self.assertEqual(protocol.encode_heartbeat(0x10005)[3:5], b"\x00\x05")

    def test_payload_limit(self):
        protocol.encode_frame(0x7E, 0, bytes(protocol.MAX_PAYLOAD))
        with self.assertRaises(ValueError):
            protocol.encode_frame(0x7E, 0, bytes(protocol.MAX_PAYLOAD + 1))

    def test_make_trade_msg_scales_and_rounds(self):
        msg = protocol.make_trade_msg(1, "sell", Decimal("64123.456"), Decimal("0.0000015"))
        self.assertEqual(msg, TradeMsg(symbol_id=1, side=protocol.SIDE_SELL, price=6_412_346, qty=2))

    def test_make_trade_msg_saturates(self):
        msg = protocol.make_trade_msg(0, "buy", Decimal("1e9"), Decimal("5000"))
        self.assertEqual((msg.price, msg.qty), (protocol.U32_MAX, protocol.U32_MAX))

    def test_make_trade_msg_rejects_bad_input(self):
        with self.assertRaises(ValueError):
            protocol.make_trade_msg(4, "buy", Decimal(1), Decimal(1))
        with self.assertRaises(ValueError):
            protocol.make_trade_msg(0, "hold", Decimal(1), Decimal(1))
        with self.assertRaises(ValueError):
            protocol.make_trade_msg(0, "buy", Decimal(-1), Decimal(1))


class DecoderTest(unittest.TestCase):
    def trade(self, seq, price=100):
        return protocol.encode_trade(seq, TradeMsg(0, 0, price, 1))

    def test_round_trip(self):
        msgs = [TradeMsg(i % 4, i % 2, 1000 + i, i) for i in range(10)]
        stream = b"".join(protocol.encode_trade(i, m) for i, m in enumerate(msgs))
        frames = Decoder().feed(stream)
        self.assertEqual([protocol.decode_trade(f.payload) for f in frames], msgs)

    def test_byte_at_a_time(self):
        decoder = Decoder()
        frames = []
        for b in self.trade(0) + protocol.encode_heartbeat(1):
            frames += decoder.feed(bytes([b]))
        self.assertEqual([f.msg_type for f in frames], [protocol.MSG_TRADE, protocol.MSG_HEARTBEAT])

    def test_resyncs_through_noise_and_repeated_sync0(self):
        frames = Decoder().feed(b"\x00\x13\xA5" + self.trade(5))
        self.assertEqual([f.seq for f in frames], [5])

    def test_checksum_error_drops_frame(self):
        bad = bytearray(self.trade(0))
        bad[-1] ^= 0xFF
        decoder = Decoder()
        frames = decoder.feed(bytes(bad) + self.trade(1))
        self.assertEqual([f.seq for f in frames], [1])
        self.assertEqual(decoder.checksum_errors, 1)

    def test_length_errors(self):
        decoder = Decoder()
        decoder.feed(bytes([0xA5, 0x5A, protocol.MSG_TRADE, 0, 0, 9]))
        decoder.feed(bytes([0xA5, 0x5A, 0x7E, 0, 0, protocol.MAX_PAYLOAD + 1]))
        self.assertEqual(decoder.length_errors, 2)
        self.assertEqual(len(decoder.feed(self.trade(0))), 1)

    def test_unknown_type_is_passed_through(self):
        frames = Decoder().feed(protocol.encode_frame(0x7E, 3, b"hello"))
        self.assertEqual(frames, [protocol.Frame(0x7E, 3, b"hello")])

    def test_sequence_gaps_and_wrap(self):
        decoder = Decoder()
        decoder.feed(self.trade(10) + self.trade(12) + self.trade(0xFFFF) + self.trade(0))
        self.assertEqual(decoder.seq_gaps, 2)


if __name__ == "__main__":
    unittest.main()
