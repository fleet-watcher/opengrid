/**
 * HYPEX keeper bot — drives the reward pipeline during dStock market hours:
 *
 *   harvest()              collect the 1% fees                 (permissionless)
 *   swapAndBridge(min,min) token → WHYPE → USDC → bridge Core  (keeper, slippage-bounded)
 *   buySpcxd(px, sz)       IOC buy on the SPCXD/USDC book       (keeper, priced off the book)
 *   deliverToToken()       book the bought SPCXD for holders    (permissionless)
 *
 * Slippage floors for the EVM swaps come from a fresh QuoterV2 quote, so the swaps
 * cannot be sandwiched. The buy price comes from the live Hyperliquid orderbook.
 *
 * Run once:        pnpm start
 * Run on a loop:   LOOP_SECONDS=300 pnpm start
 */
import {
  createPublicClient, createWalletClient, http, getAddress, formatUnits, type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { managerAbi, erc20Abi, quoterAbi } from "./abi.js";
import { fetchL2Book, priceBuy, priceSell } from "./hyperliquid.js";

// ----------------------------------------------------------------- config

function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined) throw new Error(`missing env ${name}`);
  return v;
}

const RPC_URL = env("RPC_URL", "https://rpc.hyperliquid.xyz/evm");
const HL_API = env("HL_API_URL", "https://api.hyperliquid.xyz");
const MANAGER = getAddress(env("MANAGER_ADDRESS"));
const QUOTER = getAddress(env("QUOTER_ADDRESS"));
const SPCXD_BOOK_COIN = env("SPCXD_BOOK_COIN", "@465"); // SPCXD/USDC spot pair index 465
const HYPE_BOOK_COIN = env("HYPE_BOOK_COIN", "@107"); // HYPE/USDC spot pair index 107
const SLIPPAGE_BPS = Number(env("SLIPPAGE_BPS", "100")); // 1%
const SPCXD_SZ_DECIMALS = Number(env("SPCXD_SZ_DECIMALS", "2"));
const HYPE_SZ_DECIMALS = Number(env("HYPE_SZ_DECIMALS", "2"));
const MIN_HYPE_CORE = BigInt(env("MIN_HYPE_CORE", "100000000")); // 1 HYPE (8-dec core) floor
const MIN_USDC_CORE = BigInt(env("MIN_USDC_CORE", "100000000")); // 1 USDC (8-dec core) floor
const FILL_POLL_MS = Number(env("FILL_POLL_MS", "3000"));
const FILL_POLL_TRIES = Number(env("FILL_POLL_TRIES", "20"));
const LOOP_SECONDS = Number(process.env.LOOP_SECONDS ?? "0");

const account = privateKeyToAccount(env("PRIVATE_KEY") as `0x${string}`);

const chain = {
  id: 999,
  name: "HyperEVM",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
} as const;

const pub = createPublicClient({ chain, transport: http(RPC_URL) });
const wallet = createWalletClient({ account, chain, transport: http(RPC_URL) });

const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);

// ----------------------------------------------------------------- helpers

