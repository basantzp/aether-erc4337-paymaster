// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IAetherPaymaster} from "../interfaces/IAetherPaymaster.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";

/// @title AetherGasLib
/// @notice Mathematical and cryptographic helper library for ERC-4337 gas and oracle accounting
library AetherGasLib {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant WEI_PER_ETH = 1e18;

    /// @dev ERC-4337 validation success / failure indicators
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    /// @notice Fetches and validates live price from Chainlink oracle feed
    /// @param oracle Address of the AggregatorV3Interface contract
    /// @param maxOracleAge Maximum allowed staleness in seconds
    /// @return price Validated positive price
    function getValidatedPrice(address oracle, uint32 maxOracleAge) internal view returns (uint256 price) {
        if (oracle == address(0)) revert IAetherPaymaster.InvalidAddress();

        // forge-lint: disable-next-line(unused-return)
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(oracle).latestRoundData();

        if (answer <= 0) revert IAetherPaymaster.InvalidOraclePrice(answer);
        // forge-lint: disable-next-line(block-timestamp)
        if (updatedAt == 0 || updatedAt > block.timestamp) {
            revert IAetherPaymaster.InvalidOracleTimestamp(updatedAt);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > maxOracleAge) {
            revert IAetherPaymaster.StaleOraclePrice(block.timestamp, updatedAt, maxOracleAge);
        }
        if (answeredInRound < roundId) {
            revert IAetherPaymaster.IncompleteOracleRound(roundId, answeredInRound);
        }

        // casting to 'uint256' is safe because answer > 0 is verified above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer);
    }

    /// @notice Calculates required token amount for a given native gas cost in wei
    /// @dev Multiplications are ordered before divisions to preserve maximum precision without overflow
    /// @param config TokenConfig settings
    /// @param nativeGasCost Gas cost in wei (18 decimals)
    /// @return tokenAmount Total tokens required including fee markup
    /// @return price Raw oracle price used
    function computeTokenCost(IAetherPaymaster.TokenConfig memory config, uint256 nativeGasCost)
        internal
        view
        returns (uint256 tokenAmount, uint256 price)
    {
        price = getValidatedPrice(config.oracle, config.maxOracleAge);

        uint256 markupMultiplier = BPS_DENOMINATOR + config.markupBps;

        if (config.isPriceTokenPerEth) {
            // Oracle price is in Tokens per 1 ETH (e.g. ETH/USD = 2500 * 10^8)
            if (config.tokenDecimals >= config.oracleDecimals) {
                uint256 scale = 10 ** (config.tokenDecimals - config.oracleDecimals);
                // (nativeGasCost * price * scale * markupMultiplier) / (WEI_PER_ETH * BPS_DENOMINATOR)
                tokenAmount = (nativeGasCost * price * scale * markupMultiplier) / (WEI_PER_ETH * BPS_DENOMINATOR);
            } else {
                uint256 scale = 10 ** (config.oracleDecimals - config.tokenDecimals);
                // (nativeGasCost * price * markupMultiplier) / (WEI_PER_ETH * scale * BPS_DENOMINATOR)
                tokenAmount = (nativeGasCost * price * markupMultiplier) / (WEI_PER_ETH * scale * BPS_DENOMINATOR);
            }
        } else {
            // Oracle price is in ETH per 1 Token (e.g. Token/ETH: 1 Token = price * 10^-oracleDecimals ETH)
            uint256 totalDecimals = uint256(config.oracleDecimals) + uint256(config.tokenDecimals);
            if (totalDecimals >= 18) {
                uint256 scale = 10 ** (totalDecimals - 18);
                // (nativeGasCost * scale * markupMultiplier) / (price * BPS_DENOMINATOR)
                tokenAmount = (nativeGasCost * scale * markupMultiplier) / (price * BPS_DENOMINATOR);
            } else {
                uint256 scale = 10 ** (18 - totalDecimals);
                // (nativeGasCost * markupMultiplier) / (price * scale * BPS_DENOMINATOR)
                tokenAmount = (nativeGasCost * markupMultiplier) / (price * scale * BPS_DENOMINATOR);
            }
        }
    }

    /// @notice Packs authorizer, validUntil, and validAfter into canonical uint256 validationData
    /// @param success Whether signature or op validation succeeded
    /// @param validAfter Earliest timestamp the op is valid
    /// @param validUntil Latest timestamp the op is valid (0 = infinite)
    function packValidationData(bool success, uint48 validAfter, uint48 validUntil) internal pure returns (uint256) {
        return ERC4337Utils.packValidationData(success, validAfter, validUntil);
    }
}
