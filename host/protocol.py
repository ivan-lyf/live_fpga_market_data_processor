"""Wire protocol shared with rtl/packet_parser.sv. See README for the layout."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from typing import List, Optional

SYNC = b"\xA5\x5A"

MSG_TRADE = 0x01
MSG_HEARTBEAT = 0x02

MAX_PAYLOAD = 32
TRADE_PAYLOAD_LEN = 10
NUM_SYMBOLS = 4

PRICE_SCALE = 100
QTY_SCALE = 1_000_000

SIDE_BUY = 0
SIDE_SELL = 1

U32_MAX = 0xFFFFFFFF

_TRADE = struct.Struct(">BBII")
assert _TRADE.size == TRADE_PAYLOAD_LEN


@dataclass(frozen=True)
class Frame:
    msg_type: int
    seq: int
    payload: bytes


@dataclass(frozen=True)
class TradeMsg:
    symbol_id: int
    side: int
    price: int  # cents
    qty: int  # 1e-6 units


def checksum(data: bytes) -> int:
    value = 0
    for b in data:
        value ^= b
    return value


def encode_frame(msg_type: int, seq: int, payload: bytes = b"") -> bytes:
    if not 0 <= msg_type <= 0xFF:
        raise ValueError(f"message type out of range: {msg_type}")
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"payload too long: {len(payload)} > {MAX_PAYLOAD}")
    body = bytes([msg_type, (seq >> 8) & 0xFF, seq & 0xFF, len(payload)]) + payload
    return SYNC + body + bytes([checksum(body)])


def encode_trade(seq: int, msg: TradeMsg) -> bytes:
    payload = _TRADE.pack(msg.symbol_id, msg.side, msg.price, msg.qty)
    return encode_frame(MSG_TRADE, seq, payload)


def encode_heartbeat(seq: int) -> bytes:
    return encode_frame(MSG_HEARTBEAT, seq)


def decode_trade(payload: bytes) -> TradeMsg:
    symbol_id, side, price, qty = _TRADE.unpack(payload)
    return TradeMsg(symbol_id, side, price, qty)


def to_fixed(value: Decimal, scale: int) -> int:
    if value < 0:
        raise ValueError(f"negative value: {value}")
    scaled = int((value * scale).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    return min(scaled, U32_MAX)


def make_trade_msg(symbol_id: int, side: str, price: Decimal, size: Decimal) -> TradeMsg:
    if not 0 <= symbol_id < NUM_SYMBOLS:
        raise ValueError(f"symbol id out of range: {symbol_id}")
    if side not in ("buy", "sell"):
        raise ValueError(f"unknown side: {side!r}")
    return TradeMsg(
        symbol_id=symbol_id,
        side=SIDE_BUY if side == "buy" else SIDE_SELL,
        price=to_fixed(price, PRICE_SCALE),
        qty=to_fixed(size, QTY_SCALE),
    )


class Decoder:
    """Mirrors the RTL parser (minus the timeout); golden model for tb_top."""

    _SYNC0, _SYNC1, _HEADER, _PAYLOAD, _CHECK = range(5)

    def __init__(self) -> None:
        self.checksum_errors = 0
        self.length_errors = 0
        self.seq_gaps = 0
        self._last_seq: Optional[int] = None
        self._reset_frame()

    def _reset_frame(self) -> None:
        self._state = self._SYNC0
        self._header = bytearray()
        self._payload = bytearray()
        self._length = 0

    def feed(self, data: bytes) -> List[Frame]:
        frames: List[Frame] = []
        for b in data:
            frame = self._step(b)
            if frame is not None:
                frames.append(frame)
        return frames

    def _step(self, b: int) -> Optional[Frame]:
        if self._state == self._SYNC0:
            if b == SYNC[0]:
                self._state = self._SYNC1
        elif self._state == self._SYNC1:
            if b == SYNC[1]:
                self._state = self._HEADER
            elif b != SYNC[0]:
                self._state = self._SYNC0
        elif self._state == self._HEADER:
            self._header.append(b)
            if len(self._header) == 4:
                msg_type, length = self._header[0], self._header[3]
                if length > MAX_PAYLOAD or (msg_type == MSG_TRADE and length != TRADE_PAYLOAD_LEN):
                    self.length_errors += 1
                    self._reset_frame()
                else:
                    self._length = length
                    self._state = self._PAYLOAD if length else self._CHECK
        elif self._state == self._PAYLOAD:
            self._payload.append(b)
            if len(self._payload) == self._length:
                self._state = self._CHECK
        else:
            body = bytes(self._header) + bytes(self._payload)
            msg_type = self._header[0]
            seq = (self._header[1] << 8) | self._header[2]
            payload = bytes(self._payload)
            self._reset_frame()
            if b != checksum(body):
                self.checksum_errors += 1
                return None
            if self._last_seq is not None and seq != (self._last_seq + 1) & 0xFFFF:
                self.seq_gaps += 1
            self._last_seq = seq
            return Frame(msg_type, seq, payload)
        return None
