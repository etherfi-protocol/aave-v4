// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// aave-address-book format (see AaveV4Avalanche.sol there) so this file can be upstreamed
// verbatim once the instance is live. Until then it is the single pinned source for the
// launch pipeline.
//
// Entry classes:
//   - VERIFIED: checked on-chain 2026-07-23/24 — tokens via symbol()/decimals(), feeds via
//     decimals()/description()/latestAnswer() (the exact IPriceFeed interface AaveOracle
//     consumes), Safes via live code + getThreshold().
//   - PREDICTED: from a full fork simulation of the instance deployment run as the launch
//     deployer (0xf8a86ea1Ac39EC529814c377Bd484387D395421e). All are CREATE2 via the Safe
//     Singleton Factory (0x914d7Fec…43d7) and either reproduce exactly or revert; the Cash
//     Spoke additionally requires the deployer to start at nonce 3 with the exact tx sequence
//     (the AaveOracle address, plain `new`, feeds into the spoke deployment). The preflight
//     validator blocks the pipeline until code exists at every address.

/// @notice Core contracts and administration of the ether.fi Cash Aave V4 instance (OP Mainnet).
library AaveV4EtherfiCash {
  // administration multisigs — VERIFIED (Safe v1.4.1)
  address internal constant OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;
  address internal constant OPERATOR_SAFE = 0x23c30c38d73a0D1609ffAAe47aA7d6D1a3e46f03; // Nonce risk curator

  // instance — PREDICTED pending deployment
  address internal constant ACCESS_MANAGER = 0x188d7173772499FB6375F23FdFd130CE6107286b;
  address internal constant CONFIG_ENGINE = 0x84210b3087E952Be0f3610fD75f0f045995eAF22; // deployer-independent
  address internal constant HUB_CONFIGURATOR = 0xA39bEf2fD611fb9c5a69D63277b4Af97a30F0dbC;
  address internal constant SPOKE_CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;

  // canonical Aave LiquidationLogic (same address as Ethereum mainnet and Avalanche; per
  // review, the spoke links against this instead of a self-deployed copy). Pre-deployed on
  // OP 2026-07-30 via `make etherfi-predeploy-liquidationlogic` (Safe Singleton Factory +
  // the canonical salt reproduce the address, which proves the code is byte-identical to
  // the Ethereum mainnet library) and source-verified on OP Etherscan. The etherfi make
  // targets pin FOUNDRY_LIBRARIES to this value; the preflight validator checks it has
  // code on OP.
  address internal constant LIQUIDATION_LOGIC = 0x88dF535473C5adf1f57789734A05E555F7Deb8DB;

  // launch deployer EOA — must act from nonce 3 with no interleaved transactions (the
  // AaveOracle and Cash Spoke pins depend on it); every other launch transaction
  // (LiquidationLogic pre-deploy, config engine) must come from a different account
  address internal constant LAUNCH_DEPLOYER = 0xf8a86ea1Ac39EC529814c377Bd484387D395421e;

  // guardian executors — STAGED (zero = not yet onboarded; EtherfiCashLaunchPayload skips
  // zero entries, so these can be filled and the payload redeployed without logic changes).
  // Guardian roles are one-way emergency stops only (pause/freeze/halt) — safe behind hot
  // keys because they can never resume, loosen, or move anything.
  address internal constant GUARDIAN_HYPERNATIVE =
    address(0x9AF1298993DC1f397973C62A5D47a284CF76844D); // CONFIRMED — Hypernative executor
  // Curator-automation slot: intentionally the Operator Safe until the automation KMS is set
  // up (duplicate grant with the Safe's own guardian membership — harmless, AccessManager
  // updates rather than reverts). Once the KMS EOA exists, grant it the guardian roles
  // directly from the Owner Safe (grantRole 202/402) — no payload or constant change needed.
  address internal constant GUARDIAN_CURATOR = 0x23c30c38d73a0D1609ffAAe47aA7d6D1a3e46f03;

  // timelock governance (parameters in AaveV4EtherfiCashTimelock, migration in
  // scripts/etherfi/timelock). The Timelock Safe is the sole PROPOSER of the timelock — a
  // signer set distinct from the Owner (Admin) Safe, which keeps a veto (CANCELLER_ROLE) and the
  // un-halt / un-pause roles.
  address internal constant TIMELOCK_SAFE = 0xd442635bc9bF83E21bBA8B65e224F5Db6a011166;
  // EtherFiTimelock — VERIFIED 2026-09-17: CREATE2 via the Safe Singleton Factory with
  // AaveV4EtherfiCashTimelock.SALT and constant constructor args (deployer-independent); live
  // runtime code == type(EtherFiTimelock).runtimeCode, and the migration script asserts the pin
  // equals the predicted address on every run.
  address internal constant TIMELOCK = 0xbaCa0cD6B69Eef3257e2D122b22ddEE8AeE5e283;
}

