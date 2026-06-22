// Minimal ABIs for the keeper. Kept hand-written so the keeper has no build-time
// dependency on the Foundry artifacts.

export const managerAbi = [
  { type: "function", name: "harvest", stateMutability: "nonpayable", inputs: [], outputs: [
    { name: "collected0", type: "uint256" }, { name: "collected1", type: "uint256" } ] },
  { type: "function", name: "swapAndBridge", stateMutability: "nonpayable",
    inputs: [{ name: "minWhypeOut", type: "uint256" }, { name: "minUsdcOut", type: "uint256" }], outputs: [] },
  { type: "function", name: "buySpcxd", stateMutability: "nonpayable",
    inputs: [{ name: "px1e8", type: "uint64" }, { name: "sz1e8", type: "uint64" }], outputs: [] },
  { type: "function", name: "deliverToToken", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "function", name: "coreUsdc", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "coreSpcxd", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "token", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "whype", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "usdc", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "launchPoolFee", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  { type: "function", name: "whypeUsdcFee", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
] as const;

export const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view",
    inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

// Uniswap-V3 QuoterV2 (Hyperswap). quoteExactInputSingle is non-view but is read
// via eth_call; viem's simulateContract returns the decoded result.
export const quoterAbi = [
  { type: "function", name: "quoteExactInputSingle", stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [
      { name: "tokenIn", type: "address" },
      { name: "tokenOut", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "fee", type: "uint24" },
      { name: "sqrtPriceLimitX96", type: "uint160" },
    ] }],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "sqrtPriceX96After", type: "uint160" },
      { name: "initializedTicksCrossed", type: "uint32" },
      { name: "gasEstimate", type: "uint256" },
    ] },
] as const;
