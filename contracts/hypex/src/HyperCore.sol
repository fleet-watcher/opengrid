// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev CoreWriter sink — the only way an EVM contract pushes actions onto HyperCore.
///      Lives at the fixed system address 0x33...33 on HyperEVM mainnet (chain 999).
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// @title HyperCore — EVM↔Core bridge primitives for HyperEVM
/// @notice Thin, allocation-free wrappers around the HyperCore system contracts:
///         the CoreWriter action sink, the spot-balance precompile, and the
///         token bridge system addresses. Every helper here has been exercised
///         against mainnet primitives (EVM→Core bridge, CoreWriter limit order
///         that filled, CoreWriter spot-send, precompile read).
///
/// @dev Action wire format is `0x01` (encoding version) + a 3-byte big-endian
///      action id + `abi.encode(params)`. Prices and sizes are human × 1e8.
///
///      CRITICAL (validated on mainnet): CoreWriter actions only execute when the
///      `msg.sender` is a contract, never an EOA. The token bridge (a plain
///      transfer to a system address) works for both EOAs and contracts.
library HyperCore {
    // --------------------------------------------------------------- system addresses

    /// @dev CoreWriter action sink.
    ICoreWriter internal constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    /// @dev Read-only precompile returning a user's spot balance for a core token.
    address internal constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;

    // --------------------------------------------------------------- action ids

    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_SPOT_SEND = 6;

    /// @dev Time-in-force: 1 = ALO, 2 = GTC, 3 = IOC. We use IOC for "market-style" fills.
    uint8 internal constant TIF_IOC = 3;

    // --------------------------------------------------------------- actions

    /// @notice Place a spot limit order on a HyperCore orderbook.
    /// @param asset   spot-pair order asset = 10000 + pairIndex
    /// @param isBuy   true to buy the base asset with quote
    /// @param px1e8   limit price, human × 1e8
    /// @param sz1e8   size, human × 1e8
    /// @dev IOC + reduceOnly=false + cloid=0. Caller must be a contract.
    function limitOrder(uint32 asset, bool isBuy, uint64 px1e8, uint64 sz1e8) internal {
        bytes memory params = abi.encode(asset, isBuy, px1e8, sz1e8, false, TIF_IOC, uint128(0));
        _sendAction(ACTION_LIMIT_ORDER, params);
    }

    /// @notice Send a core spot token from this contract's Core account to `dest`'s Core account.
    /// @param dest   recipient Core account (EVM address == Core address)
    /// @param token  core token id
    /// @param amount amount in core units (token's `weiDecimals`)
    /// @dev Async — the transfer settles 1–2 blocks later. Caller must be a contract.
    function spotSend(address dest, uint64 token, uint64 amount) internal {
        bytes memory params = abi.encode(dest, token, amount);
        _sendAction(ACTION_SPOT_SEND, params);
    }

    // --------------------------------------------------------------- reads

    /// @notice Read `user`'s spot balance for `token` from the precompile.
    /// @return total balance in core units (the field callers care about)
    /// @return hold amount reserved by resting orders
    /// @return entryNtl cost basis notional
    function spotBalance(address user, uint64 token)
        internal
        view
        returns (uint64 total, uint64 hold, uint64 entryNtl)
    {
        (bool ok, bytes memory ret) = SPOT_BALANCE_PRECOMPILE.staticcall(abi.encode(user, token));
        require(ok, "spot balance read failed");
        (total, hold, entryNtl) = abi.decode(ret, (uint64, uint64, uint64));
    }

    // --------------------------------------------------------------- bridge

    /// @notice System address that bridges a core token to/from the EVM.
    /// @dev Top byte 0x20, the rest is the token index big-endian. Index 0 (USDC)
    ///      => 0x2000…0000. A plain ERC20 `transfer` to this address credits the
    ///      sender's Core account; a Core→EVM withdrawal sends back out of it.
    function systemAddress(uint64 index) internal pure returns (address) {
        return address((uint160(0x20) << 152) | uint160(index));
    }

    // --------------------------------------------------------------- internal

    function _sendAction(uint24 actionId, bytes memory params) private {
        // 0x01 version byte + 3-byte big-endian action id + encoded params
        bytes memory data = abi.encodePacked(
            uint8(1), uint8(actionId >> 16), uint8(actionId >> 8), uint8(actionId), params
        );
        CORE_WRITER.sendRawAction(data);
    }
}