/// @notice Hubs of the ether.fi Cash Aave V4 instance.
library AaveV4EtherfiCashHubs {
  address internal constant CASH_HUB = 0x66753c4e3fC84f1eD0e3C267C927284E9d90C572; // PREDICTED
  address internal constant CASH_HUB_IR_STRATEGY = 0x51d07C362f9c4716F96EbEB63DB985EF9D2aCd7C; // PREDICTED
  address internal constant CASH_HUB_PROXY_ADMIN = 0xed57ae702efc1774A131689E9D9b876E4063F6F5; // VERIFIED 2026-09-09 (EIP-1967 admin slot)
}

/// @notice Spokes of the ether.fi Cash Aave V4 instance.
library AaveV4EtherfiCashSpokes {
  address internal constant CASH_SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308; // PREDICTED (nonce 3 + exact sequence; EtherFiSpokeInstance, canonical-lib link)
  address internal constant CASH_SPOKE_IMPLEMENTATION = 0xA1f75D801633a1941cae6670352d627884dC3b68; // PREDICTED (canonical-lib link)
  address internal constant CASH_SPOKE_PROXY_ADMIN = 0xAc44Bde208560611E8C865EE721Dc9CCb54a0596; // VERIFIED 2026-09-09 (EIP-1967 admin slot)
  address internal constant TREASURY_SPOKE = 0x7EB4d25F137868662350603A2863F682287b0768; // PREDICTED (fee receiver)
  address internal constant TREASURY_SPOKE_PROXY_ADMIN = 0x917A5aeeAcf54Ab58d690E18f80453820E473aCC; // VERIFIED 2026-09-09 (EIP-1967 admin slot)
}

