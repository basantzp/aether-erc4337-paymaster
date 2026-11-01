// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster, IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IAetherPaymaster
/// @notice Comprehensive interface for the Aether ERC-4337 Account Abstraction Paymaster
interface IAetherPaymaster is IPaymaster {
    /// @notice Operation execution modes supported by Aether Paymaster
    enum PaymasterMode {
        SPONSORED, // Mode 0: 100% sponsored by paymaster via EIP-712 signer
        ERC20 // Mode 1: Paid in whitelisted ERC-20 tokens via price oracle settlement
    }

    /// @notice Configuration for whitelisted gas-payment ERC-20 tokens
    struct TokenConfig {
        bool isSupported; // Whether the token is currently active
        address oracle; // Chainlink AggregatorV3Interface price feed
        uint8 tokenDecimals; // ERC-20 token decimals (e.g. 6 for USDC, 18 for DAI)
        uint8 oracleDecimals; // Oracle feed decimals (typically 8 for USD feeds)
        uint32 maxOracleAge; // Max allowed staleness heartbeat in seconds
        uint16 markupBps; // Fee markup in basis points (e.g. 500 = 5%)
        bool isPriceTokenPerEth; // true if oracle returns Tokens/ETH, false if ETH/Token
    }

    // --- Custom Errors ---
    error UnauthorizedCaller(address caller);
    error InvalidSigner(address signer);
    error InvalidSignatureLength(uint256 length);
    error SignatureExpired(uint48 validUntil, uint256 currentTimestamp);
    error SignatureNotYetValid(uint48 validAfter, uint256 currentTimestamp);
    error TokenNotSupported(address token);
    error InvalidOraclePrice(int256 price);
    error InvalidOracleTimestamp(uint256 updatedAt);
    error StaleOraclePrice(uint256 currentTimestamp, uint256 updatedAt, uint32 maxAge);
    error IncompleteOracleRound(uint80 roundId, uint80 answeredInRound);
    error ExceedsMaxTokenCost(uint256 requiredTokenCost, uint256 maxAllowedTokenCost);
    error InsufficientTokenBalance(address token, address user, uint256 balance, uint256 required);
    error InsufficientTokenAllowance(address token, address user, uint256 allowance, uint256 required);
    error InvalidAddress();
    error InvalidMarkup(uint16 markupBps);
    error ZeroDeposit();
    error WithdrawFailed();
    error InvalidPaymasterMode(uint8 mode);

    // --- Events ---
    event GasSponsored(
        address indexed sender, bytes32 indexed sponsorId, uint256 actualGasCost, uint256 actualUserOpFeePerGas
    );

    event GasTokenPaid(
        address indexed sender,
        address indexed token,
        uint256 actualGasCost,
        uint256 actualTokenCost,
        uint256 refundAmount
    );

    event VerifyingSignerUpdated(address indexed signer, bool active);

    event TokenConfigUpdated(
        address indexed token,
        address indexed oracle,
        uint8 tokenDecimals,
        uint8 oracleDecimals,
        uint32 maxOracleAge,
        uint16 markupBps,
        bool isPriceTokenPerEth
    );

    event TokenRemoved(address indexed token);
    event PaymasterDeposited(address indexed paymaster, uint256 amount);
    event PaymasterDepositWithdrawn(address indexed to, uint256 amount);
    event StakeAdded(uint256 amount, uint32 unstakeDelaySec);
    event StakeUnlocked();
    event StakeWithdrawn(address indexed to, uint256 amount);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    // --- View Functions ---
    function entryPoint() external view returns (IEntryPoint);
    function isVerifyingSigner(address signer) external view returns (bool);
    function getTokenConfig(address token) external view returns (TokenConfig memory);
    function totalGasCollected(address token) external view returns (uint256);
    function getDeposit() external view returns (uint256);
    function calculateTokenCost(address token, uint256 nativeGasCost)
        external
        view
        returns (uint256 tokenAmount, uint256 effectivePrice);

    // --- Administrative Functions ---
    function setVerifyingSigner(address signer, bool active) external;
    function setTokenConfig(
        address token,
        address oracle,
        uint8 tokenDecimals,
        uint8 oracleDecimals,
        uint32 maxOracleAge,
        uint16 markupBps,
        bool isPriceTokenPerEth
    ) external;
    function removeToken(address token) external;
    function pause() external;
    function unpause() external;

    // --- EntryPoint Deposit & Stake Controls ---
    function deposit() external payable;
    function withdrawDeposit(address payable to, uint256 amount) external;
    function addStake(uint32 unstakeDelaySec) external payable;
    function unlockStake() external;
    function withdrawStake(address payable to) external;
    function withdrawToken(IERC20 token, address to, uint256 amount) external;
    function withdrawNative(address payable to, uint256 amount) external;
}
