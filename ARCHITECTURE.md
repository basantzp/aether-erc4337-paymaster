# 🏛️ Aether Paymaster — Architecture & Technical Specification

> **Aether Paymaster** is a production-grade ERC-4337 Account Abstraction Paymaster engineered in modern Solidity (0.8.28) that natively supports **EIP-712 signature-verified gas sponsorship** and **ERC-20 multi-token gas payments** settled against real-time Chainlink price feeds with dynamic refunds and formal invariant guarantees.

---

## 1. System Overview & Flow

```
                                  +-----------------------------+
                                  |         User Account        |
                                  |   (ERC-4337 Smart Wallet)   |
                                  +-----------------------------+
                                                 |
                                                 | 1. Signs PackedUserOperation
                                                 v
                                  +-----------------------------+
                                  |      Alt-Mempool Bundler    |
                                  +-----------------------------+
                                                 |
                                                 | 2. handleOps([userOp], beneficiary)
                                                 v
+-------------------------------------------------------------------------------------------------------+
|                                       CANONICAL ENTRYPOINT (v0.7)                                     |
+-------------------------------------------------------------------------------------------------------+
|                                                                                                       |
|  [Phase 1: Verification]                                                                              |
|  1. EntryPoint.getUserOpHash(userOp)                                                                  |
|  2. EntryPoint -> Paymaster.validatePaymasterUserOp(userOp, userOpHash, maxCost)                      |
|                                                                                                       |
|      +---------------------------------------------------------------------------------------------+  |
|      |                                  AETHER PAYMASTER                                           |  |
|      +---------------------------------------------------------------------------------------------+  |
|      |  IF Mode 0 (SPONSORED):                                                                     |  |
|      |    * Decode EIP-712 signature, validUntil, validAfter, sponsorId                            |  |
|      |    * Verify signature against isVerifyingSigner mapping                                    |  |
|      |    * Verify temporal validity: validAfter <= block.timestamp <= validUntil                  |  |
|      |    * Return context & packed validationData                                                 |  |
|      |                                                                                             |  |
|      |  IF Mode 1 (ERC20_PAYMENT):                                                                 |  |
|      |    * Check token whitelisting & query Chainlink oracle                                      |  |
|      |    * Verify oracle heartbeat, round completeness, and price sanity                         |  |
|      |    * Compute prefundTokenAmount for maxCost + markup                                        |  |
|      |    * Verify slippage: prefundTokenAmount <= maxAllowedTokenCost                             |  |
|      |    * safeTransferFrom(sender, paymaster, prefundTokenAmount)                                |  |
|      |    * Return context & packed validationData                                                 |  |
|      +---------------------------------------------------------------------------------------------+  |
|                                                                                                       |
|  3. EntryPoint -> Account.validateUserOp(userOp, userOpHash, missingFunds)                            |
|                                                                                                       |
|  [Phase 2: Execution]                                                                                 |
|  4. EntryPoint -> Account.execute(callData)                                                           |
|                                                                                                       |
|  [Phase 3: Post-Op Settlement]                                                                        |
|  5. EntryPoint computes actualGasCost = actualGasUsed * actualFeePerGas                               |
|  6. EntryPoint debits actualGasCost from Paymaster's native deposit                                   |
|  7. EntryPoint -> Paymaster.postOp(mode, context, actualGasCost, actualFeePerGas)                      |
|                                                                                                       |
|      +---------------------------------------------------------------------------------------------+  |
|      |                                  AETHER PAYMASTER                                           |  |
|      +---------------------------------------------------------------------------------------------+  |
|      |  IF Mode 0 (SPONSORED):                                                                     |  |
|      |    * Emit GasSponsored(sender, sponsorId, actualGasCost, actualFeePerGas)                   |  |
|      |                                                                                             |  |
|      |  IF Mode 1 (ERC20_PAYMENT):                                                                 |  |
|      |    * Compute actualTokenCost = (actualGasCost * price * markup)                             |  |
|      |    * refundAmount = prefundTokenAmount - actualTokenCost                                    |  |
|      |    * IF refundAmount > 0: safeTransfer(token, sender, refundAmount)                         |  |
|      |    * totalGasCollected[token] += actualTokenCost                                            |  |
|      |    * Emit GasTokenPaid(sender, token, actualGasCost, actualTokenCost, refundAmount)         |  |
|      +---------------------------------------------------------------------------------------------+  |
|                                                                                                       |
|  8. EntryPoint transfers actualGasCost native ETH to Bundler beneficiary                              |
+-------------------------------------------------------------------------------------------------------+
```

