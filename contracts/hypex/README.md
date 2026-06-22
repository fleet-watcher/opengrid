# HYPEX — holders earn SPCXD from the pool fee

HYPEX is a token on [HyperEVM](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm) (chain `999`) whose holders earn **SPCXD** (tokenized SpaceX dStock) out of a **1% pool fee**. The fee is harvested, converted to HYPE and bridged to HyperCore, sold for USDC and spent buying SPCXD on the HyperCore orderbooks, and delivered straight to each holder's own Core account when they claim. No team cut; the funds in flight can only become holder rewards.

> ⚠️ **Trusted LP (not locked).** A single hardcoded address, `LP_WITHDRAWER` (`0x5DdDEa56774f01fc9d207BBD7B7633596a2f4A0b`), can withdraw the LP position at any time via `manager.withdrawLiquidity(to)`. The owner/keeper cannot touch it. This is a deliberate, centralized design — **holders must trust that address not to pull liquidity.** The LP is *not* locked and this is *not* a rug-proof setup. The HYPE/USDC/SPCXD in flight on Core have no withdraw path.

## Contracts

| File | Purpose |
| --- | --- |
| `src/SpcxdToken.sol` | The launch ERC20 (0% tax, 18 dec). Holds the SPCXD dividend accumulator; holders `claimSpcxd()` here. |
| `src/SpcxdManager.sol` | Custodies the LP (withdrawable only by `LP_WITHDRAWER`) and runs `harvest → bridgeToCore → sellHypeForUsdc → buySpcxd → deliverToToken`. No reward-funds withdraw path. |
| `src/HyperCore.sol` | EVM↔Core bridge library: CoreWriter orderbook orders, spot-send, spot-balance precompile, token system addresses. |
| `script/Deploy.s.sol` | Deploys token + manager and wires them. |
| `test/Hypex.t.sol` | 12 unit tests (all passing). |
| `test/HypexFork.t.sol` | 2 mainnet-fork integration tests (real HyperSwap V3 + WHYPE). |
| `keeper/` | TypeScript keeper bot (viem) that drives the pipeline during market hours. |

## How it works

**Dividend engine (magnified-dividend-per-share, O(1), no holder list).**
`shares[a]` is `a`'s balance (0 if excluded), `totalShares` the sum over non-excluded holders. `magSpcxdPerShare` accumulates SPCXD per share, scaled by `2^128`, denominated in SPCXD core 8-dec units. A per-account `correction` (int256) plus `withdrawnSpcxd` keep each holder's owed amount exact across transfers — every `_transfer` re-syncs `shares` for both sides and shifts their corrections, so accrued SPCXD is never lost and there is no enumeration.

- `notifyReward(uint64 amount)` (manager-only): if `totalShares == 0` the reward is **buffered** for the next call; otherwise `magSpcxdPerShare += (amount + buffered) * 2^128 / totalShares`. `amount` is in SPCXD core units and the SPCXD is already in the token's Core account.
- `withdrawableSpcxd(a) = (magSpcxdPerShare * shares[a] + correction[a]) / 2^128 − withdrawnSpcxd[a]`.
- `claimSpcxd()` spot-sends the owed SPCXD (core id `610`) to the caller's own Core account. Async — it arrives 1–2 blocks later. The caller can then sell it on the orderbook with no bridge.
- Exclusions (pool, manager, reserve, dead) hold 0 shares so they don't dilute real holders.

**The pipeline (manager) — the HYPE route.**
Token-0 USDC on HyperCore is *system-managed*: its EVM ERC20 (`0x6b9e…0A24`) reverts for non-system callers (`"Caller is not the system address"`) and has no DEX pool, so USDC cannot be swapped/bridged on the EVM. Instead USDC is acquired by **selling on the Core orderbook** — using only mainnet-validated primitives (HYPE bridge + orderbook).

