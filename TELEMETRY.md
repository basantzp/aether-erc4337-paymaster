# ⚡ Aether ERC-4337 Paymaster Verification Telemetry

> **Repository**: [`basantzp/aether-erc4337-paymaster`](https://github.com/basantzp/aether-erc4337-paymaster)  
> **Stack**: Solidity 0.8.28 + ERC-4337 v0.7 + EIP-712 + Chainlink  
> **Last Verification Run**: `2026-11-03 23:48:03 +0545`  
> **Verification Status**: 🟢 **57/57 Tests & 128k Invariants Proven**  
> **Author**: `basantzp <basantpok90@gmail.com>`

---

## 🧪 Verified Paymaster Properties
- **EIP-712 Gas Sponsorship**: Strict validationData timestamp windows [validUntil][validAfter] and replay nonces.
- **Oracle ERC-20 Gas Payment**: Real-time Chainlink price scaling, 4-tier staleness checks, and post-op token refunds.
- **Invariant Monotonicity**: Native deposit integrity, USDC/DAI solvency, and fee growth proven across 128,000 calls.

### Verification Summary
```text
Suite result: ok. 25 passed; 0 failed; 0 skipped; finished in 5.34ms (6.34ms CPU time)
Ran 1 test suite in 21.85ms (5.34ms CPU time): 25 tests passed, 0 failed, 0 skipped (25 total tests)
```