/// @notice Launch assets: underlying + price source (+ decimals), all VERIFIED on-chain.
/// address(0) = staged (asset skipped by the payload until pinned).
library AaveV4EtherfiCashAssets {
  address internal constant USDC_UNDERLYING = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
  address internal constant USDC_ORACLE = 0x87C74CB64b69FD6b338EE15F9772F05668914ED7;
  uint8 internal constant USDC_DECIMALS = 6;

  address internal constant USDT_UNDERLYING = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
  address internal constant USDT_ORACLE = 0x3Fe46756Ece51Dac6dd202F2e2b45454D4F8b89c;
  uint8 internal constant USDT_DECIMALS = 6;

  address internal constant EURC_UNDERLYING = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
  address internal constant EURC_ORACLE = 0xc700125927b9f6ffae2F7b77D1D14cC725bAe628;
  uint8 internal constant EURC_DECIMALS = 6;

  address internal constant FRXUSD_UNDERLYING = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
  address internal constant FRXUSD_ORACLE = 0xf1cF6275a3DD9DEf2bF902BCc25BfE4E1aB9Cc1b;
  uint8 internal constant FRXUSD_DECIMALS = 18;

  address internal constant WETH_UNDERLYING = 0x4200000000000000000000000000000000000006;
  address internal constant WETH_ORACLE = 0xCFe45EF2B9E138E5A2e1C25592441D5c556B3ca3; // "ETH / USD"
  uint8 internal constant WETH_DECIMALS = 18;

  address internal constant WEETH_UNDERLYING = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
  address internal constant WEETH_ORACLE = 0x9e1cAf5C8E7aB34628EA5973C0F2945bBD5109aC;
  uint8 internal constant WEETH_DECIMALS = 18;

  address internal constant EBTC_UNDERLYING = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
  address internal constant EBTC_ORACLE = 0x0fdF97E16f0bd50513Eed2771d4BC31265166488;
  uint8 internal constant EBTC_DECIMALS = 8;

  address internal constant EUSD_UNDERLYING = 0x939778D83b46B456224A33Fb59630B11DEC56663;
  address internal constant EUSD_ORACLE = 0x106399f5fCb6b1401b99A0B12F075721d518aD63;
  uint8 internal constant EUSD_DECIMALS = 18;

  address internal constant ETHFI_UNDERLYING = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
  address internal constant ETHFI_ORACLE = 0x823d8De4d50454E7e1529Ed8b390DaD973f3Daba;
  uint8 internal constant ETHFI_DECIMALS = 18;

  address internal constant SETHFI_UNDERLYING = 0x86B5780b606940Eb59A062aA85a07959518c0161;
  address internal constant SETHFI_ORACLE = 0x14c7600aC4023ccCf72fe81b1d475764c9214b13;
  uint8 internal constant SETHFI_DECIMALS = 18;

  address internal constant OP_UNDERLYING = 0x4200000000000000000000000000000000000042;
  address internal constant OP_ORACLE = 0x6D53a69EBC75cFeDf319F77569a4F732f75AED79;
  uint8 internal constant OP_DECIMALS = 18;

  address internal constant WHYPE_UNDERLYING = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
  address internal constant WHYPE_ORACLE = 0xc4ca8A733aB9686753F1fc47443c46dEdb7b3670;
  uint8 internal constant WHYPE_DECIMALS = 18;

  address internal constant BEHYPE_UNDERLYING = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
  address internal constant BEHYPE_ORACLE = 0x259992e490BbfB94A08B51C753FBd001CC3b9Fb8;
  uint8 internal constant BEHYPE_DECIMALS = 18;

  address internal constant LIQUID_ETH_UNDERLYING = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
  address internal constant LIQUID_ETH_ORACLE = 0x4829C107Bc9896792c6f54bBF2Cb6F3322f20eCD;
  uint8 internal constant LIQUID_ETH_DECIMALS = 18;

  address internal constant LIQUID_BTC_UNDERLYING = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
  address internal constant LIQUID_BTC_ORACLE = 0xc5b599B15826d50b1f9Ef9dF7a68a14cCb4123b3;
  uint8 internal constant LIQUID_BTC_DECIMALS = 8;

  address internal constant LIQUID_USD_UNDERLYING = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
  address internal constant LIQUID_USD_ORACLE = 0x7E916FE60091497c74D4aEd43A7Cf348e40AE38C;
  uint8 internal constant LIQUID_USD_DECIMALS = 6;

  address internal constant LIQUID_RESERVE_UNDERLYING = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;
  address internal constant LIQUID_RESERVE_ORACLE = 0x6D7b3725Faa812FE5e29EB67068882A71228b0CB;
  uint8 internal constant LIQUID_RESERVE_DECIMALS = 18;

  address internal constant WEEUR_UNDERLYING = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
  address internal constant WEEUR_ORACLE = 0x4fdc1B6638f277bc2468Fb910f833678DF119f26;
  uint8 internal constant WEEUR_DECIMALS = 18;

  address internal constant LIQUID_RWA_UNDERLYING = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;
  address internal constant LIQUID_RWA_ORACLE = 0x6148eE0E0923Ed5F0cCde2600a85166f4E250154;
  uint8 internal constant LIQUID_RWA_DECIMALS = 18;

  // ZCHF (Frankencoin, CHF stablecoin) — post-launch collateral-only listing through the timelock
  // (scripts/etherfi/listings). Underlying VERIFIED 2026-09-17 (symbol ZCHF, 18 decimals, native OP
  // token — not an ether.fi OFT). The price is the mainnet Chainlink CHF / USD aggregator
  // (0x449d117117838fFA61263B61dA6301AA2a88B13A) relayed over LayerZero to the prod OracleSink on
  // OP (0x7cb68ddc781153d9417E08bAf6A64e801e398d42, keyed by MAINNET ZCHF
  // 0xB58E61C3098d85632Df34EecfB899A1Ed80921cB), read by an immutable cash-v3 OracleSinkPriceFeed
  // (8 decimals, "ZCHF / USD", 7-day relay bound = the bound of every live cash-v3 Summer Lend feed on OP,
  // no stable snap: CHF is not USD).
  // ORACLE is PREDICTED: CREATE3 via the cash-v3 EtherFiDeployer (0xFCD957b5913d607BF2222280093421B1e2Af6f30)
  // with salt keccak256("ZchfUsdFeed") — cash-v3 scripts/zchf-usdt0-paxgy/DeployZchfUsdt0PaxgyProdFeeds
  // asserts the deployment lands here; the listing script refuses to schedule until code exists.
  address internal constant ZCHF_UNDERLYING = 0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553;
  address internal constant ZCHF_ORACLE = 0x7445E49137F073B836eB93Fd2929820d730b948C; // "ZCHF / USD"
  uint8 internal constant ZCHF_DECIMALS = 18;

  // USDT0 (Tether omnichain USDT, LayerZero OFT) — post-launch collateral-only listing through the
  // timelock (scripts/etherfi/listings). Underlying VERIFIED 2026-09-23 (symbol "USD₮0", 6 decimals,
  // not the legacy bridged USDT above). Priced like USDT: the reserve source is the LIVE
  // "Capped USDT / USD" CAPO adapter the USDT reserve reads (AaveOracle.getReserveSource(2),
  // 2026-09-23) — the same underlying value, so no new feed is deployed.
  address internal constant USDT0_UNDERLYING = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
  address internal constant USDT0_ORACLE = 0x7579977643ee68946DB95d9Cb5fF582674619025; // "Capped USDT / USD"
  uint8 internal constant USDT0_DECIMALS = 6;

  // PAXGy (Paxos "Pax Gold Yield", mainnet 0x6c6494Fd9962eB98B94ffA48F6679058F820700e) — the OP token is
  // the ether.fi shadow OFT iPAXGy ("EtherFi PAXGy", the iPAXG shape; cash-mainnet-asset-listing), VERIFIED
  // 2026-09-23: 18 decimals, Operating Safe owner, LayerZero peer of the mainnet OFT adapter
  // 0x3108f4C4C1fA0dD25523222258cd51c4C9D3b40C. Post-launch collateral-only listing through the
  // timelock (scripts/etherfi/listings). ORACLE is PREDICTED:
  // the cash-v3 "PAXGy / USD" ChainlinkPriceFeed (CREATE3 via the EtherFiDeployer, salt
  // "PaxgyUsdFeed", 8 decimals) = Chainlink "PAXGy / Gold Exchange Rate"
  // (0xDD12d3De4964eC93F81752c8F2552f053124B180, 18 dec, 24h heartbeat, 7-day bound) x the "XAU / USD"
  // ChainlinkPriceFeed (0xf66C01179bA7326C95a5d3324Bc364f34CA7c7Af, salt "XauUsdFeed", over Chainlink
  // XAU / USD 0x8F7bFb42Bf7421c2b34AAD619be4654bFa7B3B8B, 7-day bound). 7 days = the bound of every
  // live cash-v3 Summer Lend feed on OP (verified 2026-09-23). Rate-composed, deliberately uncapped.
  address internal constant PAXGY_UNDERLYING = 0x5168E0cDeb3f308F47fDF0D9A2E250A2135C3cF5;
  address internal constant PAXGY_ORACLE = 0x9B92A2D4468ff3Df8A6Be50Ad043E8a5165459c2; // "PAXGy / USD"
  uint8 internal constant PAXGY_DECIMALS = 18;
}