1. `seed(sqrtPriceX96, tickLower, tickUpper)` (owner, one-shot): creates the token/WHYPE 1% pool and mints the manager's full token balance as a single-sided (token-only) position. The LP NFT is held by the manager; only `LP_WITHDRAWER` can withdraw it (the LP is **not** locked — see the trusted-LP note).
2. `harvest()` (permissionless): `collect()` the accrued fees into the manager. Slippage-free, so anyone may pull fees in.
3. `bridgeToCore(minWhypeOut)` (owner/keeper): swap the launch-token side → WHYPE (slippage floor from a fresh quote), unwrap **all WHYPE → native HYPE**, then value-transfer the HYPE to the HYPE system address (`0x22…22`) to credit the manager's Core account.
4. `sellHypeForUsdc(px1e8, sz1e8)` (owner/keeper): IOC sell on the **HYPE/USDC** book (asset `10107`) — turns the bridged HYPE into Core USDC.
5. `buySpcxd(px1e8, sz1e8)` (owner/keeper): IOC buy on the **SPCXD/USDC** book (asset `10465`) with that USDC.
6. `deliverToToken()` (permissionless): spot-send the bought SPCXD from the manager's Core account to the token's Core account, then `notifyReward` to book it.

`harvest`/`deliver` are permissionless; the slippage-sensitive bridge and the two market-priced orders are keeper-gated. None of them can move funds to the owner.

### Mainnet identifiers (chain 999)

- SPCXD core token id `610`, SPCXD/USDC spot asset `10465`.
- HYPE core token id `150`, HYPE/USDC spot asset `10107`.
- USDC core id `0`; CoreWriter `0x33…33`; spot-balance precompile `0x…0801`; HYPE system address `0x22…22`.

### Verified HyperSwap V3 addresses (HyperEVM mainnet, chain 999)

