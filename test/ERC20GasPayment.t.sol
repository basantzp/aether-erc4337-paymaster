// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AetherPaymaster} from "../src/AetherPaymaster.sol";
import {IAetherPaymaster} from "../src/interfaces/IAetherPaymaster.sol";
import {IPaymaster, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MockEntryPoint} from "./mocks/MockEntryPoint.sol";
import {MockAccount} from "./mocks/MockAccount.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ERC20GasPaymentTest is Test {
    AetherPaymaster public paymaster;
    MockEntryPoint public entryPoint;
    MockAccount public account;

    MockERC20 public usdc;
    MockERC20 public dai;
    MockAggregatorV3 public ethUsdOracle;

    uint256 public ownerKey = 0xAA11;
    address public owner;

    uint256 public userKey = 0xCC33;
    address public user;

    address payable public beneficiary = payable(makeAddr("beneficiary"));

    function setUp() public {
        vm.warp(100_000);

        owner = vm.addr(ownerKey);
        user = vm.addr(userKey);

        vm.deal(owner, 100 ether);
        vm.deal(user, 10 ether);

        entryPoint = new MockEntryPoint();

        vm.prank(owner);
        paymaster = new AetherPaymaster(entryPoint, owner);

        // Fund paymaster deposit in EntryPoint
        vm.prank(owner);
        paymaster.deposit{value: 10 ether}();

        // Deploy user smart account
        account = new MockAccount(user, address(entryPoint));

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Deploy Chainlink oracle feed ($2,500 / ETH, 8 decimals)
        ethUsdOracle = new MockAggregatorV3(8, "ETH / USD", 2500e8);

        // Whitelist USDC with 5% markup (500 bps)
        vm.prank(owner);
        paymaster.setTokenConfig(
            address(usdc),
            address(ethUsdOracle),
            6,
            8,
            3600,
            500, // +5%
            true
        );

        // Whitelist DAI with 3% markup (300 bps)
        vm.prank(owner);
        paymaster.setTokenConfig(
            address(dai),
            address(ethUsdOracle),
            18,
            8,
            3600,
            300, // +3%
            true
        );
    }

    function _buildERC20UserOp(
        uint256 nonce,
        address token,
        uint256 maxAllowedTokenCost,
        uint48 validUntil,
        uint48 validAfter
    ) internal view returns (PackedUserOperation memory userOp) {
        bytes32 accountGasLimits = bytes32(abi.encodePacked(uint128(100_000), uint128(100_000)));
        uint256 preVerificationGas = 50_000;
        bytes32 gasFees = bytes32(abi.encodePacked(uint128(2 gwei), uint128(20 gwei)));

        uint128 paymasterVerificationGasLimit = 100_000;
        uint128 paymasterPostOpGasLimit = 50_000;

        // Pack paymasterData: [mode=1] ++ abi.encode(token, maxAllowedTokenCost, validUntil, validAfter)
        bytes memory paymasterData = abi.encodePacked(
            uint8(IAetherPaymaster.PaymasterMode.ERC20), abi.encode(token, maxAllowedTokenCost, validUntil, validAfter)
        );

        bytes memory paymasterAndData =
            abi.encodePacked(address(paymaster), paymasterVerificationGasLimit, paymasterPostOpGasLimit, paymasterData);

        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");

        userOp = PackedUserOperation({
            sender: address(account),
            nonce: nonce,
            initCode: "",
            callData: callData,
            accountGasLimits: accountGasLimits,
            preVerificationGas: preVerificationGas,
            gasFees: gasFees,
            paymasterAndData: paymasterAndData,
            signature: ""
        });

        // Sign with account owner
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 uv, bytes32 ur, bytes32 us) = vm.sign(userKey, ethHash);
        userOp.signature = abi.encodePacked(ur, us, uv);
    }

    // --- Math & Calculation Tests ---

    function test_Math_CalculateTokenCost_USDC() public view {
        // Native gas cost: 0.002 ETH
        // ETH price: $2,500
        // Base: 0.002 * 2500 = $5.00 USDC
        // +5% markup: 5.00 * 1.05 = $5.25 USDC = 5_250_000 units
        (uint256 tokenAmount, uint256 price) = paymaster.calculateTokenCost(address(usdc), 0.002 ether);
        assertEq(price, 2500e8);
        assertEq(tokenAmount, 5_250_000);
    }

    function test_Math_CalculateTokenCost_DAI() public view {
        // Native gas cost: 0.002 ETH
        // ETH price: $2,500
        // Base: 0.002 * 2500 = $5.00 DAI
        // +3% markup: 5.00 * 1.03 = $5.15 DAI = 5.15 * 10^18 units
        (uint256 tokenAmount, uint256 price) = paymaster.calculateTokenCost(address(dai), 0.002 ether);
        assertEq(price, 2500e8);
        assertEq(tokenAmount, 5.15 ether);
    }

    // --- Happy Path Execution & Refund ---

    function test_ERC20GasPayment_USDC_SuccessWithRefund() public {
        // Mint 100 USDC to account
        usdc.mint(address(account), 100e6);

        // Account approves paymaster
        vm.prank(address(account));
        usdc.approve(address(paymaster), type(uint256).max);

        // EntryPoint simulated gas: 50,000 gas @ 20 gwei = 0.001 ETH
        // Actual cost = 0.001 * 2500 * 1.05 = 2.625 USDC = 2_625_000 units
        // MaxCost in MockEntryPoint = 150_000 * 20 gwei = 0.003 ETH
        // Prefund = 0.003 * 2500 * 1.05 = 7.875 USDC = 7_875_000 units
        // Expected refund = 7_875_000 - 2_625_000 = 5_250_000 units

        PackedUserOperation memory userOp = _buildERC20UserOp(
            0,
            address(usdc),
            10e6, // maxAllowedTokenCost = 10 USDC
            uint48(block.timestamp + 1 hours),
            uint48(block.timestamp)
        );

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        uint256 accountUsdcBefore = usdc.balanceOf(address(account));
        uint256 paymasterDepositBefore = paymaster.getDeposit();

        vm.expectEmit(true, true, false, true);
        emit IAetherPaymaster.GasTokenPaid(address(account), address(usdc), 0.001 ether, 2_625_000, 5_250_000);

        entryPoint.handleOps(ops, beneficiary);

        // Verify net deduction from user
        assertEq(usdc.balanceOf(address(account)), accountUsdcBefore - 2_625_000);

        // Verify paymaster collected fees
        assertEq(paymaster.totalGasCollected(address(usdc)), 2_625_000);
        assertEq(usdc.balanceOf(address(paymaster)), 2_625_000);

        // Verify paymaster ETH deposit debited in EntryPoint
        assertEq(paymaster.getDeposit(), paymasterDepositBefore - 0.001 ether);
    }

    function test_ERC20GasPayment_DAI_SuccessWithRefund() public {
        // Mint 100 DAI to account
        dai.mint(address(account), 100 ether);

        vm.prank(address(account));
        dai.approve(address(paymaster), type(uint256).max);

        // Actual gas: 0.001 ETH * $2,500 * 1.03 = 2.575 DAI
        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(dai), 10 ether, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        uint256 accountDaiBefore = dai.balanceOf(address(account));

        entryPoint.handleOps(ops, beneficiary);

        uint256 expectedActualCost = 2.575 ether;
        assertEq(dai.balanceOf(address(account)), accountDaiBefore - expectedActualCost);
        assertEq(paymaster.totalGasCollected(address(dai)), expectedActualCost);
    }

    // --- Slippage, Balance & Allowance Tests ---

    function test_ERC20GasPayment_RevertExceedsMaxAllowedCost() public {
        usdc.mint(address(account), 100e6);
        vm.prank(address(account));
        usdc.approve(address(paymaster), type(uint256).max);

        // Prefund required is 7.875 USDC, but user sets maxAllowed to 5.00 USDC
        PackedUserOperation memory userOp = _buildERC20UserOp(
            0,
            address(usdc),
            5e6, // Too low
            uint48(block.timestamp + 1 hours),
            0
        );

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_ERC20GasPayment_RevertInsufficientBalance() public {
        // Mint only 1 USDC, but prefund is ~7.875 USDC
        usdc.mint(address(account), 1e6);
        vm.prank(address(account));
        usdc.approve(address(paymaster), type(uint256).max);

        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(usdc), 10e6, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_ERC20GasPayment_RevertInsufficientAllowance() public {
        usdc.mint(address(account), 100e6);
        // Approve only 1 USDC
        vm.prank(address(account));
        usdc.approve(address(paymaster), 1e6);

        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(usdc), 10e6, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    // --- Oracle Defense Tests ---

    function test_ERC20GasPayment_RevertStaleOracle() public {
        usdc.mint(address(account), 100e6);
        vm.prank(address(account));
        usdc.approve(address(paymaster), type(uint256).max);

        // Set oracle updatedAt older than maxOracleAge (3600 seconds)
        ethUsdOracle.setRoundData(1, 2500e8, block.timestamp - 3601, 1);

        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(usdc), 10e6, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_ERC20GasPayment_RevertNegativeOraclePrice() public {
        usdc.mint(address(account), 100e6);
        vm.prank(address(account));
        usdc.approve(address(paymaster), type(uint256).max);

        ethUsdOracle.setPrice(-1);

        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(usdc), 10e6, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_ERC20GasPayment_RevertFutureTimestampOracle() public {
        usdc.mint(address(account), 100e6);
        vm.prank(address(account));
        usdc.approve(address(paymaster), type(uint256).max);

        ethUsdOracle.setRoundData(1, 2500e8, block.timestamp + 100, 1);

        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(usdc), 10e6, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_ERC20GasPayment_RevertIncompleteOracleRound() public {
        usdc.mint(address(account), 100e6);
        vm.prank(address(account));
        usdc.approve(address(paymaster), type(uint256).max);

        // answeredInRound (1) < roundId (2)
        ethUsdOracle.setRoundData(2, 2500e8, block.timestamp, 1);

        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(usdc), 10e6, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_ERC20GasPayment_RevertUnsupportedToken() public {
        MockERC20 unlisted = new MockERC20("Unlisted", "UNL", 18);
        unlisted.mint(address(account), 100 ether);

        vm.prank(address(account));
        unlisted.approve(address(paymaster), type(uint256).max);

        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(unlisted), 10 ether, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    // --- Token/ETH (isPriceTokenPerEth == false) Settlement & Decimals ---

    function test_Math_CalculateTokenCost_TokenPerEth_LINK() public {
        // LINK has 18 decimals, oracle LINK/ETH has 18 decimals
        MockERC20 link = new MockERC20("Chainlink", "LINK", 18);
        MockAggregatorV3 linkEthOracle = new MockAggregatorV3(18, "LINK / ETH", 0.005 ether);

        vm.prank(owner);
        paymaster.setTokenConfig(address(link), address(linkEthOracle), 18, 18, 3600, 500, false); // +5%

        // Gas: 0.01 ETH. 1 LINK = 0.005 ETH -> 2 LINK base. +5% = 2.1 LINK
        (uint256 tokenAmount, uint256 price) = paymaster.calculateTokenCost(address(link), 0.01 ether);
        assertEq(price, 0.005 ether);
        assertEq(tokenAmount, 2.1 ether);
    }

    function test_Math_CalculateTokenCost_TokenPerEth_WBTC() public {
        // WBTC has 8 decimals, oracle WBTC/ETH has 8 decimals (totalDecimals 16 < 18)
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        MockAggregatorV3 wbtcEthOracle = new MockAggregatorV3(8, "WBTC / ETH", 30e8); // 1 WBTC = 30 ETH

        vm.prank(owner);
        paymaster.setTokenConfig(address(wbtc), address(wbtcEthOracle), 8, 8, 3600, 0, false); // 0% markup

        // Gas: 3 ETH. 1 WBTC = 30 ETH -> 0.1 WBTC = 10_000_000 units
        (uint256 tokenAmount, uint256 price) = paymaster.calculateTokenCost(address(wbtc), 3 ether);
        assertEq(price, 30e8);
        assertEq(tokenAmount, 10_000_000); // exactly 0.1 WBTC in 8 decimals
    }

    function test_ERC20GasPayment_LINK_TokenPerEth_SuccessWithRefund() public {
        MockERC20 link = new MockERC20("Chainlink", "LINK", 18);
        MockAggregatorV3 linkEthOracle = new MockAggregatorV3(18, "LINK / ETH", 0.005 ether);

        vm.prank(owner);
        paymaster.setTokenConfig(address(link), address(linkEthOracle), 18, 18, 3600, 500, false);

        link.mint(address(account), 100 ether);
        vm.prank(address(account));
        link.approve(address(paymaster), type(uint256).max);

        // Simulated gas: 50,000 gas @ 20 gwei = 0.001 ETH
        // Actual cost = 0.001 / 0.005 * 1.05 = 0.21 LINK
        PackedUserOperation memory userOp =
            _buildERC20UserOp(0, address(link), 10 ether, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        uint256 accountBalBefore = link.balanceOf(address(account));
        entryPoint.handleOps(ops, beneficiary);

        assertEq(link.balanceOf(address(account)), accountBalBefore - 0.21 ether);
        assertEq(paymaster.totalGasCollected(address(link)), 0.21 ether);
    }

    function test_ERC20GasPayment_PostOpReverted_SafeHandled() public {
        // Verify postOp with postOpReverted mode returns without reverting
        bytes memory context = abi.encode(
            IAetherPaymaster.PaymasterMode.ERC20,
            address(account),
            bytes32(0),
            address(usdc),
            uint256(10e6),
            uint256(0.003 ether)
        );

        vm.prank(address(entryPoint));
        // Should execute smoothly without reverting
        paymaster.postOp(IPaymaster.PostOpMode.postOpReverted, context, 0.001 ether, 20 gwei);
    }
}
