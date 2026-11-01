// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAetherPaymaster} from "./interfaces/IAetherPaymaster.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {AetherGasLib} from "./libraries/AetherGasLib.sol";
import {IEntryPoint, IPaymaster, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title AetherPaymaster
/// @notice Production-grade ERC-4337 Account Abstraction Paymaster supporting EIP-712 gas sponsorship
///         and ERC-20 multi-token gas payments with price oracle settlement.
contract AetherPaymaster is IAetherPaymaster, Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    using ERC4337Utils for PackedUserOperation;

    /// @notice Canonical EntryPoint contract
    IEntryPoint public immutable override entryPoint;

    /// @notice Authorized verifying signers for sponsored gas operations
    mapping(address => bool) public override isVerifyingSigner;

    /// @notice Configurations for whitelisted ERC-20 payment tokens
    mapping(address => TokenConfig) private _tokenConfigs;

    /// @notice Cumulative token fees collected by the paymaster
    mapping(address => uint256) public override totalGasCollected;

    /// @notice EIP-712 TypeHash for gas sponsorship authorization
    bytes32 public constant SPONSOR_PAYMASTER_TYPEHASH = keccak256(
        "SponsorPaymaster(" "address sender," "uint256 nonce," "bytes32 initCodeHash," "bytes32 callDataHash,"
        "bytes32 accountGasLimits," "uint256 preVerificationGas," "bytes32 gasFees,"
        "uint256 paymasterVerificationGasLimit," "uint256 paymasterPostOpGasLimit," "uint48 validUntil,"
        "uint48 validAfter," "bytes32 sponsorId," "uint256 chainId," "address paymaster" ")"
    );

    /// @param anEntryPoint Address of the canonical ERC-4337 EntryPoint contract
    /// @param initialOwner Initial admin account for 2-step ownership
    constructor(IEntryPoint anEntryPoint, address initialOwner) Ownable(initialOwner) EIP712("AetherPaymaster", "1") {
        if (address(anEntryPoint) == address(0) || initialOwner == address(0)) {
            revert InvalidAddress();
        }
        entryPoint = anEntryPoint;
    }

    /// @dev Reverts if caller is not the registered EntryPoint
    modifier onlyEntryPoint() {
        _requireFromEntryPoint();
        _;
    }

    function _requireFromEntryPoint() internal view {
        if (msg.sender != address(entryPoint)) {
            revert UnauthorizedCaller(msg.sender);
        }
    }

    /// @notice Validates whether the paymaster will pay for the user operation
    /// @dev Called by EntryPoint during verification phase
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        /* userOpHash */
        uint256 maxCost
    )
        external
        override
        onlyEntryPoint
        returns (bytes memory context, uint256 validationData)
    {
        if (paused()) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        bytes calldata pData = userOp.paymasterData();
        if (pData.length == 0) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        uint8 mode = uint8(pData[0]);

        if (mode == uint8(PaymasterMode.SPONSORED)) {
            return _validateSponsoredOp(userOp, pData[1:]);
        } else if (mode == uint8(PaymasterMode.ERC20)) {
            return _validateERC20Op(userOp, maxCost, pData[1:]);
        } else {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }
    }

    /// @dev Internal validation logic for Mode 0 (Gas Sponsorship via EIP-712)
    function _validateSponsoredOp(PackedUserOperation calldata userOp, bytes calldata data)
        internal
        view
        returns (bytes memory context, uint256 validationData)
    {
        if (data.length < 32 * 4) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        (uint48 validUntil, uint48 validAfter, bytes32 sponsorId, bytes memory signature) =
            abi.decode(data, (uint48, uint48, bytes32, bytes));

        if (validUntil != 0 && validUntil < validAfter) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }
        if (signature.length != 65) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        bytes32 structHash = keccak256(
            abi.encode(
                SPONSOR_PAYMASTER_TYPEHASH,
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                userOp.paymasterVerificationGasLimit(),
                userOp.paymasterPostOpGasLimit(),
                validUntil,
                validAfter,
                sponsorId,
                block.chainid,
                address(this)
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        (address recoveredSigner, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);

        if (err != ECDSA.RecoverError.NoError || !isVerifyingSigner[recoveredSigner] || recoveredSigner == address(0)) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        context = abi.encode(PaymasterMode.SPONSORED, userOp.sender, sponsorId, address(0), 0, 0);

        validationData = AetherGasLib.packValidationData(true, validAfter, validUntil);
    }

    /// @dev Internal validation logic for Mode 1 (ERC-20 Gas Payment with Oracle Settlement)
    function _validateERC20Op(PackedUserOperation calldata userOp, uint256 maxCost, bytes calldata data)
        internal
        returns (bytes memory context, uint256 validationData)
    {
        if (data.length < 32 * 4) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        (address token, uint256 maxAllowedTokenCost, uint48 validUntil, uint48 validAfter) =
            abi.decode(data, (address, uint256, uint48, uint48));

        if (validUntil != 0 && validUntil < validAfter) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        TokenConfig memory config = _tokenConfigs[token];
        if (!config.isSupported) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        (uint256 prefundTokenAmount,) = AetherGasLib.computeTokenCost(config, maxCost);

        // Guard against extreme slippage exceeding user's maximum allowance
        if (maxAllowedTokenCost != 0 && prefundTokenAmount > maxAllowedTokenCost) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        // Verify balance and allowance prior to pull
        if (IERC20(token).balanceOf(userOp.sender) < prefundTokenAmount) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }
        if (IERC20(token).allowance(userOp.sender, address(this)) < prefundTokenAmount) {
            return (bytes(""), AetherGasLib.SIG_VALIDATION_FAILED);
        }

        // Pre-charge maximum token cost upfront
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        IERC20(token).safeTransferFrom(userOp.sender, address(this), prefundTokenAmount);

        context = abi.encode(PaymasterMode.ERC20, userOp.sender, bytes32(0), token, prefundTokenAmount, maxCost);

        validationData = AetherGasLib.packValidationData(true, validAfter, validUntil);
    }

    /// @notice Post-operation callback invoked by EntryPoint to reconcile actual gas costs
    /// @dev Called by EntryPoint after inner execution
    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        external
        override
        nonReentrant
        onlyEntryPoint
    {
        if (context.length == 0) return;

        (
            PaymasterMode opMode,
            address sender,
            bytes32 sponsorId,
            address token,
            uint256 prefundTokenAmount,
            uint256 maxCost
        ) = abi.decode(context, (PaymasterMode, address, bytes32, address, uint256, uint256));

        if (opMode == PaymasterMode.SPONSORED) {
            emit GasSponsored(sender, sponsorId, actualGasCost, actualUserOpFeePerGas);
        } else if (opMode == PaymasterMode.ERC20) {
            // If postOp previously reverted, EntryPoint calls postOp with mode == postOpReverted.
            // As per ERC-4337, postOp MUST NOT revert on postOpReverted to avoid bricking the entire bundle.
            if (mode == PostOpMode.postOpReverted) {
                return;
            }

            uint256 actualTokenCost = (maxCost > 0 && actualGasCost < maxCost)
                ? (prefundTokenAmount * actualGasCost) / maxCost
                : prefundTokenAmount;

            uint256 refundAmount = prefundTokenAmount - actualTokenCost;

            // Refund unused tokens to user
            if (refundAmount > 0) {
                IERC20(token).safeTransfer(sender, refundAmount);
            }

            totalGasCollected[token] += actualTokenCost;

            emit GasTokenPaid(sender, token, actualGasCost, actualTokenCost, refundAmount);
        }
    }

    // --- Configuration & Admin ---

    /// @notice Configures authorized verifying signer for sponsorship
    /// @param signer Signer address
    /// @param active Authorization status
    function setVerifyingSigner(address signer, bool active) external override onlyOwner {
        if (signer == address(0)) revert InvalidAddress();
        isVerifyingSigner[signer] = active;
        emit VerifyingSignerUpdated(signer, active);
    }

    /// @notice Whitelists or updates configuration for an ERC-20 payment token
    function setTokenConfig(
        address token,
        address oracle,
        uint8 tokenDecimals,
        uint8 oracleDecimals,
        uint32 maxOracleAge,
        uint16 markupBps,
        bool isPriceTokenPerEth
    ) external override onlyOwner {
        if (token == address(0) || oracle == address(0)) revert InvalidAddress();
        if (markupBps > 5_000) revert InvalidMarkup(markupBps); // Max 50% markup safeguard
        if (tokenDecimals == 0 || tokenDecimals > 18) revert InvalidDecimals(tokenDecimals);
        if (oracleDecimals == 0 || oracleDecimals > 18) revert InvalidDecimals(oracleDecimals);
        if (maxOracleAge == 0) revert InvalidMaxOracleAge();

        _tokenConfigs[token] = TokenConfig({
            isSupported: true,
            oracle: oracle,
            tokenDecimals: tokenDecimals,
            oracleDecimals: oracleDecimals,
            maxOracleAge: maxOracleAge,
            markupBps: markupBps,
            isPriceTokenPerEth: isPriceTokenPerEth
        });

        emit TokenConfigUpdated(
            token, oracle, tokenDecimals, oracleDecimals, maxOracleAge, markupBps, isPriceTokenPerEth
        );
    }

    /// @notice Removes support for an ERC-20 payment token
    function removeToken(address token) external override onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        delete _tokenConfigs[token];
        emit TokenRemoved(token);
    }

    /// @notice Emergency pause for all paymaster operations
    function pause() external override onlyOwner {
        _pause();
    }

    /// @notice Unpause paymaster operations
    function unpause() external override onlyOwner {
        _unpause();
    }

    // --- EntryPoint Deposit & Stake Controls ---

    /// @notice Deposits native ETH into EntryPoint to fund gas payments
    function deposit() external payable override {
        if (msg.value == 0) revert ZeroDeposit();
        emit PaymasterDeposited(address(this), msg.value);
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /// @notice Withdraws ETH deposit from EntryPoint to specified recipient
    function withdrawDeposit(address payable to, uint256 amount) external override nonReentrant onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        emit PaymasterDepositWithdrawn(to, amount);
        entryPoint.withdrawTo(to, amount);
    }

    /// @notice Adds stake in EntryPoint to improve bundler reputation
    function addStake(uint32 unstakeDelaySec) external payable override onlyOwner {
        if (msg.value == 0) revert ZeroDeposit();
        emit StakeAdded(msg.value, unstakeDelaySec);
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @notice Requests unlocking stake in EntryPoint
    function unlockStake() external override onlyOwner {
        emit StakeUnlocked();
        entryPoint.unlockStake();
    }

    /// @notice Withdraws unlocked stake from EntryPoint
    function withdrawStake(address payable to) external override nonReentrant onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        uint256 balanceBefore = to.balance;
        entryPoint.withdrawStake(to);
        uint256 amountWithdrawn = to.balance - balanceBefore;
        // forge-lint: disable-next-line(reentrancy-events)
        emit StakeWithdrawn(to, amountWithdrawn);
    }

    /// @notice Withdraws accumulated ERC-20 gas fee revenue to treasury
    function withdrawToken(IERC20 token, address to, uint256 amount) external override nonReentrant onlyOwner {
        if (to == address(0) || address(token) == address(0)) revert InvalidAddress();
        emit FeesWithdrawn(address(token), to, amount);
        token.safeTransfer(to, amount);
    }

    /// @notice Withdraws direct native ETH held in contract
    function withdrawNative(address payable to, uint256 amount) external override nonReentrant onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        emit NativeWithdrawn(to, amount);
        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }

    // --- Views ---

    /// @notice Returns token configuration
    function getTokenConfig(address token) external view override returns (TokenConfig memory) {
        return _tokenConfigs[token];
    }

    /// @notice Returns paymaster deposit in EntryPoint
    function getDeposit() external view override returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /// @notice Calculates estimated token cost for gas in wei
    function calculateTokenCost(address token, uint256 nativeGasCost)
        external
        view
        override
        returns (uint256 tokenAmount, uint256 effectivePrice)
    {
        TokenConfig memory config = _tokenConfigs[token];
        if (!config.isSupported) revert TokenNotSupported(token);
        return AetherGasLib.computeTokenCost(config, nativeGasCost);
    }

    /// @notice Fallback to accept native ETH and route directly into EntryPoint deposit
    receive() external payable {
        if (msg.value > 0) {
            emit PaymasterDeposited(address(this), msg.value);
            entryPoint.depositTo{value: msg.value}(address(this));
        }
    }
}
