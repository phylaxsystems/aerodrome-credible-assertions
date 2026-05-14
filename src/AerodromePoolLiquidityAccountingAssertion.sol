// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";

/// @notice Minimal ERC20 balance reader used for pool token custody checks.
interface IERC20BalanceReaderLike {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Minimal Aerodrome V1 pool surface used by liquidity-accounting checks.
interface IAerodromePoolLiquidityLike {
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function metadata()
        external
        view
        returns (
            uint256 dec0,
            uint256 dec1,
            uint256 reserve0,
            uint256 reserve1,
            bool stable,
            address token0,
            address token1
        );
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title AerodromePoolLiquidityAccountingAssertion
/// @author Phylax Systems
/// @notice Protects Aerodrome V1 pool deposit and withdrawal accounting.
/// - Confirms `mint()` LP output matches recipient LP balance changes.
/// - Confirms `burn()` token outputs match pool custody and recipient token changes.
/// - Confirms post-call reserves remain aligned with external token balances.
contract AerodromePoolLiquidityAccountingAssertion is Assertion {
    struct PoolSnapshot {
        uint256 reserve0;
        uint256 reserve1;
        address token0;
        address token1;
        uint256 poolBalance0;
        uint256 poolBalance1;
        uint256 totalSupply;
        uint256 recipientLpBalance;
        uint256 recipientToken0Balance;
        uint256 recipientToken1Balance;
        uint256 poolLpBalance;
    }

    address internal immutable POOL;

    constructor(address pool_) {
        POOL = pool_;
        _registerReshiramSpec();
    }

    function _viewFailureMessage() internal pure override returns (string memory) {
        return "AerodromeLiquidity: fork read failed";
    }

    /// @notice Registers Aerodrome V1 liquidity deposit and withdrawal surfaces.
    function triggers() external view override {
        registerFnCallTrigger(this.assertMintAccounting.selector, IAerodromePoolLiquidityLike.mint.selector);
        registerFnCallTrigger(this.assertBurnAccounting.selector, IAerodromePoolLiquidityLike.burn.selector);
    }

    /// @notice Checks `mint()` keeps token custody, reserves, supply, and recipient LP accounting aligned.
    /// @dev A failure means a successful deposit minted a different LP amount than reported, or
    ///      reserves no longer match the pool's external token balances after the deposit.
    function assertMintAccounting() external view {
        PhEvm.TriggerContext memory ctx = ph.context();
        address recipient = _decodeSingleAddress(ph.callinputAt(ctx.callStart));

        PoolSnapshot memory pre = _snapshotAt(_preCall(ctx.callStart), recipient);
        PoolSnapshot memory post = _snapshotAt(_postCall(ctx.callEnd), recipient);
        uint256 mintedLiquidity = abi.decode(ph.callOutputAt(ctx.callStart), (uint256));

        require(pre.poolBalance0 >= pre.reserve0, "AerodromeLiquidity: token0 pending deposit underflow");
        require(pre.poolBalance1 >= pre.reserve1, "AerodromeLiquidity: token1 pending deposit underflow");
        require(post.reserve0 >= pre.reserve0, "AerodromeLiquidity: token0 reserve decreased on mint");
        require(post.reserve1 >= pre.reserve1, "AerodromeLiquidity: token1 reserve decreased on mint");
        require(
            post.reserve0 - pre.reserve0 == pre.poolBalance0 - pre.reserve0,
            "AerodromeLiquidity: token0 deposit/reserve mismatch"
        );
        require(
            post.reserve1 - pre.reserve1 == pre.poolBalance1 - pre.reserve1,
            "AerodromeLiquidity: token1 deposit/reserve mismatch"
        );
        require(
            post.recipientLpBalance - pre.recipientLpBalance == mintedLiquidity,
            "AerodromeLiquidity: minted LP mismatch"
        );
        require(post.totalSupply >= pre.totalSupply + mintedLiquidity, "AerodromeLiquidity: totalSupply under-minted");
        require(post.poolBalance0 == post.reserve0, "AerodromeLiquidity: token0 reserves underbacked");
        require(post.poolBalance1 == post.reserve1, "AerodromeLiquidity: token1 reserves underbacked");
    }

    /// @notice Checks `burn()` keeps token custody, reserves, supply, and recipient withdrawals aligned.
    /// @dev A failure means a successful withdrawal returned token amounts that do not match pool
    ///      custody deltas, failed to burn the pool-held LP tokens, or left reserve accounting stale.
    function assertBurnAccounting() external view {
        PhEvm.TriggerContext memory ctx = ph.context();
        address recipient = _decodeSingleAddress(ph.callinputAt(ctx.callStart));

        PoolSnapshot memory pre = _snapshotAt(_preCall(ctx.callStart), recipient);
        PoolSnapshot memory post = _snapshotAt(_postCall(ctx.callEnd), recipient);
        (uint256 amount0, uint256 amount1) = abi.decode(ph.callOutputAt(ctx.callStart), (uint256, uint256));

        require(pre.poolLpBalance > 0, "AerodromeLiquidity: no pool LP burned");
        require(post.poolLpBalance == 0, "AerodromeLiquidity: pool LP not fully burned");
        require(pre.totalSupply - post.totalSupply == pre.poolLpBalance, "AerodromeLiquidity: LP burn mismatch");
        require(pre.poolBalance0 >= post.poolBalance0, "AerodromeLiquidity: token0 custody increased on burn");
        require(pre.poolBalance1 >= post.poolBalance1, "AerodromeLiquidity: token1 custody increased on burn");
        require(pre.poolBalance0 - post.poolBalance0 == amount0, "AerodromeLiquidity: token0 burn output mismatch");
        require(pre.poolBalance1 - post.poolBalance1 == amount1, "AerodromeLiquidity: token1 burn output mismatch");
        require(
            post.recipientToken0Balance - pre.recipientToken0Balance == amount0,
            "AerodromeLiquidity: token0 recipient mismatch"
        );
        require(
            post.recipientToken1Balance - pre.recipientToken1Balance == amount1,
            "AerodromeLiquidity: token1 recipient mismatch"
        );
        require(post.poolBalance0 == post.reserve0, "AerodromeLiquidity: token0 reserves underbacked");
        require(post.poolBalance1 == post.reserve1, "AerodromeLiquidity: token1 reserves underbacked");
    }

    function _snapshotAt(PhEvm.ForkId memory fork, address recipient)
        internal
        view
        returns (PoolSnapshot memory snapshot)
    {
        (,, snapshot.reserve0, snapshot.reserve1,, snapshot.token0, snapshot.token1) = abi.decode(
            _viewAt(POOL, abi.encodeCall(IAerodromePoolLiquidityLike.metadata, ()), fork),
            (uint256, uint256, uint256, uint256, bool, address, address)
        );
        snapshot.poolBalance0 = _balanceAt(snapshot.token0, POOL, fork);
        snapshot.poolBalance1 = _balanceAt(snapshot.token1, POOL, fork);
        snapshot.totalSupply = _readUintAt(POOL, abi.encodeCall(IAerodromePoolLiquidityLike.totalSupply, ()), fork);
        snapshot.recipientLpBalance =
            _readUintAt(POOL, abi.encodeCall(IAerodromePoolLiquidityLike.balanceOf, (recipient)), fork);
        snapshot.recipientToken0Balance = _balanceAt(snapshot.token0, recipient, fork);
        snapshot.recipientToken1Balance = _balanceAt(snapshot.token1, recipient, fork);
        snapshot.poolLpBalance = _readUintAt(POOL, abi.encodeCall(IAerodromePoolLiquidityLike.balanceOf, (POOL)), fork);
    }

    function _balanceAt(address token, address account, PhEvm.ForkId memory fork) internal view returns (uint256) {
        return _readUintAt(token, abi.encodeCall(IERC20BalanceReaderLike.balanceOf, (account)), fork);
    }

    function _decodeSingleAddress(bytes memory input) internal pure returns (address value) {
        require(input.length >= 36, "AerodromeLiquidity: malformed calldata");
        assembly {
            value := mload(add(input, 36))
        }
    }

    function _registerReshiramSpec() private {
        // The current local runner expects a mutable CALL for spec recording.
        address specRecorder = address(uint160(uint256(keccak256("SpecRecorder"))));
        (bool ok,) = specRecorder.call(abi.encodeWithSignature("registerAssertionSpec(uint8)", uint8(1)));
        require(ok, "AerodromeLiquidity: spec registration failed");
    }
}
