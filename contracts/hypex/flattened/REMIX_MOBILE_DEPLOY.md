# Deploy HYPEX from your phone (Remix + mobile wallet)

You don't need a desktop. Everything below works in a mobile browser with a mobile
wallet (MetaMask / Rabby / OKX) connected via WalletConnect.

> ⚠️ **Do this on TESTNET first (chain 998).** Only go to mainnet (999) once you've
> seen it work and you understand the trusted-LP design (`LP_WITHDRAWER` can pull the LP).

`SpcxdManager.flat.sol` is self-contained — it includes `SpcxdToken`, the `HyperCore`
library, and `SpcxdManager`. You only need that one file.

## 1. Add HyperEVM to your wallet

| Field | Mainnet | Testnet |
| --- | --- | --- |
| Chain ID | `999` | `998` |
| RPC | `https://rpc.hyperliquid.xyz/evm` | `https://rpc.hyperliquid-testnet.xyz/evm` |
| Symbol | `HYPE` | `HYPE` |

Fund the address with a little HYPE for gas (testnet: use a faucet).

## 2. Enable "big blocks" for your address

HyperEVM's small blocks cap at ~2M gas; deploying these contracts needs more. Flip your
deployer address to **big blocks** (e.g. via the toggle on `hyperevm-block.vercel.app`
or the `evmUserModify` action) before deploying. You can flip back after.

## 3. Open Remix and paste the file

1. Go to `remix.ethereum.org` in your phone browser.
2. Create a new file `SpcxdManager.flat.sol`, paste the contents of this folder's file.
3. **Solidity Compiler** tab → version `0.8.26`, enable **Optimizer** (200 runs) → Compile.

## 4. Connect your wallet

**Deploy & Run** tab → Environment → **WalletConnect** (or Injected Provider) → scan/approve
in your mobile wallet. Confirm the network shows chain `998` (or `999`).

## 5. Deploy the token

- Contract dropdown → **SpcxdToken**.
- Constructor args:
  - `name_`: `HYPEX`
  - `symbol_`: `HYPEX`
  - `supply_`: `10000000000000000000000`  (= 10,000 × 1e18)
  - `recipient`: **your wallet address** (receives the whole supply to airdrop + seed)
- **Deploy**, confirm in wallet, **copy the deployed token address**.

## 6. Deploy the manager

- Contract dropdown → **SpcxdManager**.
- Constructor args (mainnet values shown; the manager only stores them):
  - `token_`: the token address from step 5
  - `whype_`: `0x5555555555555555555555555555555555555555`
  - `nfpm_`: `0x6eDA206207c09e5428F281761DdC0D300851fBC8`
  - `router_`: `0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D`
  - `launchPoolFee_`: `10000`  (1% pool)
- **Deploy**, **copy the manager address**.

## 7. Wire them

- On the deployed **SpcxdToken** instance → call `setManager(<manager address>)`.

That's the deployment. The token now knows its manager, and the manager is excluded from
dividends automatically.

## 8. Distribute + seed (when ready)

- Airdrop HYLD holders 1:1 from your wallet (`token.transfer`).
- Transfer the LP allocation to the manager (`token.transfer(<manager>, amount)`).
- Call `manager.seed(sqrtPriceX96, tickLower, tickUpper)` once — the single-sided ticks
  are derived off-chain from your launch price (see the main README).

## 9. Run the keeper

Point `contracts/hypex/keeper` at the deployed `MANAGER_ADDRESS` and run it during market
hours (it needs a machine that stays online — a small VPS, not the phone).

---

**Reminder:** the only thing nobody can test without a funded, live deployment + an open
SPCXD market is the actual orderbook fill (sell HYPE→USDC, buy SPCXD). The contract logic
itself is covered by 12 unit tests + 2 mainnet-fork integration tests.
