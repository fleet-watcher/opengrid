# HYPEX — holders earn SPCXD from the pool fee

HYPEX is a token on [HyperEVM](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm) (chain `999`) whose holders earn **SPCXD** (tokenized SpaceX dStock) out of a **1% pool fee**. The fee is harvested, routed to USDC, bridged to HyperCore, spent buying SPCXD on the HyperCore orderbook, and delivered straight to each holder's own Core account when they claim. No team cut; the harvested reward funds can only become holder rewards.

> ⚠️ **Trusted LP (not locked).** A single hardcoded address, `LP_WITHDRAWER` (`0x5DdDEa56774f01fc9d207BBD7B7633596a2f4A0b`), can withdraw the LP position at any time via `manager.withdrawLiquidity(to)`. The owner/keeper cannot touch it. This is a deliberate, centralized design — **holders must trust that address not to pull liquidity.** The LP is *not* locked and this is *not* a rug-proof setup. Only the harvested reward funds (USDC/SPCXD on Core) have no withdraw path.

## Contracts

| File | Purpose |
| --- | --- |
| `src/SpcxdToken.sol` | The launch ERC20 (0% tax, 18 dec). Holds the SPCXD dividend accumulator; holders `claimSpcxd()` here. |
| `src/SpcxdManager.sol` | Custodies the LP (owner-withdrawable) and runs `harvest → buySpcxd → deliverToToken`. **No** USDC/SPCXD/HYPE reward withdraw path. |
| `src/HyperCore.sol` | EVM↔Core bridge library: CoreWriter orderbook orders, spot-send, spot-balance precompile, token system addresses. |
| `script/Deploy.s.sol` | Deploys token + manager and wires them. |
| `test/Hypex.t.sol` | 11 unit tests (all passing). |
| `keeper/` | TypeScript keeper bot (viem) that drives the pipeline during market hours. |

## How it works

**Dividend engine (magnified-dividend-per-share, O(1), no holder list).**
`shares[a]` is `a`'s balance (0 if excluded), `totalShares` the sum over non-excluded holders. `magSpcxdPerShare` accumulates SPCXD per share, scaled by `2^128`, denominated in SPCXD core 8-dec units. A per-account `correction` (int256) plus `withdrawnSpcxd` keep each holder's owed amount exact across transfers — every `_transfer` re-syncs `shares` for both sides and shifts their corrections, so accrued SPCXD is never lost and there is no enumeration.

- `notifyReward(uint64 amount)` (manager-only): if `totalShares == 0` the reward is **buffered** for the next call; otherwise `magSpcxdPerShare += (amount + buffered) * 2^128 / totalShares`. `amount` is in SPCXD core units and the SPCXD is already in the token's Core account.
- `withdrawableSpcxd(a) = (magSpcxdPerShare * shares[a] + correction[a]) / 2^128 − withdrawnSpcxd[a]`.
- `claimSpcxd()` spot-sends the owed SPCXD (core id `610`) to the caller's own Core account. Async — it arrives 1–2 blocks later. The caller can then sell it on the orderbook with no bridge.
- Exclusions (pool, manager, reserve, dead) hold 0 shares so they don't dilute real holders.

**The pipeline (manager).**
1. `seed(sqrtPriceX96, tickLower, tickUpper)` (owner, one-shot): creates the token/WHYPE 1% pool and mints the manager's full token balance as a single-sided (token-only) position. The LP NFT is held by the manager; the hardcoded `LP_WITHDRAWER` address can withdraw it any time via `withdrawLiquidity(to)` (the LP is **not** locked — see the trusted-LP note above).
2. `harvest()` (permissionless): `collect()` the accrued fees into the manager. Slippage-free, so anyone may pull fees in.
3. `swapAndBridge(minWhypeOut, minUsdcOut)` (owner/keeper): swap the token side → WHYPE → USDC and bridge USDC EVM→Core. The slippage floors come from a fresh quote (the keeper reads the post-harvest balances, quotes each leg, and applies its tolerance) so the swaps can't be sandwiched.
4. `buySpcxd(px1e8, sz1e8)` (owner/keeper): IOC ("market-style") buy on the SPCXD/USDC book (asset `10465 = 10000 + 465`) using the Core USDC balance. Owner/keeper-gated because it needs live market data and dStock trades only during the SpaceX session.
5. `deliverToToken()` (permissionless): spot-send the bought SPCXD from the manager's Core account to the token's Core account, then `notifyReward` to book it.