Labels confirmed on [hyperevmscan.io](https://hyperevmscan.io); token/pair facts from the Hyperliquid `spotMeta` API. Baked in as overridable defaults in `script/Deploy.s.sol` and `keeper/.env.example`.

| Contract | Address |
| --- | --- |
| WHYPE | `0x5555555555555555555555555555555555555555` |
| HyperSwap V3 SwapRouter (with deadline) | `0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D` |
| HyperSwap V3 NonfungiblePositionManager | `0x6eDA206207c09e5428F281761DdC0D300851fBC8` |
| HyperSwap V3 Quoter v2 (keeper) | `0x03A918028f22D9E1473B7959C927AD7425A45C7C` |

> **Why the HYPE route (verified on a mainnet fork + spotMeta):** the Hyperliquid API
> confirms SPCXD (token 610) trades only as **SPCXD/USDC** (pair 465) and USDC is token 0.
> But token-0 USDC's EVM contract (`0x6b9e…0A24`) is system-only — `transfer`/`balanceOf`
> revert for normal callers and it has no DEX pool, so you cannot obtain USDC by an EVM
> swap/bridge. The pipeline therefore bridges **HYPE** (validated primitive) and sells it
> for USDC on the **HYPE/USDC** book (pair 107) before buying SPCXD.

### Decimals

- HYPEX: 18 dec (EVM). HYPE: 18 dec EVM / 8 dec Core. USDC: 8 dec Core. SPCXD: 8 dec Core (18 dec ERC20 unused).
- Orderbook px/sz and reward amounts: human × `1e8`.

## Build & test

```bash
cd contracts/hypex
git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std
forge test -vv
```

```
Ran 12 tests for test/Hypex.t.sol:HypexTest
[PASS] test_buffer()           [PASS] test_buyOrderEncoding()  [PASS] test_sellHypeOrderEncoding()
[PASS] test_claimSpotSend()    [PASS] test_deliver()          [PASS] test_distributionMath()
[PASS] test_managerGating()    [PASS] test_systemAddress()    [PASS] test_harvestPipeline()
[PASS] test_harvestSlippageAndGating()  [PASS] test_seedSingleSided()  [PASS] test_withdrawLiquidity()
12 passed; 0 failed
```

The Core-side actions (sell/buy/deliver/claim) are checked against a CoreWriter recorder
that asserts the exact action-byte encoding; the EVM-side pipeline (collect → swap → unwrap
→ bridge, with the slippage floor enforced) is checked against mock NFPM/router/ERC20s.

### Mainnet-fork integration (`test/HypexFork.t.sol`)

Run against real HyperSwap V3 + WHYPE mainnet state (no funds, no keys):

```bash
forge test --fork-url https://rpc.hyperliquid.xyz/evm --match-contract HypexFork -vv
```

- `test_fork_seedSingleSided` — `seed()` against the **real NFPM**: creates a real
  token/WHYPE 1% pool, mints a real V3 position, deposits the full 10,000-token supply
  single-sided (0 left over). ✅
- `test_fork_bridgeWhypeToCore` — unwraps real WHYPE→HYPE and value-transfers it to the
  HYPE system address (0.1 WHYPE → 0.1 HYPE bridged). ✅

Without `--fork-url` these no-op (the addresses have no code), so plain `forge test`
stays at the 12 unit tests. **Note:** the fork can only exercise the EVM side; the Core
orderbook orders (sell/buy/spot-send/precompiles) are system-level and not in fork state.

## Keeper bot

`keeper/` is a standalone TypeScript bot (viem + the Hyperliquid Info API):

```bash
cd contracts/hypex/keeper
pnpm install --ignore-workspace
cp .env.example .env   # fill in PRIVATE_KEY, MANAGER_ADDRESS …
pnpm start             # one pass; set LOOP_SECONDS=300 to repeat
```

Each pass: `harvest()` → quote the launch-token→WHYPE leg for a floor → `bridgeToCore(min)`
→ poll `coreHype()` → price an IOC sell off the live HYPE/USDC book → `sellHypeForUsdc(px,sz)`
→ poll `coreUsdc()` → price an IOC buy off the SPCXD/USDC book (size = USDC/px) →
`buySpcxd(px,sz)` → poll `coreSpcxd()` → `deliverToToken()`. Set the keeper wallet with
`manager.setKeeper(addr)` — it runs the pipeline but has **no** fund-withdraw power.

## Deploy

```bash
export PRIVATE_KEY=0x...        # your funded deployer key (runs on YOUR machine)
# optional overrides: WHYPE, NFPM, SWAP_ROUTER, TOTAL_SUPPLY, LAUNCH_POOL_FEE
forge script script/Deploy.s.sol --rpc-url hyperevm_testnet --broadcast   # testnet first (chain 998)
```

The verified HyperSwap V3 addresses are baked-in defaults, so only `PRIVATE_KEY` is required.
After deploy: airdrop HYLD holders 1:1 from the deployer balance (snapshot ≈ 50 holders, ~4,940 HYPEX), transfer the remaining LP allocation to the manager, then call `manager.seed(...)` once.

> **HyperEVM big blocks:** contract deploys often exceed the 2M small-block gas limit. Flip your deployer to big blocks before deploying, then back.

> **CoreWriter caller rule (validated on mainnet):** CoreWriter actions only execute when the sender is a *contract*, not an EOA — which is exactly why the manager runs them. The HYPE bridge (value transfer to the system address) works from either.

## Trust model

- **No team cut on the reward path** — 100% of the *harvested* fee reaches holders as SPCXD; the manager has no path to send HYPE/USDC/SPCXD rewards to the owner.
- **LP is withdrawable by one hardcoded address (NOT locked)** — only `LP_WITHDRAWER` (`0x5DdDEa…4A0b`) can call `withdrawLiquidity(to)` and pull the LP at any time; the owner/keeper cannot. This is a centralized, trusted design: **holders must trust that address not to remove liquidity.** It is *not* rug-proof. For a trustless setup, remove `withdrawLiquidity` (genuine lock) or gate it behind a public timelock.
- **0% transfer tax. Pro-rata, claim-based, O(1)** — no holder list.

## Honest constraints

- **dStock market hours** — SPCXD only trades during the SpaceX session; off-hours the value queues as HYPE/USDC on Core until the next run. "More SpaceX over time," not "instant per trade."
- **Async + keeper** — fills and bridges settle 1–2 blocks later; a keeper triggers the orders.
- **Slippage** — the launch-token→WHYPE swap enforces a keeper-supplied `minWhypeOut` floor (quoted fresh, tolerance `SLIPPAGE_BPS`); the IOC sell and buy cross their books by the same tolerance. Large batches move the books — size accordingly.
- **Min order size** — small fees batch up between runs.

This is a reference implementation and has **not been audited**. Test on HyperEVM testnet (chain `998`) before putting real funds behind it.
