// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SpcxdToken} from "../src/SpcxdToken.sol";
import {SpcxdManager, INonfungiblePositionManager, ISwapRouter} from "../src/SpcxdManager.sol";

/// Deploys the HYPEX token + manager and wires them together.
///
/// Usage:
///   export PRIVATE_KEY=0x...
///   export WHYPE=0x5555555555555555555555555555555555555555
///   export USDC=0x...               # EVM USDC (6 dec)
///   export NFPM=0x...               # Hyperswap NonfungiblePositionManager
///   export SWAP_ROUTER=0x...        # Hyperswap SwapRouter
///   export TOTAL_SUPPLY=10000       # whole tokens (×1e18 applied below)
///   export LAUNCH_POOL_FEE=10000    # 1% pool
///   export WHYPE_USDC_FEE=500       # WHYPE/USDC fee tier
///   forge script script/Deploy.s.sol --rpc-url hyperevm --broadcast
///
/// After deploy: airdrop HYLD holders 1:1 from the deployer balance, transfer the
/// LP allocation to the manager, then call `manager.seed(...)` once.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address whype = vm.envAddress("WHYPE");
        address usdc = vm.envAddress("USDC");
        address nfpm = vm.envAddress("NFPM");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        uint256 supplyWhole = vm.envOr("TOTAL_SUPPLY", uint256(10_000));
        uint24 launchPoolFee = uint24(vm.envOr("LAUNCH_POOL_FEE", uint256(10_000)));
        uint24 whypeUsdcFee = uint24(vm.envOr("WHYPE_USDC_FEE", uint256(500)));

        vm.startBroadcast(pk);

        SpcxdToken token = new SpcxdToken("HYPEX", "HYPEX", supplyWhole * 1e18, deployer);
        SpcxdManager manager = new SpcxdManager(
            token,
            whype,
            usdc,
            INonfungiblePositionManager(nfpm),
            ISwapRouter(swapRouter),
            launchPoolFee,
            whypeUsdcFee
        );
        token.setManager(address(manager));

        vm.stopBroadcast();

        console.log("SpcxdToken   :", address(token));
        console.log("SpcxdManager :", address(manager));
    }
}
