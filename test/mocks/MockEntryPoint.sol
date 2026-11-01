// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEntryPoint, IAccount, IPaymaster, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";

contract MockEntryPoint is IEntryPoint {
    using ERC4337Utils for PackedUserOperation;

    struct DepositInfo {
        uint112 deposit;
        bool staked;
        uint112 stake;
        uint32 unstakeDelaySec;
        uint48 withdrawTime;
    }

    mapping(address => DepositInfo) public deposits;
    mapping(address => uint256) public nonces;

    uint256 public simulatedActualGas = 50_000;
    uint256 public simulatedFeePerGas = 20 gwei;

    event UserOpHandled(
        bytes32 indexed userOpHash, address indexed sender, address indexed paymaster, uint256 actualCost
    );

    function setSimulatedGas(uint256 gasUsed, uint256 feePerGas) external {
        simulatedActualGas = gasUsed;
        simulatedFeePerGas = feePerGas;
    }

    function setNonce(address sender, uint256 nonce) external {
        nonces[sender] = nonce;
    }

    // --- IEntryPointNonces ---
    function getNonce(
        address sender,
        uint192 /* key */
    )
        external
        view
        override
        returns (uint256 nonce)
    {
        return nonces[sender];
    }

    // --- IEntryPointStake ---
    function balanceOf(address account) external view override returns (uint256) {
        return deposits[account].deposit;
    }

    function depositTo(address account) external payable override {
        deposits[account].deposit += uint112(msg.value);
    }

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external override {
        require(deposits[msg.sender].deposit >= withdrawAmount, "MockEntryPoint: insufficient deposit");
        deposits[msg.sender].deposit -= uint112(withdrawAmount);
        (bool success,) = withdrawAddress.call{value: withdrawAmount}("");
        require(success, "MockEntryPoint: withdraw failed");
    }

    function addStake(uint32 unstakeDelaySec) external payable override {
        deposits[msg.sender].staked = true;
        deposits[msg.sender].stake += uint112(msg.value);
        deposits[msg.sender].unstakeDelaySec = unstakeDelaySec;
    }

    function unlockStake() external override {
        DepositInfo storage info = deposits[msg.sender];
        require(info.staked, "MockEntryPoint: not staked");
        info.staked = false;
        info.withdrawTime = uint48(block.timestamp + info.unstakeDelaySec);
    }

    function withdrawStake(address payable withdrawAddress) external override {
        DepositInfo storage info = deposits[msg.sender];
        require(!info.staked, "MockEntryPoint: stake not unlocked");
        require(info.withdrawTime <= block.timestamp, "MockEntryPoint: delay not passed");
        uint256 amount = info.stake;
        info.stake = 0;
        (bool success,) = withdrawAddress.call{value: amount}("");
        require(success, "MockEntryPoint: withdraw stake failed");
    }

    // --- Hash Calculation ---
    function getUserOpHash(PackedUserOperation calldata userOp) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                keccak256(userOp.paymasterAndData),
                block.chainid,
                address(this)
            )
        );
    }

    // --- Execution ---
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external override {
        uint256 length = ops.length;
        for (uint256 i = 0; i < length; i++) {
            _handleOp(ops[i], beneficiary);
        }
    }

    function handleAggregatedOps(
        UserOpsPerAggregator[] calldata,
        /* opsPerAggregator */
        address payable /* beneficiary */
    )
        external
        pure
        override
    {
        revert("Aggregated ops not implemented");
    }

    function _handleOp(PackedUserOperation calldata userOp, address payable beneficiary) internal {
        require(userOp.nonce == nonces[userOp.sender], "MockEntryPoint: invalid nonce");
        bytes32 opHash = getUserOpHash(userOp);
        nonces[userOp.sender]++;

        address paymasterAddr = userOp.paymaster();
        bytes memory context = "";
        uint256 maxCost = 150_000 * simulatedFeePerGas;

        if (paymasterAddr != address(0)) {
            uint256 valData;
            (context, valData) = IPaymaster(paymasterAddr).validatePaymasterUserOp(userOp, opHash, maxCost);
            (address authorizer, uint48 validAfter, uint48 validUntil,) = ERC4337Utils.parseValidationData(valData);
            require(authorizer == address(0), "MockEntryPoint: paymaster validation failed");
            require(block.timestamp >= validAfter, "MockEntryPoint: paymaster not valid yet");
            require(validUntil == 0 || block.timestamp <= validUntil, "MockEntryPoint: paymaster expired");
        }

        // Account validation
        uint256 accountVal = IAccount(userOp.sender).validateUserOp(userOp, opHash, 0);
        require(uint160(accountVal) == 0, "MockEntryPoint: account validation failed");

        // Inner execution
        IPaymaster.PostOpMode postOpMode = IPaymaster.PostOpMode.opSucceeded;
        if (userOp.callData.length > 0) {
            (bool success,) = userOp.sender.call(userOp.callData);
            if (!success) {
                postOpMode = IPaymaster.PostOpMode.opReverted;
            }
        }

        uint256 actualCost = simulatedActualGas * simulatedFeePerGas;

        if (paymasterAddr != address(0)) {
            require(deposits[paymasterAddr].deposit >= actualCost, "MockEntryPoint: paymaster out of deposit");
            deposits[paymasterAddr].deposit -= uint112(actualCost);

            try IPaymaster(paymasterAddr).postOp(postOpMode, context, actualCost, simulatedFeePerGas) {}
            catch {
                // Canonical ERC-4337 second-chance callback with postOpReverted mode
                IPaymaster(paymasterAddr)
                    .postOp(IPaymaster.PostOpMode.postOpReverted, context, actualCost, simulatedFeePerGas);
            }
        }

        if (beneficiary != address(0) && actualCost > 0) {
            (bool paid,) = beneficiary.call{value: actualCost}("");
            require(paid, "MockEntryPoint: beneficiary pay failed");
        }

        emit UserOpHandled(opHash, userOp.sender, paymasterAddr, actualCost);
    }

    receive() external payable {}
}
