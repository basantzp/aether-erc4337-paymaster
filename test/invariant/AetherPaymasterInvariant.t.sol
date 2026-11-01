// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AetherPaymaster} from "../../src/AetherPaymaster.sol";
import {IAetherPaymaster} from "../../src/interfaces/IAetherPaymaster.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";
import {MockAccount} from "../mocks/MockAccount.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {AetherHandler} from "./handlers/AetherHandler.sol";

contract AetherPaymasterInvariantTest is StdInvariant, Test {
    AetherPaymaster public paymaster;
    MockEntryPoint public entryPoint;
    MockAccount public account;

    MockERC20 public usdc;
    MockERC20 public dai;
    MockAggregatorV3 public oracle;

    AetherHandler public handler;
    address public owner = makeAddr("owner");

    function setUp() public {
        vm.warp(100_000);

        entryPoint = new MockEntryPoint();
        address userAccountOwner = vm.addr(0xCC33);
        account = new MockAccount(userAccountOwner, address(entryPoint));

        vm.prank(owner);
        paymaster = new AetherPaymaster(entryPoint, owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        oracle = new MockAggregatorV3(8, "ETH / USD", 2500e8);

        vm.prank(owner);
        paymaster.setTokenConfig(address(usdc), address(oracle), 6, 8, 3600, 500, true);

        vm.prank(owner);
        paymaster.setTokenConfig(address(dai), address(oracle), 18, 8, 3600, 300, true);

        handler = new AetherHandler(paymaster, entryPoint, account, usdc, dai, oracle, owner);

        targetContract(address(handler));
    }

    /// @notice Invariant 1: Paymaster token balance must always be at least total collected fees minus withdrawn fees
    function invariant_TokenSolvencyUSDC() public view {
        uint256 paymasterBalance = usdc.balanceOf(address(paymaster));
        uint256 expectedBalance =
            handler.ghost_feesCollected(address(usdc)) - handler.ghost_tokensWithdrawn(address(usdc));
        assertGe(paymasterBalance, expectedBalance, "USDC solvency violated");
    }

    /// @notice Invariant 2: Paymaster token balance must always be at least total collected fees minus withdrawn fees (DAI)
    function invariant_TokenSolvencyDAI() public view {
        uint256 paymasterBalance = dai.balanceOf(address(paymaster));
        uint256 expectedBalance =
            handler.ghost_feesCollected(address(dai)) - handler.ghost_tokensWithdrawn(address(dai));
        assertGe(paymasterBalance, expectedBalance, "DAI solvency violated");
    }

    /// @notice Invariant 3: Native deposit in EntryPoint matches deposit accounting exactly
    function invariant_NativeDepositIntegrity() public view {
        uint256 actualDeposit = paymaster.getDeposit();
        uint256 expectedDeposit =
            handler.ghost_nativeDeposited() - handler.ghost_nativeSpent() - handler.ghost_nativeWithdrawn();
        assertEq(actualDeposit, expectedDeposit, "Native deposit integrity violated");
    }

    /// @notice Invariant 4: Total collected fees recorded on paymaster match handler ghost fees
    function invariant_FeesCollectedMonotonic() public view {
        assertEq(paymaster.totalGasCollected(address(usdc)), handler.ghost_feesCollected(address(usdc)));
        assertEq(paymaster.totalGasCollected(address(dai)), handler.ghost_feesCollected(address(dai)));
    }
}
