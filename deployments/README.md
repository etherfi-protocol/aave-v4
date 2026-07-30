# Deployments

Machine-readable records of the live ether.fi Cash Aave V4 whitelabel instances, one file per
network. These are the canonical addresses for integrators (e.g. cash-v3 modules), monitoring,
and tooling.

| Network  | Chain ID | File                                     | Status            |
| -------- | -------- | ---------------------------------------- | ----------------- |
| Optimism | 10       | [`optimism/10.json`](./optimism/10.json) | live (2026-07-30) |

## Consuming

```bash
# a single address
jq -r '.spokes.CASH_SPOKE.proxy' deployments/optimism/10.json

# every borrowable reserve
jq -r '.reserves | to_entries[] | select(.value.borrowable) | .key' deployments/optimism/10.json
```

## Relationship to the other sources of truth

- **`src/etherfi/AaveV4EtherfiCash.sol`** — the same addresses as a Solidity library, in
  aave-address-book format, consumed by the on-chain payloads and scripts.
- **`scripts/etherfi/LAUNCH_SPEC.md`** — the full human-readable parameter specification
  (risk parameters, interest curves, caps) with the launch/verification narrative.
- **These JSON files** — the machine-readable extract for off-chain integrators.

All three are kept consistent; the JSON is generated from the same deployment as the library and
verified live on-chain (every address has matching code). Regenerate/verify with
`make etherfi-verify` (reads the instance state and checks it against the payload spec).

## Notes for integrators (Aave V4 differs from V3)

- Borrow/supply/withdraw/repay target the **spoke** (`spokes.CASH_SPOKE.proxy`), not a single
  Pool, and are keyed by **`reserveId`** (uint), not token address. Resolve it as
  `assetId = hub.getAssetId(underlying)` then `reserveId = spoke.getReserveId(hub, assetId)`.
- **Borrow is gated**: `onBehalfOf` must be an ether.fi Cash Safe (per the `borrowGate`
  dataProvider). No position managers are deployed, so the borrower and the position owner must
  be the same address.
- There are no aTokens / debt tokens; positions are share-accounted on the spoke.
