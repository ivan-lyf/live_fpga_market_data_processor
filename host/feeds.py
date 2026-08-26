"""Coinbase and synthetic trade feeds."""

from __future__ import annotations

import asyncio
import json
import logging
import random
from dataclasses import dataclass
from decimal import Decimal
from typing import AsyncIterator, Dict, Iterator, Optional, Sequence

log = logging.getLogger(__name__)

COINBASE_WS_URL = "wss://ws-feed.exchange.coinbase.com"


@dataclass(frozen=True)
class Trade:
    product: str
    side: str  # taker side
    price: Decimal
    size: Decimal


def parse_coinbase_message(msg: dict) -> Optional[Trade]:
    # Coinbase reports the maker side; flip it to get the taker.
    if msg.get("type") not in ("match", "last_match"):
        return None
    taker_side = "sell" if msg["side"] == "buy" else "buy"
    return Trade(
        product=msg["product_id"],
        side=taker_side,
        price=Decimal(msg["price"]),
        size=Decimal(msg["size"]),
    )


async def coinbase_trades(products: Sequence[str], url: str = COINBASE_WS_URL) -> AsyncIterator[Trade]:
    import websockets

    subscribe = json.dumps({"type": "subscribe", "product_ids": list(products), "channels": ["matches"]})
    backoff = 1.0
    while True:
        try:
            async with websockets.connect(url, ping_interval=20, ping_timeout=20) as ws:
                await ws.send(subscribe)
                log.info("connected to %s, subscribed to %s", url, ", ".join(products))
                async for raw in ws:
                    msg = json.loads(raw)
                    kind = msg.get("type")
                    if kind == "error":
                        raise RuntimeError(f"feed error: {msg.get('message')}: {msg.get('reason')}")
                    if kind == "subscriptions":
                        backoff = 1.0
                        continue
                    trade = parse_coinbase_message(msg)
                    if trade is not None:
                        yield trade
        except (OSError, asyncio.TimeoutError, websockets.exceptions.WebSocketException) as exc:
            log.warning("feed disconnected (%s); reconnecting in %.0fs", exc, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)


_BASE_PRICES: Dict[str, Decimal] = {
    "BTC-USD": Decimal("65000"),
    "ETH-USD": Decimal("3200"),
    "SOL-USD": Decimal("150"),
    "LTC-USD": Decimal("80"),
}
_CENT = Decimal("0.01")
_MICRO = Decimal("0.000001")


def synthetic_trade_stream(products: Sequence[str], seed: Optional[int] = None) -> Iterator[Trade]:
    rng = random.Random(seed)
    prices = {p: float(_BASE_PRICES.get(p, Decimal("100"))) for p in products}
    while True:
        product = rng.choice(list(products))
        prices[product] *= 1.0 + rng.gauss(0.0, 0.0005)
        price = Decimal(repr(prices[product])).quantize(_CENT)
        notional = rng.expovariate(1.0 / 2000.0)
        size = max(Decimal(repr(notional / prices[product])).quantize(_MICRO), _MICRO)
        yield Trade(product, rng.choice(("buy", "sell")), price, size)


async def synthetic_trades(
    products: Sequence[str], rate_hz: float = 20.0, seed: Optional[int] = None
) -> AsyncIterator[Trade]:
    stream = synthetic_trade_stream(products, seed)
    rng = random.Random(seed)
    while True:
        await asyncio.sleep(rng.expovariate(rate_hz))
        yield next(stream)
