// Thin client for the Hyperliquid Info API (the SPCXD/USDC orderbook).
// Docs: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint

export interface BookLevel {
  px: string; // price, human units
  sz: string; // size, human units
  n: number;
}

export interface L2Book {
  // levels[0] = bids (desc), levels[1] = asks (asc)
  levels: [BookLevel[], BookLevel[]];
}

/**
 * Fetch the L2 orderbook for a spot coin. Spot pairs are addressed as `@{index}`
 * (e.g. `@465` for the SPCXD/USDC pair, index 465).
 */
export async function fetchL2Book(apiUrl: string, coin: string): Promise<L2Book> {
  const res = await fetch(`${apiUrl}/info`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: "l2Book", coin }),
  });
  if (!res.ok) throw new Error(`l2Book ${coin}: HTTP ${res.status}`);
  const book = (await res.json()) as L2Book;
  if (!book.levels || book.levels.length < 2) throw new Error(`l2Book ${coin}: malformed response`);
  return book;
}

export interface BuyQuote {
  /** Limit price to send, human × 1e8 (uint64). Crosses the spread by `slippageBps`. */
  px1e8: bigint;
  /** Order size to send, human × 1e8 (uint64), rounded to `szDecimals`. */
  sz1e8: bigint;
  /** Best ask used, for logging. */
  bestAsk: number;
}

/**
 * Price an IOC market-style buy of `usdcHuman` worth of SPCXD against the live book.
 * Walks the ask side to a price that fills the notional, then pads by `slippageBps`
 * so the IOC actually crosses. Size is the USDC notional divided by that price,
 * shaved by `slippageBps` and floored to `szDecimals`.
 */
export function priceBuy(
  book: L2Book,
  usdcHuman: number,
  slippageBps: number,
  szDecimals: number,
): BuyQuote | null {
  const asks = book.levels[1];
  if (!asks || asks.length === 0) return null; // market closed / empty book

  // Walk asks until the cumulative notional covers what we want to spend.
  let remaining = usdcHuman;
  let clearingPx = Number(asks[0].px);
  for (const lvl of asks) {
    const px = Number(lvl.px);
    const sz = Number(lvl.sz);
    clearingPx = px;
    const levelNotional = px * sz;
    if (levelNotional >= remaining) break;
    remaining -= levelNotional;
  }

  const slip = slippageBps / 10_000;
  const limitPx = clearingPx * (1 + slip);
  const sizeHuman = (usdcHuman / limitPx) * (1 - slip);

  const szScale = 10 ** szDecimals;
  const sizeRounded = Math.floor(sizeHuman * szScale) / szScale;
  if (sizeRounded <= 0) return null;

  const px1e8 = BigInt(Math.round(limitPx * 1e8));
  const sz1e8 = BigInt(Math.round(sizeRounded * 1e8));
  if (px1e8 <= 0n || sz1e8 <= 0n) return null;
  if (px1e8 > MAX_U64 || sz1e8 > MAX_U64) throw new Error("px/sz overflow uint64");

  return { px1e8, sz1e8, bestAsk: Number(asks[0].px) };
}

/**
 * Price an IOC market-style SELL of `sizeHuman` base tokens for the quote (e.g. HYPE→USDC).
 * Crosses the bid side: limit price = best bid shaved DOWN by `slippageBps` so the IOC fills.
 */
export function priceSell(
  book: L2Book,
  sizeHuman: number,
  slippageBps: number,
  szDecimals: number,
): BuyQuote | null {
  const bids = book.levels[0];
  if (!bids || bids.length === 0) return null;

  const slip = slippageBps / 10_000;
  const limitPx = Number(bids[0].px) * (1 - slip);

  const szScale = 10 ** szDecimals;
  const sizeRounded = Math.floor(sizeHuman * szScale) / szScale;
  if (sizeRounded <= 0 || limitPx <= 0) return null;

  const px1e8 = BigInt(Math.round(limitPx * 1e8));
  const sz1e8 = BigInt(Math.round(sizeRounded * 1e8));
  if (px1e8 <= 0n || sz1e8 <= 0n) return null;
  if (px1e8 > MAX_U64 || sz1e8 > MAX_U64) throw new Error("px/sz overflow uint64");

  return { px1e8, sz1e8, bestAsk: Number(bids[0].px) };
}

const MAX_U64 = (1n << 64n) - 1n;