---

## 2. Dual Operation Modes

### Mode 0: EIP-712 Gas Sponsorship (Verifying Paymaster)

In sponsored mode, a decentralized application, wallet provider, or campaign sponsor subsidizes 100% of the gas cost on behalf of the user.

#### EIP-712 Domain Separator
```solidity
keccak256(
    abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256(bytes("AetherPaymaster")),
        keccak256(bytes("1")),
        block.chainid,
        address(this)
    )
);
```

#### Sponsorship TypeHash
```solidity
bytes32 public constant SPONSOR_PAYMASTER_TYPEHASH = keccak256(
    "SponsorPaymaster("
        "address sender,"
        "uint256 nonce,"
        "bytes32 initCodeHash,"
        "bytes32 callDataHash,"
        "bytes32 accountGasLimits,"
        "uint256 preVerificationGas,"
        "bytes32 gasFees,"
        "uint256 paymasterVerificationGasLimit,"
        "uint256 paymasterPostOpGasLimit,"
        "uint48 validUntil,"
        "uint48 validAfter,"
        "bytes32 sponsorId,"
        "uint256 chainId,"
        "address paymaster"
    ")"
);
```

#### Replay and Anti-Tampering Defenses
1. **Parameter Immutability**: Any modification to `sender`, `nonce`, `callData`, `accountGasLimits`, `preVerificationGas`, `gasFees`, or paymaster gas limits alters the digest and invalidates the signature.
2. **Cross-Chain Replay Defense**: Bound directly to `block.chainid` and the domain separator.
3. **Cross-Paymaster Replay Defense**: Binds `address(paymaster)` explicitly.
4. **Temporal Expiration Bounds**: Enforced via `validUntil` (upper bound) and `validAfter` (lower bound).

---

### Mode 1: ERC-20 Multi-Token Gas Payments with Oracle Settlement

In ERC-20 mode, users pay for gas using any whitelisted token (USDC, USDT, DAI, WETH, WBTC).

#### Token Configuration (`TokenConfig`)
```solidity
struct TokenConfig {
    bool isSupported;           // Whitelist status
    address oracle;             // Chainlink AggregatorV3Interface
    uint8 tokenDecimals;        // ERC-20 decimals (e.g. 6 for USDC, 18 for DAI)
    uint8 oracleDecimals;       // Feed decimals (typically 8)
    uint32 maxOracleAge;        // Maximum heartbeat staleness in seconds
    uint16 markupBps;           // Fee markup in basis points (max 5,000 = 50%)
    bool isPriceTokenPerEth;    // true if oracle returns Token/ETH, false if ETH/Token
}
```

#### 4-Layer Chainlink Oracle Defense
To prevent oracle exploitation, flash crashes, and stale data attacks:
```solidity
(uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
    AggregatorV3Interface(oracle).latestRoundData();

if (answer <= 0) revert InvalidOraclePrice(answer);
if (updatedAt == 0 || updatedAt > block.timestamp) revert InvalidOracleTimestamp(updatedAt);
if (block.timestamp - updatedAt > maxOracleAge) revert StaleOraclePrice(...);
if (answeredInRound < roundId) revert IncompleteOracleRound(...);
```