/// @notice Launch spoke caps (whole tokens, uint40) — FINAL per the 'Submit to AAVE' section
/// of Proposal-Aave-V4-Parameters-by-Nonce (2026-07-23 17:25 revision). Only USDC and WETH
/// are borrowable at launch; every other asset is collateral-only (draw cap 0 by design).
/// Not part of the address-book upstream — launch configuration only.
library AaveV4EtherfiCashCaps {
  uint40 internal constant USDC_ADD_CAP = 10_000_000;
  uint40 internal constant USDC_DRAW_CAP = 7_000_000; // max util 70% < 92% kink
  uint40 internal constant USDT_ADD_CAP = 10_000_000;
  uint40 internal constant WETH_ADD_CAP = 1_000;
  uint40 internal constant WETH_DRAW_CAP = 100;
  uint40 internal constant EURC_ADD_CAP = 5_000_000;
  uint40 internal constant EURC_DRAW_CAP = 0; // borrowable follow-up: opened CLOSED on purpose; the risk curator (201) raises it
  uint40 internal constant USDT_DRAW_CAP = 0; // opened for borrowing CLOSED on purpose (scripts/etherfi/listings); the risk curator (201) raises it
  uint40 internal constant FRXUSD_ADD_CAP = 5_000_000;
  uint40 internal constant WEETH_ADD_CAP = 1_000;
  uint40 internal constant EBTC_ADD_CAP = 200;
  uint40 internal constant EUSD_ADD_CAP = 1_000_000;
  uint40 internal constant ETHFI_ADD_CAP = 2_000_000;
  uint40 internal constant SETHFI_ADD_CAP = 2_000_000;
  uint40 internal constant OP_ADD_CAP = 1_000_000;
  uint40 internal constant WHYPE_ADD_CAP = 100_000;
  uint40 internal constant BEHYPE_ADD_CAP = 100_000;
  uint40 internal constant LIQUID_ETH_ADD_CAP = 1_000;
  uint40 internal constant LIQUID_BTC_ADD_CAP = 100;
  uint40 internal constant LIQUID_USD_ADD_CAP = 5_000_000;
  uint40 internal constant LIQUID_RESERVE_ADD_CAP = 1_000_000;
  uint40 internal constant WEEUR_ADD_CAP = 1_000_000;
  uint40 internal constant LIQUID_RWA_ADD_CAP = 1_000_000;
  // ZCHF — PROPOSED (~$1.2M at listing-time CHF/USD); collateral-only, draw cap 0 by design
  uint40 internal constant ZCHF_ADD_CAP = 0;
  // USDT0 — PROPOSED (~$5M; the USDT reserve sits at 30M live); listed BORROWABLE with the draw cap
  // pinned to 0 (opened closed on purpose; the risk curator (201) raises it)
  uint40 internal constant USDT0_ADD_CAP = 5_000_000;
  uint40 internal constant USDT0_DRAW_CAP = 0;
  // PAXGy — PROPOSED placeholder (iPAXG sits at 300); collateral-only, draw cap 0 by design
  uint40 internal constant PAXGY_ADD_CAP = 0;
}

