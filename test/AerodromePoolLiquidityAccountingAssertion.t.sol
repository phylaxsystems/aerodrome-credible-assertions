// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CredibleTest} from "credible-std/CredibleTest.sol";

import {AerodromePoolLiquidityAccountingAssertion} from "../src/AerodromePoolLiquidityAccountingAssertion.sol";
import {MockAerodromeLiquidityPool, TestERC20} from "./mocks/MockAerodrome.sol";

/// @title AerodromePoolLiquidityAccountingAssertionTest
/// @notice cl.assertion-armed tests for pool mint and burn accounting.
contract AerodromePoolLiquidityAccountingAssertionTest is Test, CredibleTest {
    TestERC20 internal token0;
    TestERC20 internal token1;
    MockAerodromeLiquidityPool internal pool;

    address internal lp = address(0xBEEF);
    address internal recipient = address(0xCAFE);

    function setUp() public {
        token0 = new TestERC20("Token 0", "TK0");
        token1 = new TestERC20("Token 1", "TK1");
        pool = new MockAerodromeLiquidityPool(token0, token1);
        pool.seed(address(this), 1_000 ether, 1_000 ether, 1_000 ether);
    }

    function _arm(bytes4 fnSelector) internal {
        bytes memory createData =
            abi.encodePacked(type(AerodromePoolLiquidityAccountingAssertion).creationCode, abi.encode(address(pool)));
        cl.assertion(address(pool), createData, fnSelector);
    }

    /// @notice Honest deposits pass when token custody, reserves, and minted LP all agree.
    function testMintAccountingPasses() public {
        token0.mint(address(pool), 100 ether);
        token1.mint(address(pool), 100 ether);

        _arm(AerodromePoolLiquidityAccountingAssertion.assertMintAccounting.selector);
        pool.mint(lp);
    }

    /// @notice Deposits trip when the pool reports more minted LP than the recipient received.
    function testMintAccountingTripsOnUnderMintedLp() public {
        token0.mint(address(pool), 100 ether);
        token1.mint(address(pool), 100 ether);
        pool.setMode(MockAerodromeLiquidityPool.Mode.UnderMint);

        _arm(AerodromePoolLiquidityAccountingAssertion.assertMintAccounting.selector);
        vm.expectRevert(bytes("AerodromeLiquidity: minted LP mismatch"));
        pool.mint(lp);
    }

    /// @notice Honest withdrawals pass when burned LP and returned tokens match custody deltas.
    function testBurnAccountingPasses() public {
        pool.transfer(address(pool), 100 ether);

        _arm(AerodromePoolLiquidityAccountingAssertion.assertBurnAccounting.selector);
        pool.burn(recipient);
    }

    /// @notice Withdrawals trip when token custody decreases more than the recipient receives.
    function testBurnAccountingTripsOnShortTokenOutput() public {
        pool.transfer(address(pool), 100 ether);
        pool.setMode(MockAerodromeLiquidityPool.Mode.ShortBurnToken0);

        _arm(AerodromePoolLiquidityAccountingAssertion.assertBurnAccounting.selector);
        vm.expectRevert(bytes("AerodromeLiquidity: token0 burn output mismatch"));
        pool.burn(recipient);
    }
}
