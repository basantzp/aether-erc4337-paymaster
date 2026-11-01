// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AetherPaymaster} from "../src/AetherPaymaster.sol";
import {IAetherPaymaster} from "../src/interfaces/IAetherPaymaster.sol";
import {IPaymaster, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MockEntryPoint} from "./mocks/MockEntryPoint.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract AetherPaymasterTest is Test {
    AetherPaymaster public paymaster;
    MockEntryPoint public entryPoint;
    MockERC20 public usdc;
    MockAggregatorV3 public ethUsdOracle;

    address public owner = makeAddr("owner");
    address public newOwner = makeAddr("newOwner");
    address public verifyingSigner = makeAddr("verifyingSigner");
    address public user = makeAddr("user");
    address public treasury = makeAddr("treasury");

    function setUp() public {
        vm.deal(owner, 100 ether);
        vm.deal(user, 10 ether);

        entryPoint = new MockEntryPoint();

        vm.prank(owner);
        paymaster = new AetherPaymaster(entryPoint, owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        ethUsdOracle = new MockAggregatorV3(8, "ETH / USD", 2500e8); // $2,500
    }

    // --- Constructor & Initialization ---

    function test_Constructor_Success() public view {
        assertEq(address(paymaster.entryPoint()), address(entryPoint));
        assertEq(paymaster.owner(), owner);
        assertFalse(paymaster.paused());
    }

    function test_Constructor_RevertZeroAddress() public {
        // Zero initial owner reverts with OwnableInvalidOwner(address(0))
        vm.expectRevert();
        new AetherPaymaster(entryPoint, address(0));

        // Zero entryPoint address reverts with InvalidAddress
        vm.expectRevert(IAetherPaymaster.InvalidAddress.selector);
        new AetherPaymaster(MockEntryPoint(payable(address(0))), owner);
    }

    // --- Two-Step Ownership ---

    function test_TwoStepOwnership_TransferAndAccept() public {
        vm.prank(owner);
        paymaster.transferOwnership(newOwner);

        // Still owned by owner until accepted
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.pendingOwner(), newOwner);

        // Non-pending owner cannot accept
        vm.prank(user);
        vm.expectRevert();
        paymaster.acceptOwnership();

        // Pending owner accepts
        vm.prank(newOwner);
        paymaster.acceptOwnership();

        assertEq(paymaster.owner(), newOwner);
        assertEq(paymaster.pendingOwner(), address(0));
    }

    function test_TwoStepOwnership_OnlyOwnerCanTransfer() public {
        vm.prank(user);
        vm.expectRevert();
        paymaster.transferOwnership(newOwner);
    }

    // --- Pause Controls ---

    function test_Pause_Unpause() public {
        vm.prank(owner);
        paymaster.pause();
        assertTrue(paymaster.paused());

        vm.prank(owner);
        paymaster.unpause();
        assertFalse(paymaster.paused());
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        paymaster.pause();
    }

    // --- Verifying Signers ---

    function test_SetVerifyingSigner_Success() public {
        vm.prank(owner);
        paymaster.setVerifyingSigner(verifyingSigner, true);
        assertTrue(paymaster.isVerifyingSigner(verifyingSigner));

        vm.prank(owner);
        paymaster.setVerifyingSigner(verifyingSigner, false);
        assertFalse(paymaster.isVerifyingSigner(verifyingSigner));
    }

    function test_SetVerifyingSigner_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAetherPaymaster.InvalidAddress.selector);
        paymaster.setVerifyingSigner(address(0), true);
    }

    function test_SetVerifyingSigner_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        paymaster.setVerifyingSigner(verifyingSigner, true);
    }

    // --- Token Config Management ---

    function test_SetTokenConfig_Success() public {
        vm.prank(owner);
        paymaster.setTokenConfig(
            address(usdc),
            address(ethUsdOracle),
            6,
            8,
            3600,
            500, // 5%
            true
        );

        IAetherPaymaster.TokenConfig memory config = paymaster.getTokenConfig(address(usdc));
        assertTrue(config.isSupported);
        assertEq(config.oracle, address(ethUsdOracle));
        assertEq(config.tokenDecimals, 6);
        assertEq(config.oracleDecimals, 8);
        assertEq(config.maxOracleAge, 3600);
        assertEq(config.markupBps, 500);
        assertTrue(config.isPriceTokenPerEth);
    }

    function test_SetTokenConfig_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAetherPaymaster.InvalidAddress.selector);
        paymaster.setTokenConfig(address(0), address(ethUsdOracle), 6, 8, 3600, 500, true);

        vm.prank(owner);
        vm.expectRevert(IAetherPaymaster.InvalidAddress.selector);
        paymaster.setTokenConfig(address(usdc), address(0), 6, 8, 3600, 500, true);
    }

    function test_SetTokenConfig_RevertInvalidMarkup() public {
        vm.prank(owner);
        // Exceeds 50% (5000 bps)
        vm.expectRevert(abi.encodeWithSelector(IAetherPaymaster.InvalidMarkup.selector, 5001));
        paymaster.setTokenConfig(address(usdc), address(ethUsdOracle), 6, 8, 3600, 5001, true);
    }

    function test_SetTokenConfig_RevertInvalidDecimals() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAetherPaymaster.InvalidDecimals.selector, 0));
        paymaster.setTokenConfig(address(usdc), address(ethUsdOracle), 0, 8, 3600, 500, true);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAetherPaymaster.InvalidDecimals.selector, 19));
        paymaster.setTokenConfig(address(usdc), address(ethUsdOracle), 19, 8, 3600, 500, true);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAetherPaymaster.InvalidDecimals.selector, 0));
        paymaster.setTokenConfig(address(usdc), address(ethUsdOracle), 6, 0, 3600, 500, true);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAetherPaymaster.InvalidDecimals.selector, 20));
        paymaster.setTokenConfig(address(usdc), address(ethUsdOracle), 6, 20, 3600, 500, true);
    }

    function test_SetTokenConfig_RevertInvalidMaxOracleAge() public {
        vm.prank(owner);
        vm.expectRevert(IAetherPaymaster.InvalidMaxOracleAge.selector);
        paymaster.setTokenConfig(address(usdc), address(ethUsdOracle), 6, 8, 0, 500, true);
    }

    function test_RemoveToken_Success() public {
        vm.prank(owner);
        paymaster.setTokenConfig(address(usdc), address(ethUsdOracle), 6, 8, 3600, 500, true);

        vm.prank(owner);
        paymaster.removeToken(address(usdc));

        IAetherPaymaster.TokenConfig memory config = paymaster.getTokenConfig(address(usdc));
        assertFalse(config.isSupported);
    }

    // --- EntryPoint Deposit & Stake ---

    function test_Deposit_Success() public {
        vm.prank(owner);
        paymaster.deposit{value: 5 ether}();

        assertEq(paymaster.getDeposit(), 5 ether);
        assertEq(entryPoint.balanceOf(address(paymaster)), 5 ether);
    }

    function test_Deposit_ReceiveFallback() public {
        (bool success,) = address(paymaster).call{value: 3 ether}("");
        assertTrue(success);

        assertEq(paymaster.getDeposit(), 3 ether);
    }

    function test_Deposit_RevertZeroValue() public {
        vm.prank(owner);
        vm.expectRevert(IAetherPaymaster.ZeroDeposit.selector);
        paymaster.deposit{value: 0}();
    }

    function test_WithdrawDeposit_Success() public {
        vm.prank(owner);
        paymaster.deposit{value: 5 ether}();

        uint256 treasuryBefore = treasury.balance;
        vm.prank(owner);
        paymaster.withdrawDeposit(payable(treasury), 2 ether);

        assertEq(treasury.balance, treasuryBefore + 2 ether);
        assertEq(paymaster.getDeposit(), 3 ether);
    }

    function test_WithdrawDeposit_RevertZeroAddress() public {
        vm.prank(owner);
        paymaster.deposit{value: 5 ether}();

        vm.prank(owner);
        vm.expectRevert(IAetherPaymaster.InvalidAddress.selector);
        paymaster.withdrawDeposit(payable(address(0)), 1 ether);
    }

    function test_Stake_Lifecycle() public {
        vm.prank(owner);
        paymaster.addStake{value: 2 ether}(1 days);

        (, bool staked, uint112 stake, uint32 delay,) = entryPoint.deposits(address(paymaster));
        assertTrue(staked);
        assertEq(stake, 2 ether);
        assertEq(delay, 1 days);

        vm.prank(owner);
        paymaster.unlockStake();

        // Warp time past unstake delay
        vm.warp(block.timestamp + 1 days + 1);

        uint256 treasuryBefore = treasury.balance;
        vm.expectEmit(true, false, false, true);
        emit IAetherPaymaster.StakeWithdrawn(treasury, 2 ether);
        vm.prank(owner);
        paymaster.withdrawStake(payable(treasury));

        assertEq(treasury.balance, treasuryBefore + 2 ether);
    }

    function test_WithdrawToken_Success() public {
        usdc.mint(address(paymaster), 1000e6);

        vm.prank(owner);
        paymaster.withdrawToken(usdc, treasury, 600e6);

        assertEq(usdc.balanceOf(treasury), 600e6);
        assertEq(usdc.balanceOf(address(paymaster)), 400e6);
    }

    function test_WithdrawNative_Success() public {
        vm.deal(address(paymaster), 1 ether);

        uint256 treasuryBefore = treasury.balance;
        vm.prank(owner);
        paymaster.withdrawNative(payable(treasury), 1 ether);

        assertEq(treasury.balance, treasuryBefore + 1 ether);
    }

    // --- Caller Access Controls ---

    function test_ValidatePaymasterUserOp_OnlyEntryPoint() public {
        PackedUserOperation memory userOp;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAetherPaymaster.UnauthorizedCaller.selector, user));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
    }

    function test_PostOp_OnlyEntryPoint() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAetherPaymaster.UnauthorizedCaller.selector, user));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0.01 ether, 20 gwei);
    }
}