/// @notice Collateral-side parameters of the reserves listed after launch (BPS), applied by the
/// listing scripts (scripts/etherfi/listings) through the timelock. Collateral-only house style of the
/// launch payload: flat 0% curve (kink 99%), 0% liquidity fee, 10% liquidation fee, collateral risk
/// 0, receive-shares on, not borrowable. Not part of the address-book upstream — configuration only.
library AaveV4EtherfiCashCollateral {
  // shared by every collateral-only reserve (EtherfiCashLaunchPayload._collateralOnly)
  uint16 internal constant COLLATERAL_ONLY_OPTIMAL_USAGE_RATIO = 99_00;
  uint256 internal constant COLLATERAL_ONLY_LIQUIDITY_FEE = 0;
  uint16 internal constant LIQUIDATION_FEE = 10_00;
  uint24 internal constant COLLATERAL_RISK = 0;

  // ZCHF — PROPOSED pending the risk curator (Nonce). A non-USD, CDP-backed stablecoin: below the
  // fiat-backed stables (CF 95% / bonus 1% at launch), at the live EURC bonus (7.5%). Confirm before
  // signing; the script reads every value back after execution.
  uint16 internal constant ZCHF_COLLATERAL_FACTOR = 85_00;
  uint32 internal constant ZCHF_MAX_LIQUIDATION_BONUS = 107_50; // 100_00 = 0% bonus

  // USDT0 — PROPOSED: mirrors the live USDT reserve (CF 90% / max bonus 5%, read 2026-09-23); the
  // debt side (borrowable, curve, fee) is in AaveV4EtherfiCashRates.
  uint16 internal constant USDT0_COLLATERAL_FACTOR = 90_00;
  uint32 internal constant USDT0_MAX_LIQUIDATION_BONUS = 105_00;

  // PAXGy — PROPOSED placeholder: mirrors the live iPAXG reserve (CF 80% / max bonus 10%).
  uint16 internal constant PAXGY_COLLATERAL_FACTOR = 75_00;
  uint32 internal constant PAXGY_MAX_LIQUIDATION_BONUS = 110_00;
}

