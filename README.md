# Understanding Angstrom

## Relevant knowledge

Uniswap V3:

- Primers on Uniswap V3 math [1](https://blog.uniswap.org/uniswap-v3-math-primer) and [2](https://blog.uniswap.org/uniswap-v3-math-primer-2).
- [Uniswap V3 Whitepaper](https://app.uniswap.org/whitepaper-v3.pdf) - Specifically, focus on section 6 on the implementation of ticks and fee accounting. The implementation of fee accounting in Angstrom is extremely similar.

Uniswap V4:

- [Uniswap V4 Whitepaper](https://github.com/Uniswap/v4-core/blob/main/docs/whitepaper/whitepaper-v4.pdf)
- [Uniswap V4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- There doesn't seem to be much good explanations on Uniswap V4 as of now, but mainly focus on:
  - How [hooks](https://docs.uniswap.org/contracts/v4/concepts/hooks) work when performing actions
  - [Delta accounting](https://docs.uniswap.org/contracts/v4/concepts/flash-accounting)
- Of course, nothing beats just looking through the code itself in [v4-core](https://github.com/Uniswap/v4-core/tree/main).

## Navigating this repository

This repository contains my notes for the Spearbit audit for commit [`1073823`](https://github.com/SorellaLabs/angstrom/tree/10738235a2ff54dc171537e8617134cb644bf485).

You can view all the notes in [this commit](https://github.com/MiloTruck/sorella-notes/commit/ff6cb2449afc1e60c367de53186036002c41f9d9), or use the [Inline Bookmarks](https://marketplace.visualstudio.com/items?itemName=tintinweb.vscode-inline-bookmarks) extension:

- `@audit-issue` tags are issues found during the audit.
- `@audit` tags are interesting leads worth looking into.
- `@note` tags are information about the codebase.

## Areas to look into

These are areas that (in my opinion) are the most likely to have bugs. They also happen to be the most complicated parts of the codebase.

### Delta accounting

Similar to Uniswap V4, Angstrom maintains [a transient mapping of deltas](https://github.com/MiloTruck/sorella-notes/blob/main/src/modules/Settlement.sol#L23) that [need to be resolved](https://github.com/MiloTruck/sorella-notes/blob/main/src/modules/Settlement.sol#L100-L102) after a transaction is executed. It's worth looking into whether:

- Deltas are updated correctly with each action performed in the code.
- Delta accounting in Angstrom works with the delta accounting in Uniswap V4.
- Delta accounting can be bypassed to steal funds.

### Fee accounting

The implementation for fees is similar Uniswap V3/V4, but modified. Focus on [`PoolUpdates.sol`](https://github.com/MiloTruck/sorella-notes/blob/main/src/modules/PoolUpdates.sol) and [`GrowthOutsideUpdater.sol`](https://github.com/MiloTruck/sorella-notes/blob/main/src/modules/GrowthOutsideUpdater.sol) to see if reward distribution has any issues (e.g. rounding issues, edge cases regarding ticks).

It's also worth noting that a large part of the fee implementation [was refactored](https://github.com/SorellaLabs/angstrom/commit/26db3bbd0c49f1581486de5f3976844a9b6a82ca) to mitigate issues found in the Spearbit audit.

### Assembly

Although there shouldn't be any obvious implementation errors, a lingering concern we have is dirty bytes. More specifically:

1. When a variable with a type smaller than 32 bytes is used in assembly, the upper bytes could be dirty if it was downcasted or directly assigned in assembly from a larger type. Look for variables smaller than 32 bytes used in assembly, and trace backwards to reason if its upper bytes could be dirty at that point in time.
2. Usage of scratch space or free memory without writing to them before, as these regions [are not zeroed out](https://docs.soliditylang.org/en/latest/internals/layout_in_memory.html#layout-in-memory).

Examples of such issues found previously:

1. [Pair.sol#L131-L153](https://github.com/MiloTruck/sorella-notes/blob/main/src/types/Pair.sol#L131-L153)
2. [HookBuffer.sol#L79-L89](https://github.com/MiloTruck/sorella-notes/blob/main/src/types/HookBuffer.sol#L79-L89)

