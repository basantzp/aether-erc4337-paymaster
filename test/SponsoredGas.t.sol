// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AetherPaymaster} from "../src/AetherPaymaster.sol";
import {IAetherPaymaster} from "../src/interfaces/IAetherPaymaster.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MockEntryPoint} from "./mocks/MockEntryPoint.sol";
import {MockAccount} from "./mocks/MockAccount.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract SponsoredGasTest is Test {
    AetherPaymaster public paymaster;
    MockEntryPoint public entryPoint;
    MockAccount public account;

    uint256 public ownerKey = 0xAA11;
    address public owner;

    uint256 public signerKey = 0xBB22;
    address public verifyingSigner;

    uint256 public userKey = 0xCC33;
    address public user;

    address payable public beneficiary = payable(makeAddr("beneficiary"));
    bytes32 public sponsorId = keccak256("CAMPAIGN_ALPHA_2026");

    function setUp() public {
        vm.warp(100_000);

        owner = vm.addr(ownerKey);
        verifyingSigner = vm.addr(signerKey);
        user = vm.addr(userKey);

        vm.deal(owner, 100 ether);
        vm.deal(user, 10 ether);

        entryPoint = new MockEntryPoint();

        vm.prank(owner);
        paymaster = new AetherPaymaster(entryPoint, owner);

        vm.prank(owner);
        paymaster.setVerifyingSigner(verifyingSigner, true);

        // Fund paymaster deposit in EntryPoint
        vm.prank(owner);
        paymaster.deposit{value: 10 ether}();

        // Deploy user smart account
        account = new MockAccount(user, address(entryPoint));
    }

    function _buildUserOp(
        uint256 nonce,
        bytes memory callData,
        uint48 validUntil,
        uint48 validAfter,
        bytes32 aSponsorId,
        uint256 aSignerKey
    ) internal view returns (PackedUserOperation memory userOp) {
        bytes32 accountGasLimits = bytes32(abi.encodePacked(uint128(100_000), uint128(100_000)));
        uint256 preVerificationGas = 50_000;
        bytes32 gasFees = bytes32(abi.encodePacked(uint128(2 gwei), uint128(20 gwei)));

        uint128 paymasterVerificationGasLimit = 100_000;
        uint128 paymasterPostOpGasLimit = 50_000;

        // Construct EIP-712 struct hash
        bytes32 structHash = keccak256(
            abi.encode(
                paymaster.SPONSOR_PAYMASTER_TYPEHASH(),
                address(account),
                nonce,
                keccak256(""),
                keccak256(callData),
                accountGasLimits,
                preVerificationGas,
                gasFees,
                uint256(paymasterVerificationGasLimit),
                uint256(paymasterPostOpGasLimit),
                validUntil,
                validAfter,
                aSponsorId,
                block.chainid,
                address(paymaster)
            )
        );

        // Sign with paymaster signer
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aSignerKey, digest);
        bytes memory paymasterSig = abi.encodePacked(r, s, v);

        // Pack paymasterData: [mode=0] ++ abi.encode(validUntil, validAfter, sponsorId, signature)
        bytes memory paymasterData = abi.encodePacked(
            uint8(IAetherPaymaster.PaymasterMode.SPONSORED),
            abi.encode(validUntil, validAfter, aSponsorId, paymasterSig)
        );

        bytes memory paymasterAndData =
            abi.encodePacked(address(paymaster), paymasterVerificationGasLimit, paymasterPostOpGasLimit, paymasterData);

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

        // Sign userOp with user key
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 uv, bytes32 ur, bytes32 us) = vm.sign(userKey, ethHash);
        userOp.signature = abi.encodePacked(ur, us, uv);
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("AetherPaymaster")),
                keccak256(bytes("1")),
                block.chainid,
                address(paymaster)
            )
        );
    }

    // --- Happy Path Tests ---

    function test_SponsoredGas_SuccessfulExecution() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        PackedUserOperation memory userOp = _buildUserOp(0, callData, validUntil, validAfter, sponsorId, signerKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        uint256 depositBefore = paymaster.getDeposit();
        uint256 beneficiaryBefore = beneficiary.balance;

        vm.expectEmit(true, true, false, false);
        emit IAetherPaymaster.GasSponsored(address(account), sponsorId, 0, 0);

        entryPoint.handleOps(ops, beneficiary);

        uint256 expectedCost = entryPoint.simulatedActualGas() * entryPoint.simulatedFeePerGas();
        assertEq(paymaster.getDeposit(), depositBefore - expectedCost);
        assertEq(beneficiary.balance, beneficiaryBefore + expectedCost);
        assertEq(entryPoint.getNonce(address(account), 0), 1);
    }

    // --- Rejection & Tamper Tests ---

    function test_SponsoredGas_RevertExpiredSignature() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");
        uint48 validUntil = uint48(block.timestamp - 1); // Expired
        uint48 validAfter = 0;

        PackedUserOperation memory userOp = _buildUserOp(0, callData, validUntil, validAfter, sponsorId, signerKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_SponsoredGas_RevertPrematureSignature() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");
        uint48 validUntil = uint48(block.timestamp + 2 hours);
        uint48 validAfter = uint48(block.timestamp + 1 hours); // In future

        PackedUserOperation memory userOp = _buildUserOp(0, callData, validUntil, validAfter, sponsorId, signerKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_SponsoredGas_RevertUnauthorizedSigner() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");
        uint256 unauthorizedKey = 0x9999;

        PackedUserOperation memory userOp =
            _buildUserOp(0, callData, uint48(block.timestamp + 1 hours), 0, sponsorId, unauthorizedKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_SponsoredGas_ReplayProtection_SameNonce() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");

        PackedUserOperation memory userOp =
            _buildUserOp(0, callData, uint48(block.timestamp + 1 hours), 0, sponsorId, signerKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        // First execution succeeds
        entryPoint.handleOps(ops, beneficiary);

        // Replaying same operation fails because nonce on EntryPoint is now 1
        // And userOp was signed with nonce 0
        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_SponsoredGas_ReplayProtection_DifferentNonce() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");

        // UserOp paymaster signature signed for nonce 0
        PackedUserOperation memory userOp =
            _buildUserOp(0, callData, uint48(block.timestamp + 1 hours), 0, sponsorId, signerKey);

        // Account is now at nonce 1 on EntryPoint
        entryPoint.setNonce(address(account), 1);
        userOp.nonce = 1;

        // Account signs for nonce 1
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 uv, bytes32 ur, bytes32 us) = vm.sign(userKey, ethHash);
        userOp.signature = abi.encodePacked(ur, us, uv);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        // Paymaster signature bound nonce 0, so paymaster rejects nonce 1!
        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_SponsoredGas_TamperedCallData() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");

        PackedUserOperation memory userOp =
            _buildUserOp(0, callData, uint48(block.timestamp + 1 hours), 0, sponsorId, signerKey);

        // Attacker tampers callData
        userOp.callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xdead), 0, "");

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_SponsoredGas_TamperedGasFees() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");

        PackedUserOperation memory userOp =
            _buildUserOp(0, callData, uint48(block.timestamp + 1 hours), 0, sponsorId, signerKey);

        // Attacker inflates gasFees
        userOp.gasFees = bytes32(abi.encodePacked(uint128(10 gwei), uint128(100 gwei)));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_SponsoredGas_RevertWhenPaused() public {
        bytes memory callData = abi.encodeWithSelector(MockAccount.execute.selector, address(0xbeef), 0, "");

        PackedUserOperation memory userOp =
            _buildUserOp(0, callData, uint48(block.timestamp + 1 hours), 0, sponsorId, signerKey);

        vm.prank(owner);
        paymaster.pause();

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert("MockEntryPoint: paymaster validation failed");
        entryPoint.handleOps(ops, beneficiary);
    }
}