/// @notice Debt-side parameters of the reserves made borrowable after launch (BPS). The launch
/// curves live in EtherfiCashLaunchPayload; these are applied by scripts/etherfi/borrowable
/// together with the AaveV4EtherfiCashCaps draw cap (set to 0 explicitly: borrowable but closed
/// until the risk curator, HUB_RISK_CURATOR_ROLE, raises it with updateSpokeDrawCap). Not part of
/// the address-book upstream — configuration only.
library AaveV4EtherfiCashRates {
  // EURC — PROPOSED: mirrors USDC's LIVE hub configuration (read 2026-09-17: fee 30%, kink 85%,
  // base 3%, slope1 1.25%, slope2 10%, max 14.25%), not the launch sheet. Confirm with the risk
  // curator (Nonce) before signing; the script reads every value back after execution.
  uint256 internal constant EURC_LIQUIDITY_FEE = 30_00;
  uint16 internal constant EURC_OPTIMAL_USAGE_RATIO = 85_00;
  uint32 internal constant EURC_BASE_DRAWN_RATE = 3_00;
  uint32 internal constant EURC_RATE_GROWTH_BEFORE_OPTIMAL = 1_25;
  uint32 internal constant EURC_RATE_GROWTH_AFTER_OPTIMAL = 10_00;

  // USDT (opened for borrowing post-launch, scripts/etherfi/listings) and USDT0 (listed borrowable
  // there) — PROPOSED: both mirror USDC's LIVE hub configuration (re-read 2026-09-23: fee 30%, kink
  // 85%, base 3%, slope1 1.25%, slope2 10%). Confirm with the risk curator (Nonce) before signing.
  uint256 internal constant USDT_LIQUIDITY_FEE = 30_00;
  uint16 internal constant USDT_OPTIMAL_USAGE_RATIO = 85_00;
  uint32 internal constant USDT_BASE_DRAWN_RATE = 3_00;
  uint32 internal constant USDT_RATE_GROWTH_BEFORE_OPTIMAL = 1_25;
  uint32 internal constant USDT_RATE_GROWTH_AFTER_OPTIMAL = 10_00;
  uint256 internal constant USDT0_LIQUIDITY_FEE = 30_00;
  uint16 internal constant USDT0_OPTIMAL_USAGE_RATIO = 85_00;
  uint32 internal constant USDT0_BASE_DRAWN_RATE = 3_00;
  uint32 internal constant USDT0_RATE_GROWTH_BEFORE_OPTIMAL = 1_25;
  uint32 internal constant USDT0_RATE_GROWTH_AFTER_OPTIMAL = 10_00;
}

