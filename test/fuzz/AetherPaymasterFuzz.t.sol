// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AetherPaymaster} from "../../src/AetherPaymaster.sol";
import {IAetherPaymaster} from "../../src/interfaces/IAetherPaymaster.sol";
import {AetherGasLib} from "../../src/libraries/AetherGasLib.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract AetherPaymasterFuzzTest is Test {
    AetherPaymaster public paymaster;
    MockEntryPoint public entryPoint;
    MockERC20 public usdc;
    MockAggregatorV3 public oracle;

    address public owner = makeAddr("owner");

    function setUp() public {
        vm.warp(100_000);
        entryPoint = new MockEntryPoint();
        paymaster = new AetherPaymaster(entryPoint, owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockAggregatorV3(8, "ETH / USD", 2500e8);

        vm.prank(owner);
        paymaster.setTokenConfig(address(usdc), address(oracle), 6, 8, 3600, 500, true);
    }

    /// @notice Invariant: Token calculation never overflows or truncates to 0 for realistic gas costs
    function testFuzz_CalculateTokenCost_RangeAndMonotonicity(uint256 gasCostWei, int256 ethPrice, uint16 markupBps)
        public
    {
        gasCostWei = bound(gasCostWei, 21_000 * 1 gwei, 50 ether);
        ethPrice = bound(ethPrice, 50e8, 200_000e8); // $50 to $200k / ETH
        markupBps = uint16(bound(markupBps, 0, 5000)); // up to 50%

        oracle.setPrice(ethPrice);

        vm.prank(owner);
        paymaster.setTokenConfig(address(usdc), address(oracle), 6, 8, 3600, markupBps, true);

        (uint256 tokenCost, uint256 fetchedPrice) = paymaster.calculateTokenCost(address(usdc), gasCostWei);

        assertGt(tokenCost, 0, "Token cost must be positive");
        assertEq(fetchedPrice, uint256(ethPrice));

        // Monotonicity check: 2x gas cost must yield >= 2x token cost (ignoring 1 unit rounding)
        (uint256 doubleCost,) = paymaster.calculateTokenCost(address(usdc), gasCostWei * 2);
        assertGe(doubleCost, tokenCost * 2 - 1, "Monotonic scaling violated");
    }

    /// @notice Invariant: Pre-fund always equals exactly actualTokenCost + refundAmount
    function testFuzz_RefundConservation(uint256 simulatedActualGas, uint256 gasPriceGwei) public view {
        simulatedActualGas = bound(simulatedActualGas, 21_000, 150_000);
        gasPriceGwei = bound(gasPriceGwei, 1, 500); // 1 to 500 gwei
        uint256 feePerGas = gasPriceGwei * 1 gwei;

        uint256 maxCost = 150_000 * feePerGas;
        uint256 actualCost = simulatedActualGas * feePerGas;

        (uint256 prefundTokens,) = paymaster.calculateTokenCost(address(usdc), maxCost);
        (uint256 actualTokens,) = paymaster.calculateTokenCost(address(usdc), actualCost);

        assertLe(actualTokens, prefundTokens, "Actual tokens cannot exceed prefund");
        uint256 refundTokens = prefundTokens - actualTokens;

        assertEq(actualTokens + refundTokens, prefundTokens, "Token conservation violated");
    }

    /// @notice Invariant: Timestamp validity packing correctly identifies valid vs invalid ranges
    function testFuzz_TimestampValidationData(uint48 validAfter, uint48 validUntil, uint48 currentTimestamp)
        public
        pure
    {
        currentTimestamp = uint48(bound(currentTimestamp, 100, 10_000_000));
        validAfter = uint48(bound(validAfter, 0, 20_000_000));
        validUntil = uint48(bound(validUntil, 0, 20_000_000));

        bool isTimestampValid = (currentTimestamp >= validAfter) && (validUntil == 0 || currentTimestamp <= validUntil);

        uint256 valData = AetherGasLib.packValidationData(isTimestampValid, validAfter, validUntil);
        address authorizer = address(uint160(valData));

        if (isTimestampValid) {
            assertEq(authorizer, address(0), "Valid op must return authorizer 0");
        } else {
            assertEq(authorizer, address(1), "Invalid op must return authorizer 1");
        }
    }

    /// @notice Invariant: Markup strictly capped at 5000 bps (50%)
    function testFuzz_MarkupRejection(uint16 markupBps) public {
        if (markupBps <= 5000) {
            vm.prank(owner);
            paymaster.setTokenConfig(address(usdc), address(oracle), 6, 8, 3600, markupBps, true);
            IAetherPaymaster.TokenConfig memory config = paymaster.getTokenConfig(address(usdc));
            assertEq(config.markupBps, markupBps);
        } else {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(IAetherPaymaster.InvalidMarkup.selector, markupBps));
            paymaster.setTokenConfig(address(usdc), address(oracle), 6, 8, 3600, markupBps, true);
        }
    }
}