The collect and deliver legs are permissionless; only the slippage-sensitive swap and the market-priced buy are keeper-gated. None of them can move funds to the owner.

### Mainnet identifiers (chain 999)

- SPCXD core token id `610`; SPCXD spot order asset `10465`.
- USDC core id `0`; CoreWriter `0x33…33`; spot-balance precompile `0x…0801`; HYPE system address `0x22…22`.
- Token system address = `0x20` top byte + token index big-endian (USDC `0` → `0x2000…0000`).

### Verified HyperSwap V3 + token addresses (HyperEVM mainnet, chain 999)

All labels confirmed on [hyperevmscan.io](https://hyperevmscan.io). Baked in as
overridable defaults in `script/Deploy.s.sol` and `keeper/.env.example`.

| Contract | Address |
| --- | --- |
| WHYPE | `0x5555555555555555555555555555555555555555` |
| HyperSwap V3 SwapRouter (with deadline) | `0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D` |
| HyperSwap V3 NonfungiblePositionManager | `0x6eDA206207c09e5428F281761DdC0D300851fBC8` |
| HyperSwap V3 Quoter v2 (keeper) | `0x03A918028f22D9E1473B7959C927AD7425A45C7C` |
| **USD₮0** — EVM stable w/ the deep WHYPE V3 pool (0.05%) | `0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb` |
| WHYPE/USD₮0 V3 pool (0.05%) | `0x337b56d87a6185cd46af3ac2cdf03cbc37070c30` |

> **Stable caveat (mainnet-fork verified).** The harvest stable leg uses **USD₮0**, not
> USDC: Circle USDC (`0xb88339…`) has **no** WHYPE V3 pool, and the spec's USDC
> `0x6B9E…0A24` **reverts on every ERC20 call** (it is not a usable token). USD₮0 is the
> only EVM stable with deep WHYPE liquidity.
>
> ⚠️ **Open item (HyperCore side, not fork-verifiable).** `SpcxdManager` hardcodes
> `USDC_CORE_ID = 0` and the SPCXD/USDC spot asset `10465` — it assumes the buy is quoted
> in USDC on Core. If the harvested EVM stable is USD₮0, confirm whether (a) SPCXD is
> actually quoted in USD₮0 on Core (then update those constants) or (b) a USD₮0→USDC hop on
> Core is needed before the buy, and that the stable's bridge system index matches the core
> id. **Resolve this before mainnet.**

### Decimals

- HYPEX: 18 dec (EVM). USDC: 6 dec EVM / 8 dec Core. SPCXD: 8 dec Core (18 dec ERC20 unused).
- Orderbook px/sz and reward amounts: human × `1e8` (SPCXD core 8-dec units).

## Build & test

```bash
cd contracts/hypex
git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std
forge test -vv
```

```
Ran 11 tests for test/Hypex.t.sol:HypexTest
[PASS] test_buffer()           [PASS] test_buyOrderEncoding()  [PASS] test_claimSpotSend()
[PASS] test_deliver()          [PASS] test_distributionMath()  [PASS] test_managerGating()
[PASS] test_systemAddress()    [PASS] test_harvestPipeline()   [PASS] test_harvestSlippageAndGating()
[PASS] test_seedSingleSided()  [PASS] test_withdrawLiquidity()
11 passed; 0 failed
```

The Core-side actions (buy/deliver/claim) are checked against a CoreWriter recorder
that asserts the exact action-byte encoding; the EVM-side pipeline (collect → swap →
bridge, with the slippage floor enforced) is checked against mock NFPM/router/ERC20s.

### Mainnet-fork integration (`test/HypexFork.t.sol`)

Run against real HyperSwap V3 mainnet state (no funds, no keys):

```bash
forge test --fork-url https://rpc.hyperliquid.xyz/evm --match-contract HypexFork -vv
```

- `test_fork_seedSingleSided` — deploys and calls `seed()` against the **real NFPM**:
  creates a real token/WHYPE 1% pool, mints a real V3 position, deposits the full
  10,000-token supply single-sided (0 left over). ✅
- `test_fork_swapWhypeToStableAndBridge` — swaps WHYPE→USD₮0 through the **real router
  and WHYPE/USD₮0 0.05% pool**, then runs the bridge transfer (e.g. 0.1 WHYPE → ~6.6
  USD₮0). ✅

Without `--fork-url` these no-op (the addresses have no code), so plain `forge test`
stays at the 11 unit tests. **Note:** the fork can only exercise the EVM side; HyperCore
actions (buy/spot-send/precompiles) are system-level and not present in fork state.

## Keeper bot

`keeper/` is a standalone TypeScript bot (viem + the Hyperliquid Info API) that runs
the pipeline during market hours:

```bash
cd contracts/hypex/keeper
pnpm install --ignore-workspace
cp .env.example .env   # fill in PRIVATE_KEY, MANAGER_ADDRESS, QUOTER_ADDRESS …
pnpm start             # one pass; set LOOP_SECONDS=300 to repeat
```

Each pass: `harvest()` → read balances, quote each swap leg and derive slippage floors,
`swapAndBridge(min,min)` → read `coreUsdc()` → price an IOC buy off the live SPCXD/USDC
book (cross the spread + buffer, size = USDC/px) → `buySpcxd(px,sz)` → poll `coreSpcxd()`
for the fill → `deliverToToken()`. Set the keeper wallet on-chain with `manager.setKeeper(addr)`
— it can run `swapAndBridge`/`buySpcxd` but has **no** fund-withdraw power.

## Deploy

```bash
export PRIVATE_KEY=0x...
export WHYPE=0x5555555555555555555555555555555555555555
export USDC=0x...            # EVM USDC (6 dec)
export NFPM=0x...            # Hyperswap NonfungiblePositionManager
export SWAP_ROUTER=0x...     # Hyperswap SwapRouter
export TOTAL_SUPPLY=10000
forge script script/Deploy.s.sol --rpc-url hyperevm --broadcast
```

After deploy: airdrop HYLD holders 1:1 from the deployer balance (snapshot ≈ 50 holders, ~4,940 HYPEX), transfer the remaining LP allocation to the manager, then call `manager.seed(...)` once.

> **HyperEVM big blocks:** contract deploys often exceed the 2M small-block gas limit. Flip your deployer to big blocks before deploying, then back.

> **CoreWriter caller rule (validated on mainnet):** CoreWriter actions only execute when the sender is a *contract*, not an EOA — which is exactly why the token and manager run them. The token-bridge transfer to a system address works from either.

## Trust model

- **No team cut on the reward path** — 100% of the *harvested* fee reaches holders as SPCXD; the manager has no path to send USDC/SPCXD/HYPE rewards to the owner.
- **LP is withdrawable by one hardcoded address (NOT locked)** — only `LP_WITHDRAWER` (`0x5DdDEa…4A0b`) can call `withdrawLiquidity(to)` and pull the LP position at any time; the owner/keeper cannot. This is a centralized, trusted design: **holders must trust that address not to remove liquidity.** It is *not* rug-proof. If you want a trustless setup instead, remove `withdrawLiquidity` (genuine lock) or gate it behind a public timelock.
- **0% transfer tax. Pro-rata, claim-based, O(1)** — no holder list.

## Honest constraints

- **dStock market hours** — SPCXD only trades during the SpaceX session; off-hours, fees queue as USDC on Core until the next run. "More SpaceX over time," not "instant per trade."
- **Async + keeper** — fills and bridges settle 1–2 blocks later; a keeper triggers `buySpcxd`.
- **Slippage** — EVM swaps enforce keeper-supplied `minWhypeOut`/`minUsdcOut` floors (quoted fresh, tolerance `SLIPPAGE_BPS`) and the IOC buy crosses the book by the same tolerance. Large batches still move the book — size accordingly.
- **Min order size** — small fees batch up between runs.

This is a reference implementation and has **not been audited**. Test on HyperEVM testnet (chain `998`) before putting real funds behind it.