/// @notice EtherFiTimelock parameters (cash-v3 contract, OpenZeppelin TimelockController). Not part of
/// the address-book upstream — governance configuration only.
library AaveV4EtherfiCashTimelock {
  uint256 internal constant MIN_DELAY = 24 hours; // 86400
  /// @dev Constructor executor. address(0) = OPEN execution at deployment, so the first
  /// scheduled operation (phase 1b-i) can be executed by anyone; that operation seats
  /// TIMELOCK_SAFE as the only EXECUTOR and revokes the open seat, so every later matured
  /// operation (starting with phase 1b-ii) needs a Timelock Safe signature to execute (the delay
  /// and the cancellers still guard the queue).
  address internal constant EXECUTOR = address(0);
  /// @dev no external admin: the timelock administers its own roles behind the delay
  address internal constant ADMIN = address(0);
  /// @dev CREATE2 salt (Safe Singleton Factory); bump the suffix for a new deployment
  bytes32 internal constant SALT = keccak256('ETHERFI_CASH_AAVE_V4_TIMELOCK_V1');
  /// @dev keccak256('CANCELLER_ROLE') = 0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783
  bytes32 internal constant CANCELLER_ROLE = keccak256('CANCELLER_ROLE');
  /// @dev keccak256('EXECUTOR_ROLE') = 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63
  bytes32 internal constant EXECUTOR_ROLE = keccak256('EXECUTOR_ROLE');

  // salts of the migration's scheduled operations (deterministic ids let the script track them)
  /// @dev phase 1b-i: EXECUTOR_ROLE to TIMELOCK_SAFE, open EXECUTOR seat (address(0)) revoked
  bytes32 internal constant OP_SALT_EXECUTOR = keccak256('ETHERFI_CASH_TIMELOCK_OP_EXECUTOR_V1');
  /// @dev phase 1b-ii: CANCELLER_ROLE to the Admin + Operator Safes (first Timelock-Safe-only execute)
  bytes32 internal constant OP_SALT_CANCELLERS =
    keccak256('ETHERFI_CASH_TIMELOCK_OP_CANCELLERS_V1');
  /// @dev phase 3: the Admin Safe's timelocked AccessManager roles revoked THROUGH the queue — the
  /// first timelock -> AccessManager call doubles as the proof of the path. POINT OF NO RETURN
  bytes32 internal constant OP_SALT_REVOCATIONS =
    keccak256('ETHERFI_CASH_TIMELOCK_OP_REVOCATIONS_V1');
  bytes32 internal constant OP_SALT_TREASURY_ACCEPT =
    keccak256('ETHERFI_CASH_TIMELOCK_OP_TREASURY_ACCEPT_V1');

  // salts of post-migration governance operations (one per listing; bump the suffix to re-run)
  /// @dev ZCHF collateral-only listing: addAsset + addSpoke + addReserve (scripts/etherfi/listings)
  bytes32 internal constant OP_SALT_ZCHF_LISTING =
    keccak256('ETHERFI_CASH_TIMELOCK_OP_ZCHF_LISTING_V1');
  /// @dev ONE operation: USDT0 listed borrowable + the live USDT reserve opened for borrowing
  /// (updateLiquidityFee + updateBorrowable) - scripts/etherfi/listings
  bytes32 internal constant OP_SALT_USDT0_LISTING =
    keccak256('ETHERFI_CASH_TIMELOCK_OP_USDT0_LISTING_V1');
  /// @dev PAXGy collateral-only listing (scripts/etherfi/listings)
  bytes32 internal constant OP_SALT_PAXGY_LISTING =
    keccak256('ETHERFI_CASH_TIMELOCK_OP_PAXGY_LISTING_V1');
}

/// @notice AccessManager roles of the instance: Aave Roles.sol IDs, the launch payload's curator /
/// guardian roles and the timelock migration's restart roles, plus the configurator selectors the
/// migration moves. Plain values on purpose (no imports) so they can be compared to the plan by
/// eye; the migration helpers cross-check every one of them against Roles.sol, the launch payload
/// and the configurator interfaces at runtime. Not part of the address-book upstream.
library AaveV4EtherfiCashRoles {
  uint64 internal constant ADMIN_ROLE = 0; // Roles.ACCESS_MANAGER_ADMIN_ROLE
  uint64 internal constant HUB_FEE_MINTER_ROLE = 102; // Roles.HUB_FEE_MINTER_ROLE
  uint64 internal constant HUB_DEFICIT_ELIMINATOR_ROLE = 103; // Roles.HUB_DEFICIT_ELIMINATOR_ROLE
  uint64 internal constant HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE = 200; // Roles.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE
  uint64 internal constant HUB_RISK_CURATOR_ROLE = 201; // EtherfiCashLaunchPayload
  uint64 internal constant HUB_GUARDIAN_ROLE = 202; // EtherfiCashLaunchPayload
  uint64 internal constant HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE = 203; // timelock migration: restart path — updateSpokeHalted (Admin Safe); guardians keep the one-way haltSpoke/haltAsset
  uint64 internal constant SPOKE_USER_POSITION_UPDATER_ROLE = 302; // Roles.SPOKE_USER_POSITION_UPDATER_ROLE
  uint64 internal constant SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE = 400; // Roles.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE
  uint64 internal constant SPOKE_RISK_CURATOR_ROLE = 401; // EtherfiCashLaunchPayload
  uint64 internal constant SPOKE_GUARDIAN_ROLE = 402; // EtherfiCashLaunchPayload
  uint64 internal constant SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE = 403; // timelock migration: restart path — updatePaused/updateFrozen (Admin Safe); guardians keep the one-way pause*/freeze*

  string internal constant HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE_LABEL =
    'HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE';
  string internal constant SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE_LABEL =
    'SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE';

  /// @dev 22 HubConfigurator + 24 SpokeConfigurator selectors (Roles.sol); the whole map is read back
  uint256 internal constant CONFIGURATOR_SELECTOR_COUNT = 46;
}