async function send(fn: "harvest" | "deliverToToken"): Promise<void>;
async function send(fn: "bridgeToCore", args: [bigint]): Promise<void>;
async function send(fn: "sellHypeForUsdc" | "buySpcxd", args: [bigint, bigint]): Promise<void>;
async function send(fn: string, args: readonly unknown[] = []): Promise<void> {
  const { request } = await pub.simulateContract({
    account, address: MANAGER, abi: managerAbi, functionName: fn as never, args: args as never,
  });
  const hash = await wallet.writeContract(request);
  log(`  ${fn} tx`, hash);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${fn} reverted (${hash})`);
}

function read<T>(fn: string, args: readonly unknown[] = []): Promise<T> {
  return pub.readContract({ address: MANAGER, abi: managerAbi, functionName: fn as never, args: args as never }) as Promise<T>;
}

async function quote(quoter: Address, tokenIn: Address, tokenOut: Address, amountIn: bigint, fee: number): Promise<bigint> {
  const { result } = await pub.simulateContract({
    address: quoter, abi: quoterAbi, functionName: "quoteExactInputSingle",
    args: [{ tokenIn, tokenOut, amountIn, fee, sqrtPriceLimitX96: 0n }],
  });
  return (result as readonly bigint[])[0];
}

const applySlippage = (x: bigint) => (x * BigInt(10_000 - SLIPPAGE_BPS)) / 10_000n;

// ----------------------------------------------------------------- pipeline

async function pollCore(fn: "coreHype" | "coreUsdc" | "coreSpcxd", min: bigint): Promise<bigint> {
  let v = 0n;
  for (let i = 0; i < FILL_POLL_TRIES; i++) {
    await sleep(FILL_POLL_MS);
    v = await read<bigint>(fn);
    if (v >= min) break;
  }
  return v;
}

async function runOnce(): Promise<void> {
  const [tokenAddr, whype, launchFee] = await Promise.all([
    read<Address>("token"), read<Address>("whype"), read<number>("launchPoolFee"),
  ]);

  // 1. Collect fees (permissionless, no slippage).
  log("harvest: collecting fees…");
  await send("harvest");

  // 2. Quote the launch-token→WHYPE leg for a slippage floor, then unwrap+bridge HYPE to Core.
  const tokenBal = await pub.readContract({ address: tokenAddr, abi: erc20Abi, functionName: "balanceOf", args: [MANAGER] });
  const whypeBal = await pub.readContract({ address: whype, abi: erc20Abi, functionName: "balanceOf", args: [MANAGER] });
  let minWhypeOut = 0n;
  if (tokenBal > 0n) minWhypeOut = applySlippage(await quote(QUOTER, tokenAddr, whype, tokenBal, launchFee));
  if (tokenBal > 0n || whypeBal > 0n) {
    log(`bridgeToCore: minWhypeOut=${minWhypeOut}`);
    await send("bridgeToCore", [minWhypeOut]);
  } else {
    log("bridgeToCore: nothing to bridge");
  }

  // 3. Sell the Core HYPE for USDC on the HYPE/USDC book.
  const coreHype = await pollCore("coreHype", MIN_HYPE_CORE);
  log(`coreHype = ${formatUnits(coreHype, 8)} HYPE`);
  if (coreHype >= MIN_HYPE_CORE) {
    const hypeBook = await fetchL2Book(HL_API, HYPE_BOOK_COIN);
    const sell = priceSell(hypeBook, Number(formatUnits(coreHype, 8)), SLIPPAGE_BPS, HYPE_SZ_DECIMALS);
    if (sell) {
      log(`sellHypeForUsdc: px=${formatUnits(sell.px1e8, 8)} sz=${formatUnits(sell.sz1e8, 8)}`);
      await send("sellHypeForUsdc", [sell.px1e8, sell.sz1e8]);
    } else {
      log("no HYPE/USDC bids — HYPE stays queued");
    }
  }

  // 4. Buy SPCXD with the resulting Core USDC.
  const coreUsdc = await pollCore("coreUsdc", MIN_USDC_CORE);
  log(`coreUsdc = ${formatUnits(coreUsdc, 8)} USDC`);
  if (coreUsdc < MIN_USDC_CORE) {
    log("below MIN_USDC_CORE — leaving it queued for the next run");
    return;
  }
  const spcxdBook = await fetchL2Book(HL_API, SPCXD_BOOK_COIN);
  const buy = priceBuy(spcxdBook, Number(formatUnits(coreUsdc, 8)), SLIPPAGE_BPS, SPCXD_SZ_DECIMALS);
  if (!buy) {
    log("no SPCXD asks (market closed?) — USDC stays queued");
    return;
  }
  log(`buySpcxd: px=${formatUnits(buy.px1e8, 8)} sz=${formatUnits(buy.sz1e8, 8)} (bestAsk=${buy.bestAsk})`);
  await send("buySpcxd", [buy.px1e8, buy.sz1e8]);

  // 5. Wait for the SPCXD fill to settle, then deliver to holders.
  const bought = await pollCore("coreSpcxd", 1n);
  if (bought === 0n) {
    log("fill not seen yet — deliverToToken() can be called once it settles");
    return;
  }
  log(`coreSpcxd = ${formatUnits(bought, 8)} SPCXD — delivering`);
  await send("deliverToToken");
  log("delivered: holders can now claimSpcxd()");
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  log(`keeper up: manager=${MANAGER} account=${account.address} loop=${LOOP_SECONDS || "off"}`);
  for (;;) {
    try {
      await runOnce();
    } catch (e) {
      log("run error:", e instanceof Error ? e.message : e);
    }
    if (LOOP_SECONDS <= 0) break;
    await sleep(LOOP_SECONDS * 1000);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
