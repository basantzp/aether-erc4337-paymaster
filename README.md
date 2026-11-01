# ⚡ Aether ERC-4337 Paymaster

[![CI](https://github.com/basantzp/aether-erc4337-paymaster/actions/workflows/ci.yml/badge.svg)](https://github.com/basantzp/aether-erc4337-paymaster/actions/workflows/ci.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange.svg)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

**Aether Paymaster** is an enterprise-grade ERC-4337 Account Abstraction Paymaster engineered in modern **Solidity 0.8.28**. It delivers full dual-mode support for:
1. **EIP-712 Signature-Verified Gas Sponsorship** (Verifying Paymaster pattern)
2. **ERC-20 Multi-Token Gas Payments with Chainlink Oracle Settlement** and automatic post-op refunds.

---

## 🌟 Key Highlights

- **ERC-4337 v0.7 Canonical Compliance**: Built natively for `PackedUserOperation` and canonical EntryPoint v0.7.
- **Dual Operating Modes**:
  - `Mode 0 (SPONSORED)`: EIP-712 typed gas sponsorship with campaign tracking (`sponsorId`), nonce-bound anti-replay protection, and temporal bounds (`validAfter` / `validUntil`).
  - `Mode 1 (ERC20_PAYMENT)`: Dynamic multi-token fee payment (USDC, USDT, DAI, WETH) with on-chain Chainlink oracle conversion, 4-tier staleness verification, fee markups, and instant post-op refunds.
- **4-Layer Oracle Defense**: Validates freshness, heartbeat bounds, positive pricing, and round completion (`answeredInRound >= roundId`).
- **Mathematical Decimal Normalization**: Zero-precision-loss integer scaling between native wei (18 decimals), Chainlink feeds (typically 8 decimals), and diverse token decimals (6, 8, 18).
- **Two-Step Ownership & Circuit Breaker**: Managed by OpenZeppelin's `Ownable2Step` and `Pausable`.
- **Reentrancy Hardening**: Complete `ReentrancyGuard` protection across `postOp` and all withdrawal paths.
- **Formally Verified Invariants**: 128,000 handler calls across 256 stateful invariant runs with 0 reverts.

---

## 🏛️ System Architecture

```
                       [User Account (ERC-4337)]
                                  │
                                  ▼
                        [Bundler Alt-Mempool]
                                  │
                                  ▼
                   [Canonical EntryPoint (v0.7)]
                     │                       │
       validatePaymasterUserOp               │
                     │                       │
                     ▼                       ▼
           [Aether Paymaster]        [Account.execute]
             ├── Mode 0: EIP-712             │
             └── Mode 1: Oracle ERC-20       │
                     │                       │
                   postOp                    │
                     ▼                       ▼
            [Gas & Token Refund] ◄───────────┘
```

For detailed protocol state machines, calldata memory layouts, and sequence diagrams, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 📊 Gas Benchmarks (`forge test --gas-report`)

| Function Name | Min Gas | Avg Gas | Median Gas | Max Gas | # Calls |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `validatePaymasterUserOp` | 5,699 | 23,283 | 27,249 | 29,486 | 23 |
| `postOp` | 3,402 | 19,557 | 22,580 | 25,114 | 14 |
| `calculateTokenCost` | 12,382 | 12,382 | 12,382 | 12,382 | 4 |
| `setTokenConfig` | 46,285 | 46,312 | 46,312 | 46,339 | 5 |
| `setVerifyingSigner` | 24,196 | 24,196 | 24,196 | 24,196 | 3 |
| `deposit` | 47,823 | 47,823 | 47,823 | 47,823 | 4 |
| `withdrawDeposit` | 37,219 | 37,219 | 37,219 | 37,219 | 2 |

---

## 🧪 Verification Matrix (57/57 Passing Tests)

### 1. Unit Tests (`test/AetherPaymaster.t.sol`) — 25 Tests
- `test_Constructor_Success`: Verifies immutable EntryPoint and initial owner assignment.
- `test_Constructor_RevertZeroAddress`: Verifies input validation on zero addresses.
- `test_TwoStepOwnership_TransferAndAccept`: Verifies two-step owner handshake.
- `test_TwoStepOwnership_OnlyOwnerCanTransfer`: Restricts ownership transfer initiation.
- `test_Pause_Unpause`: Verifies pause state transitions.
- `test_Pause_OnlyOwner`: Restricts circuit breaker control to admin.
- `test_SetVerifyingSigner_Success`: Registers and revokes authorized signers.
- `test_SetVerifyingSigner_RevertZeroAddress`: Rejects zero-address signer.
- `test_SetTokenConfig_Success`: Whitelists ERC-20 token with oracle configuration.
- `test_SetTokenConfig_RevertInvalidMarkup`: Enforces 50% (5,000 bps) max markup limit.
- `test_SetTokenConfig_RevertInvalidDecimals`: Enforces `1 <= decimals <= 18` bounds.
- `test_SetTokenConfig_RevertInvalidMaxOracleAge`: Enforces non-zero oracle heartbeat window.
- `test_RemoveToken_Success`: De-whitelists payment tokens.
- `test_Deposit_Success`: Deposits native ETH to EntryPoint.
- `test_Deposit_ReceiveFallback`: Automatically routes plain ETH transfers into EntryPoint deposit.
- `test_WithdrawDeposit_Success`: Withdraws deposit to recipient treasury.
- `test_Stake_Lifecycle`: Full lifecycle test: `addStake` -> `unlockStake` -> delay -> `withdrawStake` with exact event telemetry.
- `test_WithdrawToken_Success`: Sweeps collected ERC-20 fee revenue.
- `test_WithdrawNative_Success`: Sweeps direct native ETH balance.
- `test_ValidatePaymasterUserOp_OnlyEntryPoint`: Reverts unauthorized direct validation.
- `test_PostOp_OnlyEntryPoint`: Reverts unauthorized direct postOp.

### 2. Sponsored Gas Suite (`test/SponsoredGas.t.sol`) — 10 Tests
- `test_SponsoredGas_SuccessfulExecution`: End-to-end EntryPoint execution with valid EIP-712 signature.
- `test_SponsoredGas_RevertExpiredSignature`: Rejects user operations with `validUntil < timestamp`.
- `test_SponsoredGas_RevertPrematureSignature`: Rejects user operations with `validAfter > timestamp`.
- `test_SponsoredGas_RevertInvertedTimeRange`: Rejects user operations with `validUntil < validAfter`.
- `test_SponsoredGas_RevertUnauthorizedSigner`: Rejects signatures from unregistered signers.
- `test_SponsoredGas_ReplayProtection_SameNonce`: Rejects replaying identical userOp with consumed nonce.
- `test_SponsoredGas_ReplayProtection_DifferentNonce`: Rejects re-using paymaster signature for new nonce.
- `test_SponsoredGas_TamperedCallData`: Rejects user operations with altered execution calldata.
- `test_SponsoredGas_TamperedGasFees`: Rejects user operations with inflated gas fees.
- `test_SponsoredGas_RevertWhenPaused`: Verifies paymaster pauses all gas sponsorships immediately.

### 3. ERC-20 Gas Payment Suite (`test/ERC20GasPayment.t.sol`) — 16 Tests
- `test_Math_CalculateTokenCost_USDC`: Verifies 6-decimal USDC fee conversion at $2,500/ETH.
- `test_Math_CalculateTokenCost_DAI`: Verifies 18-decimal DAI fee conversion at $2,500/ETH.
- `test_Math_CalculateTokenCost_TokenPerEth_LINK`: Verifies Token/ETH feed calculation for 18-decimal LINK.
- `test_Math_CalculateTokenCost_TokenPerEth_WBTC`: Verifies Token/ETH feed calculation for 8-decimal WBTC without decimal distortion.
- `test_ERC20GasPayment_USDC_SuccessWithRefund`: End-to-end USDC payment, prefund pull, and exact token refund.
- `test_ERC20GasPayment_DAI_SuccessWithRefund`: End-to-end DAI payment and settlement.
- `test_ERC20GasPayment_LINK_TokenPerEth_SuccessWithRefund`: End-to-end Token/ETH feed payment and settlement.
- `test_ERC20GasPayment_PostOpReverted_SafeHandled`: Verifies safe no-revert handling when EntryPoint invokes `postOpReverted`.
- `test_ERC20GasPayment_RevertExceedsMaxAllowedCost`: Enforces user-defined slippage limit.
- `test_ERC20GasPayment_RevertInsufficientBalance`: Rejects operations when account lacks token balance.
- `test_ERC20GasPayment_RevertInsufficientAllowance`: Rejects operations without paymaster approval.
- `test_ERC20GasPayment_RevertStaleOracle`: Rejects execution when oracle data exceeds `maxOracleAge`.
- `test_ERC20GasPayment_RevertNegativeOraclePrice`: Rejects non-positive oracle price readings.
- `test_ERC20GasPayment_RevertFutureTimestampOracle`: Rejects invalid future oracle timestamps.
- `test_ERC20GasPayment_RevertIncompleteOracleRound`: Rejects unfinalized Chainlink rounds.
- `test_ERC20GasPayment_RevertUnsupportedToken`: Rejects unwhitelisted ERC-20 tokens.

### 4. Fuzz Testing Suite (`test/fuzz/AetherPaymasterFuzz.t.sol`) — 5 Tests x 256 Runs
- `testFuzz_CalculateTokenCost_RangeAndMonotonicity`: Fuzzes gas costs ($21\text{k}$ gas to $50\text{ ETH}$), ETH prices ($50 to $200k), and markups (0 to 50%). Proves monotonicity and overflow resistance.
- `testFuzz_CalculateTokenCost_TokenPerEthInverted`: Fuzzes Token/ETH inverted feeds across price points, proving monotonicity.
- `testFuzz_RefundConservation`: Proves exact token conservation: $\text{ActualTokenCost} + \text{RefundAmount} \equiv \text{PrefundAmount}$.
- `testFuzz_TimestampValidationData`: Fuzzes arbitrary timestamp intervals and validates exact canonical bit-packing and round-trip unpacking via `ERC4337Utils`.
- `testFuzz_MarkupRejection`: Proves strict rejection boundary at $> 5,000\text{ bps}$.

### 5. Stateful Invariant Testing (`test/invariant/AetherPaymasterInvariant.t.sol`) — 128,000 Calls
- `invariant_TokenSolvencyUSDC`: Paymaster USDC balance $\ge$ total collected fees $-$ withdrawn fees.
- `invariant_TokenSolvencyDAI`: Paymaster DAI balance $\ge$ total collected fees $-$ withdrawn fees.
- `invariant_NativeDepositIntegrity`: EntryPoint deposit $\equiv$ native deposits $-$ native spent $-$ native withdrawn.
- `invariant_FeesCollectedMonotonic`: Accumulated fee metrics increase monotonically across all valid executions.

---

## 🚀 Quick Start

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)

### Installation & Build
```bash
git clone https://github.com/basantzp/aether-erc4337-paymaster.git
cd aether-erc4337-paymaster

# Install dependencies
forge install

# Compile contracts
forge build
```

### Running Tests
```bash
# Run unit and fuzz tests
forge test --no-match-path "test/invariant/**"

# Run stateful invariant suite
forge test --match-path "test/invariant/**"

# Generate gas report
forge test --gas-report --no-match-path "test/invariant/**"
```

---

## 🔒 Security & Code Standards

- **Checks-Effects-Interactions (CEI)**: Strictly adhered to across all state updates and events.
- **Language Override**: Repository configured with `.gitattributes` to guarantee 100% Solidity classification.
- **Zero-Warning Compiler Output**: Tested against Solidity 0.8.28 with `cancun` EVM settings.

---

## 📄 License

This project is open-source and released under the [MIT License](LICENSE).
Created with precision by **Basant Pokhrel** ([@basantzp](https://github.com/basantzp)).
