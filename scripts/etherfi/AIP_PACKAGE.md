# AIP input package — ether.fi Cash Aave V4 whitelabel instance (OP Mainnet)

Everything the Aave team needs to draft the AIP for the ether.fi Cash whitelabel instance.
Prepared by ether.fi; the AIP itself is authored and submitted by Aave (per agreement with
Aave eng, 2026-07-27). All addresses below are deployed and Etherscan-verified on OP Mainnet.

## 1. Summary (suggested AIP framing)

The Aave DAO authorizes the dedicated Aave V4 whitelabel instance deployed and fully managed by
ether.fi on OP Mainnet, powering ether.fi Cash. The instance runs unmodified Aave V4 core
(hub, configurators, config engine, canonical LiquidationLogic) plus one ether.fi-specific
spoke implementation that gates `borrow` to ether.fi Cash Safes. ether.fi administers the
instance entirely (Owner Safe); Nonce Capital operates risk parameters (Operator Safe); Aave
governance holds no roles on the instance.

## 2. Governance references

- ARFC: https://governance.aave.com/t/arfc-deploy-a-dedicated-aave-v4-whitelabel-instance-fully-managed-by-etherfi-on-op-mainnet-to-power-ether-fi-cash/25314
- Aave eng review (21 resolved threads): https://github.com/aave/aave-v4/pull/1325
- Repo of record: https://github.com/etherfi-protocol/aave-v4 (`main`; cut from aave/aave-v4 `main@2524fe40`)
- Full parameter specification: [`scripts/etherfi/LAUNCH_SPEC.md`](./LAUNCH_SPEC.md)

## 3. Deployed contracts (OP Mainnet, chainId 10 — all Etherscan-verified)

| Contract                     | Address                                      | Notes                            |
| ---------------------------- | -------------------------------------------- | -------------------------------- |
| AccessManager                | `0x188d7173772499FB6375F23FdFd130CE6107286b` | admin = Owner Safe               |
| CASH_HUB (proxy)             | `0x66753c4e3fC84f1eD0e3C267C927284E9d90C572` | stock HubInstance                |
| Hub implementation           | `0x697aF34263Bc8E5E6B0e6b0C37A1EC58CeDE2cE9` |                                  |
| HubConfigurator              | `0xA39bEf2fD611fb9c5a69D63277b4Af97a30F0dbC` |                                  |
| InterestRateStrategy         | `0x51d07C362f9c4716F96EbEB63DB985EF9D2aCd7C` |                                  |
| CASH_SPOKE (proxy)           | `0xdffcC3536D932eb51Df51a7F5FA407c4270d5308` | EtherFiSpokeInstance             |
| Spoke implementation         | `0xA1f75D801633a1941cae6670352d627884dC3b68` | borrow gated to Cash Safes       |
| SpokeConfigurator            | `0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b` |                                  |
| AaveOracle (spoke)           | `0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8` |                                  |
| TreasurySpoke (fee receiver) | `0x7EB4d25F137868662350603A2863F682287b0768` |                                  |
| AaveV4ConfigEngine           | `0x84210b3087E952Be0f3610fD75f0f045995eAF22` | stateless                        |
| LiquidationLogic (canonical) | `0x88dF535473C5adf1f57789734A05E555F7Deb8DB` | same address as Ethereum mainnet |
| Launch payload (phase 1)     | `0xBc0D2823611cb0C1c1a598DdC4d051289E368449` | dormant configuration            |
| Activation payload (phase 2) | `0x5F64dE77e63E9CDfF87d818FA373c8593b0b20f3` | flips spokes active              |

Position managers and SignatureGateway are deliberately **not deployed** (borrow-gate security
invariant; see `EtherFiSpokeInstance` natspec).

## 4. Administration

| Role                                                 | Holder                                                                         |
| ---------------------------------------------------- | ------------------------------------------------------------------------------ |
| Instance owner (all admin roles, payload executor)   | Owner Safe `0x082B85ED50F1cd120C597EF860ece712e54CE844` (2/6)                  |
| Risk curator (caps, curves, CFs, liquidation params) | Operator Safe — Nonce Capital `0x23c30c38d73a0D1609ffAAe47aA7d6D1a3e46f03`     |
| Emergency guardians (one-way halt/pause/freeze only) | Both Safes + Hypernative executor `0x9AF1298993DC1f397973C62A5D47a284CF76844D` |

Custom roles carved out by the launch payload: `HUB_RISK_CURATOR_ROLE` (201),
`SPOKE_RISK_CURATOR_ROLE` (401), `HUB_GUARDIAN_ROLE` (202), `SPOKE_GUARDIAN_ROLE` (402).
Aave governance holds no roles on this instance.

## 5. Launch configuration (detail in LAUNCH_SPEC.md)

- 19 assets listed; borrowable at launch: USDC (add 10M / draw 7M) and WETH (1,000 / 100);
  all others collateral-only
- Liquidation engine: target HF 1.24, HF-for-max-bonus 0.90, 10% liquidation fee on every reserve
- Borrow access: ether.fi Cash Safes only, enforced in `EtherFiSpokeInstance.borrow` via
  `EtherFiDataProvider` (`0xDC515Cb479a64552c5A11a57109C314E40A1A778`); with no position
  managers deployed, borrow proceeds can only be paid to the borrowing safe itself
- Launch process: two-phase (configure dormant → on-chain verification → activate), mirroring
  the Aave V4 Avalanche activation (proposal 504); execution via Owner Safe delegatecall
  (3CP item: https://github.com/etherfi-protocol/3CP-secure/pull/613)

## 6. Verification (reproducible by anyone)

```bash
git clone https://github.com/etherfi-protocol/aave-v4 && cd aave-v4
export RPC_OPTIMISM=<op rpc>
make etherfi-validate   # every pinned address has live, matching code
make etherfi-verify     # post-activation: full field-by-field state vs the parameter sheet
```

The deploy scripts assert every deployed address against the reviewed registry
(`src/etherfi/AaveV4EtherfiCash.sol`) — reproduce-or-revert.

## 7. Asks bundled with the AIP

1. **aave-address-book entry**: `src/etherfi/AaveV4EtherfiCash.sol` is written in address-book
   format and can be upstreamed verbatim (as `AaveV4EtherfiCash`).
2. Confirmation of the whitelabel/BUSL license authorization as the AIP's subject.
3. (Later, non-blocking) migration path to Aave's permissioned Spoke via proxy upgrade once
   available — per the 2026-07-27 agreement.

## 8. Post-activation addendum (to be appended once the 3CP executes)

- Phase-1 / phase-2 execution tx hashes
- `make etherfi-verify` output (VERIFIED — ACTIVE)
- Final caps in effect for the internal-testing window (reduced from launch values by the
  Operator Safe; to be restored to the sheet values at full production)
