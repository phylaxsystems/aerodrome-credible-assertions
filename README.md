# Aerodrome Credible Assertions

This repository contains Credible Layer example assertions for Aerodrome and Slipstream.

## Assertions

### Pool deposit and withdraw accounting

[`AerodromePoolLiquidityAccountingAssertion`](src/AerodromePoolLiquidityAccountingAssertion.sol) monitors Aerodrome V1 pool `mint(address)` and `burn(address)` calls.

It checks that:

- pool token balances, reserves, LP supply, and user LP balances move together on deposits;
- withdrawals burn the pool-held LP tokens and return exactly the token amounts implied by pool custody deltas;
- post-call reserves remain backed by the pool's external token balances.

This catches cases where a pool mints fewer LP tokens than it reports, releases fewer tokens than it accounts for, or leaves reserves stale after a deposit or withdrawal.

### Pool fees route to voted pool rewards

[`AerodromeV1GaugeFeeFlowAssertion`](src/AerodromeV1GaugeFeeFlowAssertion.sol) and [`AerodromeSlipstreamGaugeFeeFlowAssertion`](src/AerodromeSlipstreamGaugeFeeFlowAssertion.sol) monitor gauge `notifyRewardAmount(uint256)` calls.

They check that:

- the gauge is registered in the Aerodrome `Voter` as the gauge for its pool;
- the gauge maps back to the same pool and to its configured `FeesVotingReward`;
- fees claimed from V1 `PoolFees` or Slipstream `CLPool.gaugeFees()` either remain parked in gauge fee accounting or move to the voted pool's `FeesVotingReward`.

This catches diverted pool fees, stale or malicious Voter mappings, and fee-accounting updates that no longer reconcile with reward custody.

### Treasury Safe veAERO custody, delegation, and voting lockdown

[`AerodromeVeSafeAssertion`](src/AerodromeVeSafeAssertion.sol) protects an Aerodrome governance Safe from veAERO custody and voting-power side effects. It is armed against the Safe address and runs at the end of every Safe transaction.

It checks that the Safe transaction did not:

- emit a veAERO `Transfer`, `Approval`, or `ApprovalForAll` log;
- emit a veAERO `DelegateChanged` log;
- call any veAERO custody or voting-power selector (`approve`, `setApprovalForAll`, `transferFrom`, `safeTransferFrom`, `withdraw`, `merge`, `split`, `createManagedLockFor`, `createLock`/`createLockFor`, `depositFor`, `increaseAmount`, `increaseUnlockTime`, `delegate`/`delegateBySig`, `depositManaged`/`withdrawManaged`, `lockPermanent`/`unlockPermanent`);
- call any Aerodrome `Voter` voting selector (`vote`, `reset`, `poke`, `depositManaged`, `withdrawManaged`);
- cast a `ProtocolGovernor` or `EpochGovernor` vote keyed to the Safe address.

This catches both signer compromise and Safe-UI compromise: regardless of what calldata the signers approve, the transaction is invalidated on-chain if its execution would move the Safe's veNFT, change its voting-power delegation, vote a gauge, or cast a governor vote.

## Source Context

The assertions were written against the public Aerodrome contract shapes:

- Aerodrome V1 contracts, commit `1ba30815bba620f7e9faa34769ffd00c214c9b82`
- Aerodrome Slipstream contracts, commit `f8717faaae6e6717db3c8e3850149c01a79c0603`

The examples intentionally use small interfaces so they are easy to review and adapt to deployed pool or gauge addresses.

## Install

```sh
git clone https://github.com/phylaxsystems/aerodrome-credible-assertions.git
cd aerodrome-credible-assertions
git submodule update --init --recursive
```

## Build

```sh
forge build
```

## Run Tests

Credible assertion tests should be run with `pcl test`:

```sh
pcl test --match-contract AerodromePoolLiquidityAccountingAssertionTest
pcl test --match-contract AerodromeGaugeFeeFlowAssertionTest
pcl test --match-contract AerodromeVeSafeAssertionTest
```

The tests arm each assertion with `cl.assertion(...)`, execute the monitored Aerodrome-style call, and cover both honest behavior and a focused failing path.

Plain Foundry can compile the project and run non-Credible code, but the assertion trigger behavior is validated through the Phylax CLI.

## Documentation

- [Credible Layer documentation](https://docs.phylax.systems/)
- [Phylax Systems](https://www.phylax.systems/)
