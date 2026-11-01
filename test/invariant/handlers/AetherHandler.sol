// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AetherPaymaster} from "../../../src/AetherPaymaster.sol";
import {IAetherPaymaster} from "../../../src/interfaces/IAetherPaymaster.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MockEntryPoint} from "../../mocks/MockEntryPoint.sol";
import {MockAccount} from "../../mocks/MockAccount.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../../mocks/MockAggregatorV3.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract AetherHandler is Test {
    AetherPaymaster public paymaster;
    MockEntryPoint public entryPoint;
    MockAccount public account;

    MockERC20 public usdc;
    MockERC20 public dai;
    MockAggregatorV3 public oracle;

    address public owner;
    uint256 public signerKey = 0xBB22;
    address public verifyingSigner;
    uint256 public userKey = 0xCC33;
    address public user;
    address payable public beneficiary = payable(makeAddr("beneficiary"));

    // Ghost accounting
    mapping(address => uint256) public ghost_feesCollected;
    mapping(address => uint256) public ghost_tokensWithdrawn;
    uint256 public ghost_nativeDeposited;
    uint256 public ghost_nativeSpent;
    uint256 public ghost_nativeWithdrawn;

    constructor(
        AetherPaymaster _paymaster,
        MockEntryPoint _entryPoint,
        MockAccount _account,
        MockERC20 _usdc,
        MockERC20 _dai,
        MockAggregatorV3 _oracle,
        address _owner
    ) {
        paymaster = _paymaster;
        entryPoint = _entryPoint;
        account = _account;
        usdc = _usdc;
        dai = _dai;
        oracle = _oracle;
        owner = _owner;

        verifyingSigner = vm.addr(signerKey);
        user = vm.addr(userKey);

        vm.prank(owner);
        paymaster.setVerifyingSigner(verifyingSigner, true);

        // Initial deposit
        vm.deal(owner, 1000 ether);
        vm.prank(owner);
        paymaster.deposit{value: 10 ether}();
        ghost_nativeDeposited += 10 ether;

        // Mint tokens to user account and approve
        usdc.mint(address(account), 1_000_000e6);
        dai.mint(address(account), 1_000_000 ether);

        vm.prank(address(account));
        usdc.approve(address(paymaster), type(uint256).max);

        vm.prank(address(account));
        dai.approve(address(paymaster), type(uint256).max);
    }

    function depositNative(uint256 amount) public {
        amount = bound(amount, 0.1 ether, 5 ether);
        vm.prank(owner);
        paymaster.deposit{value: amount}();
        ghost_nativeDeposited += amount;
    }

    function withdrawDeposit(uint256 amount) public {
        uint256 currentDep = paymaster.getDeposit();
        if (currentDep < 1 ether) return;
        amount = bound(amount, 0.1 ether, currentDep - 0.5 ether);

        vm.prank(owner);
        paymaster.withdrawDeposit(payable(owner), amount);
        ghost_nativeWithdrawn += amount;
    }

    function executeERC20Payment(uint256 gasUsed, uint256 gasPriceGwei, uint8 tokenChoice) public {
        if (paymaster.getDeposit() < 0.5 ether) return;

        gasUsed = bound(gasUsed, 21_000, 100_000);
        gasPriceGwei = bound(gasPriceGwei, 10, 100);
        entryPoint.setSimulatedGas(gasUsed, gasPriceGwei * 1 gwei);

        address token = (tokenChoice % 2 == 0) ? address(usdc) : address(dai);

        uint256 nonce = entryPoint.getNonce(address(account), 0);
        bytes memory paymasterData = abi.encodePacked(
            uint8(IAetherPaymaster.PaymasterMode.ERC20),
            abi.encode(token, uint256(1000 ether), uint48(block.timestamp + 1 hours), uint48(0))
        );

        PackedUserOperation memory userOp = _packUserOp(nonce, paymasterData);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        uint256 feeBefore = paymaster.totalGasCollected(token);
        entryPoint.handleOps(ops, beneficiary);

        uint256 feeAfter = paymaster.totalGasCollected(token);
        uint256 deltaFee = feeAfter - feeBefore;

        ghost_feesCollected[token] += deltaFee;
        ghost_nativeSpent += (gasUsed * gasPriceGwei * 1 gwei);
    }

    function withdrawTokenFees(uint8 tokenChoice, uint256 amount) public {
        address token = (tokenChoice % 2 == 0) ? address(usdc) : address(dai);
        uint256 bal = MockERC20(token).balanceOf(address(paymaster));
        if (bal == 0) return;

        amount = bound(amount, 1, bal);
        vm.prank(owner);
        paymaster.withdrawToken(MockERC20(token), owner, amount);
        ghost_tokensWithdrawn[token] += amount;
    }

    function _packUserOp(uint256 nonce, bytes memory paymasterData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        bytes32 accountGasLimits = bytes32(abi.encodePacked(uint128(100_000), uint128(100_000)));
        uint256 preVerificationGas = 50_000;
        bytes32 gasFees = bytes32(abi.encodePacked(uint128(2 gwei), uint128(100 gwei)));

        bytes memory paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), paymasterData);

        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");

        op = PackedUserOperation({
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

        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 uv, bytes32 ur, bytes32 us) = vm.sign(userKey, ethHash);
        op.signature = abi.encodePacked(ur, us, uv);
    }
}
