// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2} from 'forge-std/console2.sol';

import {EtherfiCashScriptBase} from 'scripts/etherfi/EtherfiCashScriptBase.s.sol';
import {GnosisTxBuilder} from 'scripts/etherfi/utils/GnosisTxBuilder.sol';
import {
  AaveV4EtherfiCash as Cash,
  AaveV4EtherfiCashHubs as Hubs,
  AaveV4EtherfiCashSpokes as Spokes
} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {TimelockController} from 'src/dependencies/openzeppelin/TimelockController.sol';
import {IAccessControl} from 'src/dependencies/openzeppelin/IAccessControl.sol';
import {IAccessManager} from 'src/dependencies/openzeppelin/IAccessManager.sol';
import {Ownable} from 'src/dependencies/openzeppelin/Ownable.sol';
import {Ownable2StepUpgradeable} from 'src/dependencies/openzeppelin-upgradeable/Ownable2StepUpgradeable.sol';

/// @title EtherfiCashGovernanceBase
/// @notice Reusable plumbing for every ether.fi Cash governance script (Safe batches, timelock
/// operations, AccessManager / Ownable call builders, read-back checks). Nothing in here is
/// specific to one migration.
///   - `_grantRole`, `_revokeRole`, `_labelRole`, `_setTargetFunctionRole`, `_setRoleGuardian`:
///     AccessManager calls as Safe transactions with a readable note
///   - `_transferOwnership`, `_acceptOwnership`, `_timelockGrantRole`: Ownable / AccessControl calls
///   - `_emitBatch`: write a Safe Transaction Builder batch (+ .md twin), remembered in `lastEmitted`
///   - `_driveOperation` / `_isOperationDone`: schedule → wait → execute a TimelockController batch
///   - `_check*` / `_assertNoMismatches`: accumulate mismatches, revert with the count
abstract contract EtherfiCashGovernanceBase is EtherfiCashScriptBase {
  /// @notice The batch last written; `signer` == address(0) means anyone may send it.
  struct Emitted {
    string path;
    address signer;
  }

  string internal constant OUTPUT_DIR = 'output/etherfi/timelock/';
  /// @dev keccak256('eip1967.proxy.admin') - 1
  bytes32 internal constant EIP1967_ADMIN_SLOT =
    0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

  error Mismatches(string what, uint256 count);

  Emitted public lastEmitted;
  uint256 internal mismatches;

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // Call builders — each carries a readable note for the .md twin and the console
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  function _grantRole(
    uint64 role,
    address account
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _am(
        abi.encodeCall(IAccessManager.grantRole, (role, account, 0)),
        string.concat(
          'AccessManager.grantRole(',
          vm.toString(role),
          ', ',
          vm.toString(account),
          ', 0)'
        )
      );
  }

  function _revokeRole(
    uint64 role,
    address account
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _am(
        abi.encodeCall(IAccessManager.revokeRole, (role, account)),
        string.concat(
          'AccessManager.revokeRole(',
          vm.toString(role),
          ', ',
          vm.toString(account),
          ')'
        )
      );
  }

  function _labelRole(
    uint64 role,
    string memory label
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _am(
        abi.encodeCall(IAccessManager.labelRole, (role, label)),
        string.concat('AccessManager.labelRole(', vm.toString(role), ', "', label, '")')
      );
  }

  function _setTargetFunctionRole(
    address target,
    bytes4[] memory selectors,
    uint64 role
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    string memory list;
    for (uint256 i; i < selectors.length; i++) {
      list = string.concat(list, i == 0 ? '' : ', ', _hex(selectors[i]));
    }
    return
      _am(
        abi.encodeCall(IAccessManager.setTargetFunctionRole, (target, selectors, role)),
        string.concat(
          'AccessManager.setTargetFunctionRole(',
          _name(target),
          ', [',
          list,
          '], ',
          vm.toString(role),
          ')'
        )
      );
  }

  function _setRoleGuardian(
    uint64 role,
    uint64 guardian
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _am(
        abi.encodeCall(IAccessManager.setRoleGuardian, (role, guardian)),
        string.concat(
          'AccessManager.setRoleGuardian(',
          vm.toString(role),
          ', ',
          vm.toString(guardian),
          ')'
        )
      );
  }

  function _transferOwnership(
    address target,
    address newOwner
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _tx(
        target,
        abi.encodeCall(Ownable.transferOwnership, (newOwner)),
        string.concat(_name(target), '.transferOwnership(', vm.toString(newOwner), ')')
      );
  }

  function _acceptOwnership(address target) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _tx(
        target,
        abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
        string.concat(_name(target), '.acceptOwnership()')
      );
  }

  function _timelockGrantRole(
    address timelock,
    bytes32 role,
    address account
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _tx(
        timelock,
        abi.encodeCall(IAccessControl.grantRole, (role, account)),
        string.concat('Timelock.grantRole(', vm.toString(role), ', ', vm.toString(account), ')')
      );
  }

  function _sel(bytes4 a) internal pure returns (bytes4[] memory s) {
    s = new bytes4[](1);
    s[0] = a;
  }

  function _sel(bytes4 a, bytes4 b) internal pure returns (bytes4[] memory s) {
    s = new bytes4[](2);
    s[0] = a;
    s[1] = b;
  }

  function _am(
    bytes memory data,
    string memory note
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return _tx(Cash.ACCESS_MANAGER, data, note);
  }

  function _tx(
    address to,
    bytes memory data,
    string memory note
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return GnosisTxBuilder.Tx({to: to, value: 0, data: data, note: note});
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // Safe batches and timelock operations
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// @dev Writes a Safe Transaction Builder batch for `safe` and records it in `lastEmitted`.
  function _emitBatch(address safe, string memory name, GnosisTxBuilder.Tx[] memory txs) internal {
    string memory path = GnosisTxBuilder.write(
      OUTPUT_DIR,
      name,
      string.concat(vm.toString(txs.length), ' CALL transactions for ', vm.toString(safe)),
      safe,
      txs
    );
    lastEmitted = Emitted({path: path, signer: safe});
    console2.log('[next] wrote', path);
    console2.log('       signer:', safe);
    for (uint256 i; i < txs.length; i++) {
      console2.log(string.concat('       ', vm.toString(i + 1), '. ', txs[i].note));
    }
  }

  /// @dev Drives one TimelockController batch operation by its state: emits the proposer's
  /// schedule batch, reports the wait, or emits the execute batch (open execution: any signer).
  function _driveOperation(
    address timelock,
    address proposer,
    string memory name,
    bytes32 salt,
    uint256 delay,
    GnosisTxBuilder.Tx[] memory txs
  ) internal {
    TimelockController tl = TimelockController(payable(timelock));
    bytes32 id = _operationId(timelock, salt, txs);
    TimelockController.OperationState state = tl.getOperationState(id);
    if (state == TimelockController.OperationState.Unset) {
      _emitSchedule(timelock, proposer, name, salt, delay, txs);
      console2.log('       operation id:');
      console2.logBytes32(id);
    } else if (state == TimelockController.OperationState.Waiting) {
      delete lastEmitted;
      console2.log('[wait]', name, ': scheduled, executable at unix time', tl.getTimestamp(id));
    } else if (state == TimelockController.OperationState.Ready) {
      _emitExecute(timelock, proposer, name, salt, txs);
    }
  }

  function _emitSchedule(
    address timelock,
    address proposer,
    string memory name,
    bytes32 salt,
    uint256 delay,
    GnosisTxBuilder.Tx[] memory txs
  ) internal {
    (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _split(txs);
    GnosisTxBuilder.Tx[] memory one = new GnosisTxBuilder.Tx[](1);
    one[0] = _tx(
      timelock,
      abi.encodeCall(
        TimelockController.scheduleBatch,
        (targets, values, payloads, bytes32(0), salt, delay)
      ),
      string.concat('Timelock.scheduleBatch, delay ', vm.toString(delay), 's, of: ', _notes(txs))
    );
    _emitBatch(proposer, string.concat(name, '-schedule'), one);
  }

  function _emitExecute(
    address timelock,
    address proposer,
    string memory name,
    bytes32 salt,
    GnosisTxBuilder.Tx[] memory txs
  ) internal {
    (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _split(txs);
    GnosisTxBuilder.Tx[] memory one = new GnosisTxBuilder.Tx[](1);
    one[0] = _tx(
      timelock,
      abi.encodeCall(
        TimelockController.executeBatch,
        (targets, values, payloads, bytes32(0), salt)
      ),
      string.concat('Timelock.executeBatch of: ', _notes(txs))
    );
    _emitBatch(proposer, string.concat(name, '-execute'), one);
    lastEmitted.signer = address(0);
    console2.log('       open execution - any account may send, e.g.');
    console2.log(
      string.concat(
        '       cast send ',
        vm.toString(timelock),
        ' ',
        vm.toString(one[0].data),
        ' --rpc-url optimism --account <keystore>'
      )
    );
  }

  function _operationId(
    address timelock,
    bytes32 salt,
    GnosisTxBuilder.Tx[] memory txs
  ) internal pure returns (bytes32) {
    (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _split(txs);
    return
      TimelockController(payable(timelock)).hashOperationBatch(
        targets,
        values,
        payloads,
        bytes32(0),
        salt
      );
  }

  function _isOperationDone(
    address timelock,
    bytes32 salt,
    GnosisTxBuilder.Tx[] memory txs
  ) internal view returns (bool) {
    return TimelockController(payable(timelock)).isOperationDone(_operationId(timelock, salt, txs));
  }

  function _split(
    GnosisTxBuilder.Tx[] memory txs
  )
    internal
    pure
    returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
  {
    targets = new address[](txs.length);
    values = new uint256[](txs.length);
    payloads = new bytes[](txs.length);
    for (uint256 i; i < txs.length; i++) {
      targets[i] = txs[i].to;
      values[i] = txs[i].value;
      payloads[i] = txs[i].data;
    }
  }

  function _notes(GnosisTxBuilder.Tx[] memory txs) internal pure returns (string memory out) {
    for (uint256 i; i < txs.length; i++) {
      out = string.concat(out, i == 0 ? '' : '; ', vm.toString(i + 1), ') ', txs[i].note);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // State readers
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  function _hasRole(uint64 role, address account) internal view returns (bool) {
    (bool isMember, ) = IAccessManager(Cash.ACCESS_MANAGER).hasRole(role, account);
    return isMember;
  }

  function _owner(address target) internal view returns (address) {
    return Ownable(target).owner();
  }

  function _erc1967Admin(address proxy) internal view returns (address) {
    return address(uint160(uint256(vm.load(proxy, EIP1967_ADMIN_SLOT))));
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // Check primitives — accumulate, then `_assertNoMismatches` reverts with the count
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  function _check(string memory what, uint256 actual, uint256 expected) internal {
    if (actual != expected) {
      console2.log(
        string.concat(
          '  [MISMATCH] ',
          what,
          ': actual=',
          vm.toString(actual),
          ' expected=',
          vm.toString(expected)
        )
      );
      mismatches++;
    }
  }

  function _checkBool(string memory what, bool actual, bool expected) internal {
    _check(what, actual ? 1 : 0, expected ? 1 : 0);
  }

  function _checkAddr(string memory what, address actual, address expected) internal {
    _check(what, uint160(actual), uint160(expected));
  }

  function _checkSel(string memory what, bytes4 actual, bytes4 expected) internal {
    _check(what, uint32(actual), uint32(expected));
  }

  function _assertNoMismatches(string memory what) internal {
    uint256 count = mismatches;
    mismatches = 0;
    require(count == 0, Mismatches(what, count));
  }

  function _hex(bytes4 selector) internal pure returns (string memory) {
    return vm.toString(abi.encodePacked(selector));
  }

  /// @dev Readable name of a pinned instance address for notes and mismatch logs.
  function _name(address target) internal pure returns (string memory) {
    if (target == Cash.ACCESS_MANAGER) return 'AccessManager';
    if (target == Cash.HUB_CONFIGURATOR) return 'HubConfigurator';
    if (target == Cash.SPOKE_CONFIGURATOR) return 'SpokeConfigurator';
    if (target == Hubs.CASH_HUB_PROXY_ADMIN) return 'CashHubProxyAdmin';
    if (target == Spokes.CASH_SPOKE_PROXY_ADMIN) return 'CashSpokeProxyAdmin';
    if (target == Spokes.TREASURY_SPOKE_PROXY_ADMIN) return 'TreasurySpokeProxyAdmin';
    if (target == Spokes.TREASURY_SPOKE) return 'TreasurySpoke';
    return vm.toString(target);
  }
}
