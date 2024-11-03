// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

uint24 constant POOL_FEE = 0;

uint160 constant ANGSTROM_HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;

/*
@note Some hook flags are set but they aren't implemented in Angstrom.

Hooks that are implemented:
- beforeAddLiquidity()
- beforeRemoveLiquidity()

Hooks used to prevent direct interacting with Uniswap V4 pools:
- beforeSwap()
- beforeInitialize()

BEFORE_SWAP_FLAG and BEFORE_INITIALIZE_FLAG are set to prevent users from calling PoolManager.initialize()
and PoolManager.swap() directly in Uniswap V4. Attempting to do so would revert as the hook isn't implemented.

Whereas if the Angstrom contract calls initialize() or swap(), the noSelfCall modifier avoids calling the
hook and allows the call to pass.
*/