// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HyperCore} from "../src/HyperCore.sol";
import {SpcxdToken} from "../src/SpcxdToken.sol";
import {SpcxdManager, INonfungiblePositionManager, ISwapRouter} from "../src/SpcxdManager.sol";

/// Records every CoreWriter action so tests can assert the exact wire encoding.
/// Etched at the system address 0x33…33.
contract MockCoreWriter {
    bytes public lastData;

    function sendRawAction(bytes calldata data) external {
        lastData = data;
    }
}

contract HypexTest is Test {
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    uint64 internal constant SPCXD = 610;
    uint64 internal constant USDC_CORE = 0;
    uint32 internal constant SPCXD_ASSET = 10465;

    SpcxdToken token;
    SpcxdManager manager;

    address whype = makeAddr("whype");
    address usdc = makeAddr("usdc");
    address nfpm = makeAddr("nfpm");
    address swapRouter = makeAddr("router");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // 10,000 HYPEX, full supply to this test contract (acts as deployer/treasury).
        token = new SpcxdToken("HYPEX", "HYPEX", 10_000e18, address(this));
        manager = new SpcxdManager(
            token,
            whype,
            usdc,
            INonfungiblePositionManager(nfpm),
            ISwapRouter(swapRouter),
            10_000, // 1% launch pool
            500 // WHYPE/USDC tier
        );
        token.setManager(address(manager));

        // Install the CoreWriter recorder at the system address.
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
    }

    function _coreData() internal view returns (bytes memory) {
        return MockCoreWriter(CORE_WRITER).lastData();
    }

    function _mockSpot(address user, uint64 core, uint64 total) internal {
        vm.mockCall(
            SPOT_BALANCE, abi.encode(user, core), abi.encode(total, uint64(0), uint64(0))
        );
    }

    // 1. Distribution math: rewards split pro-rata across non-excluded holders.
    function test_distributionMath() public {
        token.transfer(alice, 3_000e18);
        token.transfer(bob, 1_000e18);
        // This contract keeps 6,000; totalShares = 10,000.

        vm.prank(address(manager));
        token.notifyReward(1_000e8); // 1,000 SPCXD (core 8-dec)

        assertEq(token.totalShares(), 10_000e18);
        // Per-share division truncates, so each holder rounds DOWN by ≤1 core unit
        // (the dust stays as backing — distribution never over-pays). 1 unit = 1e-8 SPCXD.
        assertApproxEqAbs(token.withdrawableSpcxd(alice), 300e8, 1); // 30%
        assertApproxEqAbs(token.withdrawableSpcxd(bob), 100e8, 1); // 10%
        assertApproxEqAbs(token.withdrawableSpcxd(address(this)), 600e8, 1); // 60%

        // Owed survives a transfer: Alice moves all her tokens but keeps her accrued SPCXD.
        uint256 aliceOwed = token.withdrawableSpcxd(alice);
        uint256 bobOwed = token.withdrawableSpcxd(bob);
        vm.prank(alice);
        token.transfer(bob, 3_000e18);
        assertEq(token.withdrawableSpcxd(alice), aliceOwed);
        assertEq(token.withdrawableSpcxd(bob), bobOwed);
    }

    // 2. Claim spot-sends SPCXD (core id 610) to the caller's own Core account.
    function test_claimSpotSend() public {
        token.transfer(alice, 5_000e18);
        vm.prank(address(manager));
        token.notifyReward(500e8);

        uint256 owed = token.withdrawableSpcxd(alice); // ~250 SPCXD (rounds down ≤1 unit)
        assertApproxEqAbs(owed, 250e8, 1);

        vm.prank(alice);
        token.claimSpcxd();

        // The spot-send carries exactly what was owed, to Alice's own Core account.
        bytes memory expected = abi.encodePacked(
            uint8(1), uint8(0), uint8(0), uint8(HyperCore.ACTION_SPOT_SEND),
            abi.encode(alice, SPCXD, uint64(owed))
        );
        assertEq(keccak256(_coreData()), keccak256(expected));
        assertEq(token.withdrawnSpcxd(alice), owed);
        assertEq(token.withdrawableSpcxd(alice), 0);
    }

    // 3. Buy emits an IOC limit order on the SPCXD/USDC book with the right encoding.
    function test_buyOrderEncoding() public {
        _mockSpot(address(manager), USDC_CORE, 1_000e8); // USDC sitting on Core

        manager.buySpcxd(123e8, 5e8); // px 123, size 5 (human ×1e8)

        bytes memory expected = abi.encodePacked(
            uint8(1), uint8(0), uint8(0), uint8(HyperCore.ACTION_LIMIT_ORDER),
            abi.encode(SPCXD_ASSET, true, uint64(123e8), uint64(5e8), false, uint8(3), uint128(0))
        );
        assertEq(keccak256(_coreData()), keccak256(expected));
    }

    // 4. Deliver spot-sends bought SPCXD to the token and books it as a reward.
    function test_deliver() public {
        token.transfer(alice, 10_000e18); // all shares to alice
        _mockSpot(address(manager), SPCXD, 800e8); // 800 SPCXD bought, sitting on Core

        manager.deliverToToken();

        // spot-send manager Core → token Core, full bought amount
        bytes memory expected = abi.encodePacked(
            uint8(1), uint8(0), uint8(0), uint8(HyperCore.ACTION_SPOT_SEND),
            abi.encode(address(token), SPCXD, uint64(800e8))
        );
        assertEq(keccak256(_coreData()), keccak256(expected));
        // booked for holders (alice holds all shares; rounds down ≤1 unit)
        assertApproxEqAbs(token.withdrawableSpcxd(alice), 800e8, 1);
    }

    // 5. Buffer: rewards booked with no shares roll into the next distribution.
    function test_buffer() public {
        // Park the whole supply in the manager (excluded) → totalShares == 0.
        token.transfer(address(manager), 10_000e18);
        assertEq(token.totalShares(), 0);

        vm.prank(address(manager));
        token.notifyReward(100e8); // buffered, nobody to pay
        assertEq(token.buffered(), 100e8);
        assertEq(token.magSpcxdPerShare(), 0);

        // Give Alice all the shares, then distribute again.
        vm.prank(address(manager));
        token.transfer(alice, 10_000e18);

        vm.prank(address(manager));
        token.notifyReward(50e8); // 50 new + 100 buffered

        assertEq(token.buffered(), 0);
        assertApproxEqAbs(token.withdrawableSpcxd(alice), 150e8, 1);
    }

    // 6. Only the registered manager can book rewards.
    function test_managerGating() public {
        vm.prank(alice);
        vm.expectRevert("not manager");
        token.notifyReward(1e8);

        // The owner is not the manager either.
        vm.expectRevert("not manager");
        token.notifyReward(1e8);
    }

    // 7. System address packs the token index big-endian under the 0x20 top byte.
    function test_systemAddress() public pure {
        assertEq(HyperCore.systemAddress(0), 0x2000000000000000000000000000000000000000);
        // 610 = 0x262
        assertEq(HyperCore.systemAddress(610), 0x2000000000000000000000000000000000000262);
    }
}