#### Precision Mathematical Pricing
1. **When `isPriceTokenPerEth == true` (e.g. ETH/USD = $2,500 * 10^8)**:
   - For `tokenDecimals >= oracleDecimals`:
     $$\text{TokenAmount} = \frac{\text{GasCostWei} \times \text{Price} \times 10^{\text{tokenDecimals} - \text{oracleDecimals}} \times (10000 + \text{markupBps})}{10^{18} \times 10000}$$
   - For `tokenDecimals < oracleDecimals`:
     $$\text{TokenAmount} = \frac{\text{GasCostWei} \times \text{Price} \times (10000 + \text{markupBps})}{10^{18} \times 10^{\text{oracleDecimals} - \text{tokenDecimals}} \times 10000}$$
2. **When `isPriceTokenPerEth == false` (e.g. LINK/ETH, WBTC/ETH: Price in ETH per 1 Token)**:
   - For $\text{totalDecimals} = \text{oracleDecimals} + \text{tokenDecimals} \ge 18$:
     $$\text{TokenAmount} = \frac{\text{GasCostWei} \times 10^{\text{totalDecimals} - 18} \times (10000 + \text{markupBps})}{\text{Price} \times 10000}$$
   - For $\text{totalDecimals} < 18$:
     $$\text{TokenAmount} = \frac{\text{GasCostWei} \times (10000 + \text{markupBps})}{\text{Price} \times 10^{18 - \text{totalDecimals}} \times 10000}$$
3. All operations order multiplications before divisions to preserve absolute integer precision.

#### Token Pre-Charge and Instant Safe Refund Flow
- During `validatePaymasterUserOp`:
  $$\text{PrefundAmount} = \text{computeTokenCost}(\text{maxCost})$$
  $$\text{IERC20}(\text{token}).\text{safeTransferFrom}(\text{sender}, \text{paymaster}, \text{PrefundAmount})$$
  Locks `maxCost` and `prefundTokenAmount` into `context`.
- During `postOp`:
  - Protects against double-revert if `mode == PostOpMode.postOpReverted`.
  - Reconciles cost deterministically without redundant or fragile secondary oracle calls:
  $$\text{ActualTokenCost} = \frac{\text{PrefundAmount} \times \text{ActualGasCost}}{\text{MaxCost}}$$
  $$\text{RefundAmount} = \text{PrefundAmount} - \text{ActualTokenCost}$$
  $$\text{IERC20}(\text{token}).\text{safeTransfer}(\text{sender}, \text{RefundAmount})$$

---

## 3. Administrative Controls & Security Guarantees

1. **Two-Step Ownership (`Ownable2Step`)**:
   Prevents irreversible ownership forfeiture. The prospective owner must explicitly accept ownership via `acceptOwnership()`.
2. **Reentrancy Protection (`ReentrancyGuard`)**:
   `nonReentrant` protects `postOp` and all withdrawal methods (`withdrawDeposit`, `withdrawStake`, `withdrawToken`, `withdrawNative`).
3. **Emergency Circuit Breaker (`Pausable`)**:
   `pause()` halts validation of user operations immediately, causing `validatePaymasterUserOp` to return `SIG_VALIDATION_FAILED`.
4. **Input Sanitization & Decimals Validation**:
   Enforces `1 <= tokenDecimals <= 18`, `1 <= oracleDecimals <= 18`, and `maxOracleAge > 0` on all registered token feeds.
5. **Checks-Effects-Interactions (CEI)**:
   All events and internal state accounting occur prior to external token transfers or call dispatches.
6. **Markup Limit Protection**:
   Markup cannot exceed 5,000 bps (50%), preventing accidental or malicious over-charging.
7. **Canonical ValidationData Packing**:
   Uses OpenZeppelin's audited `ERC4337Utils.packValidationData` ensuring `(validAfter, validUntil, authorizer)` bit layout conforms to canonical ERC-4337 specifications.
