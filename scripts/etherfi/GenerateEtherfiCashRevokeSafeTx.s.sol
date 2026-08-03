// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2} from 'forge-std/console2.sol';

import {IAccessManager} from 'src/dependencies/openzeppelin/IAccessManager.sol';
import {IAaveOracle} from 'src/spoke/interfaces/IAaveOracle.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {ISpokeConfigurator} from 'src/spoke/interfaces/ISpokeConfigurator.sol';
import {AaveV4EtherfiCash, AaveV4EtherfiCashSpokes} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {EtherfiCashScriptBase} from 'scripts/etherfi/EtherfiCashScriptBase.s.sol';

/// @title GenerateEtherfiCashRevokeSafeTx
/// @notice Produces one Owner-Safe transaction batch that:
///   1. revokes the Safe's own direct HUB_CONFIGURATOR_ROLE (101) and
///      SPOKE_CONFIGURATOR_ROLE (301) on the AccessManager;
///   2. updates the Cash Spoke liquidationBonusFactor to 90% (9000 BPS);
///   3. swaps the price source of three reserves to the new feed proxies
///      (EURC, frxUSD, WHYPE; the other supplied feeds are 18-decimal or unlisted - see oracleUpdates).
/// Every calldata is fork-simulated (pranked as the Owner Safe, in batch order) before the
/// JSON is written: the revokes must leave the configurator contracts' own 101/301 intact,
/// and each new price source must pass the AaveOracle's decimals check and return a live
/// non-zero price (enforced by setReserveSource).
///
/// All are plain CALLs (operation 0) — unlike the launch payloads, these can be proposed
/// with the Safe web Transaction Builder.
///
///   make etherfi-revoke-tx
///   (or: forge script scripts/etherfi/GenerateEtherfiCashRevokeSafeTx.s.sol --rpc-url optimism)
contract GenerateEtherfiCashRevokeSafeTxScript is EtherfiCashScriptBase {
  uint64 internal constant HUB_CONFIGURATOR_ROLE = 101;
  uint64 internal constant SPOKE_CONFIGURATOR_ROLE = 301;
  uint16 internal constant LIQUIDATION_BONUS_FACTOR = 90_00; // BPS

  /// @dev reserveId == assetId on the Cash Spoke (verified at launch).
  struct OracleUpdate {
    string label;
    uint256 reserveId;
    address feed;
  }

  error RoleStillHeld(uint64 roleId, address account);
  error RoleLost(uint64 roleId, address account);
  error SafeCallFailed(uint256 txIndex, bytes returndata);
  error BonusFactorNotUpdated(uint16 actual);
  error PriceSourceNotUpdated(uint256 reserveId, address actual);

  /// @notice New price feed proxies — ONLY the ones the AaveOracle can accept (its DECIMALS
  /// is immutable at 8, and setReserveSource rejects any source with different decimals).
  /// Checked on-chain 2026-08-03 via decimals()/description()/latestAnswer():
  ///   included:  EURC/USD (8 dec), FRXUSD/USD (8 dec), HYPE/USD (8 dec, WHYPE reserve)
  ///   EXCLUDED — 18-decimal feeds, oracle reverts InvalidSourceDecimals; need an 8-decimal
  ///   adapter before they can be set:
  ///     weETH  0xed5D3c24A8B0591CB3029Ca272DD1721343a9C1D ("WEETH / USD Exchange Rate")
  ///     ETHFI  0x9A3C975993354354080d815e313eEEdEb907fF34 ("ETHFI / USD")
  ///     beHYPE 0x8792DD897CFB1F6e81dd6C7c4491f97ed79eaD24 ("BEHYPE / USD Exchange Rate")
  ///   EXCLUDED — no listed reserve on the Cash Spoke: PAXG/USD, GHO/USD.
  function oracleUpdates() public pure returns (OracleUpdate[3] memory updates) {
    updates[0] = OracleUpdate('EURC/USD', 3, 0xDb2A51a5DD73865F1b0d1c33F99a96E0e7ae742c);
    updates[1] = OracleUpdate('frxUSD/USD', 4, 0x14a2Aa4189Aed564bFB04071c99f308C7ffd5283);
    updates[2] = OracleUpdate('HYPE/USD (WHYPE)', 11, 0x961f6a07bFc62F618a4fA737eDe08F23aD6Da67F);
  }

  function run() external {
    _requireOpMainnet();

    address ownerSafe = AaveV4EtherfiCash.OWNER_SAFE;
    address accessManager = AaveV4EtherfiCash.ACCESS_MANAGER;
    address spokeConfigurator = AaveV4EtherfiCash.SPOKE_CONFIGURATOR;
    address cashSpoke = AaveV4EtherfiCashSpokes.CASH_SPOKE;
    _requireCode('owner safe', ownerSafe);
    _requireCode('access manager', accessManager);
    _requireCode('spoke configurator', spokeConfigurator);

    OracleUpdate[3] memory oracles = oracleUpdates();

    // batch: [0] revoke 101, [1] revoke 301, [2] bonus factor, [3..8] price sources
    address[] memory targets = new address[](3 + oracles.length);
    bytes[] memory calldatas = new bytes[](3 + oracles.length);

    targets[0] = accessManager;
    calldatas[0] = abi.encodeCall(IAccessManager.revokeRole, (HUB_CONFIGURATOR_ROLE, ownerSafe));
    targets[1] = accessManager;
    calldatas[1] = abi.encodeCall(IAccessManager.revokeRole, (SPOKE_CONFIGURATOR_ROLE, ownerSafe));
    targets[2] = spokeConfigurator;
    calldatas[2] = abi.encodeCall(
      ISpokeConfigurator.updateLiquidationBonusFactor,
      (cashSpoke, LIQUIDATION_BONUS_FACTOR)
    );
    for (uint256 i; i < oracles.length; i++) {
      _requireCode(oracles[i].label, oracles[i].feed);
      targets[3 + i] = spokeConfigurator;
      calldatas[3 + i] = abi.encodeCall(
        ISpokeConfigurator.updateReservePriceSource,
        (cashSpoke, oracles[i].reserveId, oracles[i].feed)
      );
    }

    _simulate(ownerSafe, accessManager, cashSpoke, targets, calldatas, oracles);

    string memory txs;
    for (uint256 i; i < targets.length; i++) {
      txs = string.concat(txs, i == 0 ? '' : ',\n', _txJson(targets[i], calldatas[i]));
    }
    vm.createDir('output/etherfi', true);
    vm.writeFile(
      'output/etherfi/safe-revoke-101-301-tx.json',
      string.concat(
        '{\n',
        '  "description": "Owner Safe: revoke own roles 101/301, liquidationBonusFactor -> 9000 BPS, update 3 reserve price sources",\n',
        '  "chainId": "10",\n',
        '  "safe": "',
        vm.toString(ownerSafe),
        '",\n',
        '  "transactions": [\n',
        txs,
        '\n  ]\n',
        '}\n'
      )
    );

    console2.log('simulation passed:');
    console2.log('  - roles 101/301 revoked from the Safe, configurators keep theirs');
    console2.log('  - liquidationBonusFactor -> 9000 BPS');
    console2.log('  - 3 price sources updated, each feed live with matching decimals');
    console2.log('  - skipped: PAXG/USD, GHO/USD (unlisted); weETH, ETHFI, beHYPE (18-dec feeds)');
    console2.log('wrote output/etherfi/safe-revoke-101-301-tx.json (6 txs, operation 0)');
  }

  /// @dev Pranks the Owner Safe and executes the exact generated calldata in batch order.
  function _simulate(
    address ownerSafe,
    address accessManager,
    address cashSpoke,
    address[] memory targets,
    bytes[] memory calldatas,
    OracleUpdate[3] memory oracles
  ) internal {
    _requireRole(accessManager, HUB_CONFIGURATOR_ROLE, ownerSafe, true);
    _requireRole(accessManager, SPOKE_CONFIGURATOR_ROLE, ownerSafe, true);

    for (uint256 i; i < targets.length; i++) {
      vm.prank(ownerSafe);
      (bool ok, bytes memory ret) = targets[i].call(calldatas[i]);
      require(ok, SafeCallFailed(i, ret));
    }

    // Safe no longer holds the direct roles
    _requireRole(accessManager, HUB_CONFIGURATOR_ROLE, ownerSafe, false);
    _requireRole(accessManager, SPOKE_CONFIGURATOR_ROLE, ownerSafe, false);

    // the configurator contracts must keep them — the market depends on it
    _requireRole(accessManager, HUB_CONFIGURATOR_ROLE, AaveV4EtherfiCash.HUB_CONFIGURATOR, true);
    _requireRole(
      accessManager,
      SPOKE_CONFIGURATOR_ROLE,
      AaveV4EtherfiCash.SPOKE_CONFIGURATOR,
      true
    );

    // the Safe keeps admin (0), so the revokes are reversible via grantRole if ever needed
    _requireRole(accessManager, 0, ownerSafe, true);

    // bonus factor updated
    uint16 factor = ISpoke(cashSpoke).getLiquidationConfig().liquidationBonusFactor;
    require(factor == LIQUIDATION_BONUS_FACTOR, BonusFactorNotUpdated(factor));

    // price sources updated; setReserveSource already enforced decimals + non-zero price,
    // and getReservePrice reverts on a dead feed — log each price for eyeball review
    IAaveOracle oracle = IAaveOracle(ISpoke(cashSpoke).ORACLE());
    for (uint256 i; i < oracles.length; i++) {
      address source = oracle.getReserveSource(oracles[i].reserveId);
      require(source == oracles[i].feed, PriceSourceNotUpdated(oracles[i].reserveId, source));
      console2.log(
        string.concat(
          '  reserve ',
          vm.toString(oracles[i].reserveId),
          ' (',
          oracles[i].label,
          ') price:'
        ),
        oracle.getReservePrice(oracles[i].reserveId)
      );
    }
  }

  function _requireRole(
    address accessManager,
    uint64 roleId,
    address account,
    bool expected
  ) internal view {
    (bool isMember, ) = IAccessManager(accessManager).hasRole(roleId, account);
    if (expected) require(isMember, RoleLost(roleId, account));
    else require(!isMember, RoleStillHeld(roleId, account));
  }

  function _txJson(address to, bytes memory data) internal pure returns (string memory) {
    return
      string.concat(
        '    {\n',
        '      "to": "',
        vm.toString(to),
        '",\n',
        '      "value": "0",\n',
        '      "data": "',
        vm.toString(data),
        '",\n',
        '      "operation": 0\n',
        '    }'
      );
  }
}
