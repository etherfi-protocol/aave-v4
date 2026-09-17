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
import {IHubConfigurator} from 'src/hub/interfaces/IHubConfigurator.sol';
import {ISpokeConfigurator} from 'src/spoke/interfaces/ISpokeConfigurator.sol';
import {IAssetInterestRateStrategy} from 'src/hub/interfaces/IAssetInterestRateStrategy.sol';

/// @title EtherfiCashGovernanceBase
/// @notice Reusable plumbing for every ether.fi Cash governance script (Safe batches, timelock
/// operations, AccessManager / Ownable call builders, read-back checks). Nothing in here is
/// specific to one migration.
///   - `_grantRole`, `_revokeRole`, `_labelRole`, `_setTargetFunctionRole`, `_setRoleGuardian`:
///     AccessManager calls as Safe transactions with a readable note
///   - `_transferOwnership`, `_acceptOwnership`, `_timelockGrantRole`, `_timelockRevokeRole`:
///     Ownable / AccessControl calls
///   - `_updateInterestRateData`, `_updateLiquidityFee`, `_updateSpokeDrawCap`, `_updateBorrowable`:
///     HubConfigurator / SpokeConfigurator parameter calls
///   - `_canCall` / `_requireCanCall`: may a Safe send these calls right now (AccessManager)
///   - `_plan`: re-run a script's `configure()` and apply what it writes in this VM until COMPLETE
///   - `_emitBatch`: write a Safe Transaction Builder batch (+ .md twin), remembered in `lastEmitted`
///   - `_writeBatch` / `_previewExecute`: write a batch that is not the next step (execute batches
///     of operations still maturing, so signers can review and queue them early)
///   - `_driveOperation` / `_isOperationDone`: schedule → wait → execute a TimelockController batch
///   - `_emitSchedules`: one Safe MultiSend that schedules several operations at once
///   - `_emitScheduleAlongside`: a schedule batch that is independent of `lastEmitted` and may be
///     sent at the same time (recorded in `alsoEmitted`), so the delay overlaps the current step
///   - `_check*` / `_assertNoMismatches`: accumulate mismatches, revert with the count
abstract contract EtherfiCashGovernanceBase is EtherfiCashScriptBase {
  /// @notice The batch last written; `signer` == address(0) means anyone may send it (open
  /// timelock execution).
  struct Emitted {
    string path;
    address signer;
  }

  /// @dev Where the batches go; a script writes its own folder by overriding this.
  function _outputDir() internal pure virtual returns (string memory) {
    return 'output/etherfi/timelock/';
  }

  /// @dev keccak256('eip1967.proxy.admin') - 1
  bytes32 internal constant EIP1967_ADMIN_SLOT =
    0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

  error Mismatches(string what, uint256 count);
  error NotExecutor(address timelock, address executor);
  error NoSigner(string note);
  error PlanDidNotConverge(uint256 steps);

  Emitted public lastEmitted;
  /// @notice A second batch written for the same step that does not depend on `lastEmitted` and
  /// may be sent at the same time, by its own signer (empty path when there is none).
  Emitted public alsoEmitted;
  /// @dev The transactions behind `lastEmitted` / `alsoEmitted`, kept so a plan run can apply
  /// them in this VM without reading the files back.
  GnosisTxBuilder.Tx[] internal lastEmittedTxs;
  GnosisTxBuilder.Tx[] internal alsoEmittedTxs;
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

  function _timelockRevokeRole(
    address timelock,
    bytes32 role,
    address account
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _tx(
        timelock,
        abi.encodeCall(IAccessControl.revokeRole, (role, account)),
        string.concat('Timelock.revokeRole(', vm.toString(role), ', ', vm.toString(account), ')')
      );
  }

  function _updateInterestRateData(
    address hub,
    uint256 assetId,
    IAssetInterestRateStrategy.InterestRateData memory irData
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _tx(
        Cash.HUB_CONFIGURATOR,
        abi.encodeCall(IHubConfigurator.updateInterestRateData, (hub, assetId, abi.encode(irData))),
        string.concat(
          'HubConfigurator.updateInterestRateData(',
          _name(hub),
          ', ',
          vm.toString(assetId),
          ', {optimalUsageRatio: ',
          vm.toString(irData.optimalUsageRatio),
          ', baseDrawnRate: ',
          vm.toString(irData.baseDrawnRate),
          ', rateGrowthBeforeOptimal: ',
          vm.toString(irData.rateGrowthBeforeOptimal),
          ', rateGrowthAfterOptimal: ',
          vm.toString(irData.rateGrowthAfterOptimal),
          '})'
        )
      );
  }

  function _updateLiquidityFee(
    address hub,
    uint256 assetId,
    uint256 liquidityFee
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _tx(
        Cash.HUB_CONFIGURATOR,
        abi.encodeCall(IHubConfigurator.updateLiquidityFee, (hub, assetId, liquidityFee)),
        string.concat(
          'HubConfigurator.updateLiquidityFee(',
          _name(hub),
          ', ',
          vm.toString(assetId),
          ', ',
          vm.toString(liquidityFee),
          ')'
        )
      );
  }

  function _updateSpokeDrawCap(
    address hub,
    uint256 assetId,
    address spoke,
    uint256 drawCap
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _tx(
        Cash.HUB_CONFIGURATOR,
        abi.encodeCall(IHubConfigurator.updateSpokeDrawCap, (hub, assetId, spoke, drawCap)),
        string.concat(
          'HubConfigurator.updateSpokeDrawCap(',
          _name(hub),
          ', ',
          vm.toString(assetId),
          ', ',
          _name(spoke),
          ', ',
          vm.toString(drawCap),
          ')'
        )
      );
  }

  function _updateBorrowable(
    address spoke,
    uint256 reserveId,
    bool borrowable
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    return
      _tx(
        Cash.SPOKE_CONFIGURATOR,
        abi.encodeCall(ISpokeConfigurator.updateBorrowable, (spoke, reserveId, borrowable)),
        string.concat(
          'SpokeConfigurator.updateBorrowable(',
          _name(spoke),
          ', ',
          vm.toString(reserveId),
          ', ',
          borrowable ? 'true' : 'false',
          ')'
        )
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
    string memory path = _writeBatch(safe, name, txs);
    lastEmitted = Emitted({path: path, signer: safe});
    _store(lastEmittedTxs, txs);
    console2.log('[next] wrote', path);
    console2.log('       signer:', safe);
    for (uint256 i; i < txs.length; i++) {
      console2.log(string.concat('       ', vm.toString(i + 1), '. ', txs[i].note));
    }
  }

  /// @dev Writes a Safe Transaction Builder batch for `safe` without making it the next step.
  function _writeBatch(
    address safe,
    string memory name,
    GnosisTxBuilder.Tx[] memory txs
  ) internal returns (string memory) {
    return
      GnosisTxBuilder.write(
        _outputDir(),
        name,
        string.concat(vm.toString(txs.length), ' CALL transactions for ', vm.toString(safe)),
        safe,
        txs
      );
  }

  /// @dev Drives one TimelockController batch operation by its state: emits the proposer's
  /// schedule batch, reports the wait, or emits the execute batch. The execute batch is written
  /// for `executor` unless the timelock's EXECUTOR_ROLE is open (held by address(0)), in which
  /// case any account may send it. While the operation is unscheduled or maturing the execute
  /// batch is pre-written too (calldata is deterministic), so it can be reviewed and queued in
  /// the Safe ahead of time; it only becomes the next step once the operation is Ready.
  function _driveOperation(
    address timelock,
    address proposer,
    address executor,
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
      _previewExecute(timelock, executor, name, salt, txs);
    } else if (state == TimelockController.OperationState.Waiting) {
      _clearNext();
      console2.log('[wait]', name, ': scheduled, executable at unix time', tl.getTimestamp(id));
      _previewExecute(timelock, executor, name, salt, txs);
    } else if (state == TimelockController.OperationState.Ready) {
      _emitExecute(timelock, executor, name, salt, txs);
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
    bytes32[] memory salts = new bytes32[](1);
    salts[0] = salt;
    GnosisTxBuilder.Tx[][] memory ops = new GnosisTxBuilder.Tx[][](1);
    ops[0] = txs;
    _emitSchedules(timelock, proposer, name, salts, delay, ops);
  }

  /// @dev One Safe batch (MultiSend) from `proposer` that schedules `ops.length` separate
  /// timelock operations, `salts[i]` for `ops[i]`; each is then executed on its own.
  function _emitSchedules(
    address timelock,
    address proposer,
    string memory name,
    bytes32[] memory salts,
    uint256 delay,
    GnosisTxBuilder.Tx[][] memory ops
  ) internal {
    GnosisTxBuilder.Tx[] memory schedules = new GnosisTxBuilder.Tx[](ops.length);
    for (uint256 i; i < ops.length; i++) {
      schedules[i] = _scheduleCall(timelock, salts[i], delay, ops[i]);
    }
    _emitBatch(proposer, string.concat(name, '-schedule'), schedules);
    for (uint256 i; i < ops.length; i++) {
      console2.log(string.concat('       operation id ', vm.toString(i + 1), ':'));
      console2.logBytes32(_operationId(timelock, salts[i], ops[i]));
    }
  }

  /// @dev Writes the schedule batch of an unscheduled operation as a step that runs ALONGSIDE the
  /// current `[next]` batch: scheduling only needs `proposer`'s PROPOSER seat, so it can be sent
  /// now and the delay overlaps whatever `[next]` still has to do. Recorded in `alsoEmitted`
  /// (never in `lastEmitted`). The execute batch is pre-written for `executor` too.
  function _emitScheduleAlongside(
    address timelock,
    address proposer,
    address executor,
    string memory name,
    bytes32 salt,
    uint256 delay,
    GnosisTxBuilder.Tx[] memory txs
  ) internal {
    GnosisTxBuilder.Tx[] memory one = new GnosisTxBuilder.Tx[](1);
    one[0] = _scheduleCall(timelock, salt, delay, txs);
    string memory path = _writeBatch(proposer, string.concat(name, '-schedule'), one);
    alsoEmitted = Emitted({path: path, signer: proposer});
    _store(alsoEmittedTxs, one);
    console2.log('[also] wrote', path);
    console2.log('       signer:', proposer);
    console2.log('       independent of [next]: may be sent now so the delay overlaps');
    console2.log(string.concat('       1. ', one[0].note));
    console2.log('       operation id:');
    console2.logBytes32(_operationId(timelock, salt, txs));
    _previewExecute(timelock, executor, name, salt, txs);
  }

  /// @dev Pre-writes the execute batch of an operation that is not Ready yet (for `executor`;
  /// the Safe file is the same whether execution turns out open or not). Not the next step.
  function _previewExecute(
    address timelock,
    address executor,
    string memory name,
    bytes32 salt,
    GnosisTxBuilder.Tx[] memory txs
  ) internal {
    GnosisTxBuilder.Tx[] memory one = new GnosisTxBuilder.Tx[](1);
    one[0] = _executeCall(timelock, salt, txs);
    string memory path = _writeBatch(executor, string.concat(name, '-execute'), one);
    console2.log('[prep] wrote', path);
    console2.log('       execute batch for', executor, '- sendable once the operation matures');
  }

  /// @dev The `executeBatch` call for one operation, as a Safe transaction.
  function _executeCall(
    address timelock,
    bytes32 salt,
    GnosisTxBuilder.Tx[] memory txs
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _split(txs);
    return
      _tx(
        timelock,
        abi.encodeCall(
          TimelockController.executeBatch,
          (targets, values, payloads, bytes32(0), salt)
        ),
        string.concat('Timelock.executeBatch of: ', _notes(txs))
      );
  }

  /// @dev The `scheduleBatch` call for one operation, as a Safe transaction.
  function _scheduleCall(
    address timelock,
    bytes32 salt,
    uint256 delay,
    GnosisTxBuilder.Tx[] memory txs
  ) internal pure returns (GnosisTxBuilder.Tx memory) {
    (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _split(txs);
    return
      _tx(
        timelock,
        abi.encodeCall(
          TimelockController.scheduleBatch,
          (targets, values, payloads, bytes32(0), salt, delay)
        ),
        string.concat('Timelock.scheduleBatch, delay ', vm.toString(delay), 's, of: ', _notes(txs))
      );
  }

  function _emitExecute(
    address timelock,
    address executor,
    string memory name,
    bytes32 salt,
    GnosisTxBuilder.Tx[] memory txs
  ) internal {
    TimelockController tl = TimelockController(payable(timelock));
    bytes32 executorRole = tl.EXECUTOR_ROLE();
    bool open = tl.hasRole(executorRole, address(0));
    require(open || tl.hasRole(executorRole, executor), NotExecutor(timelock, executor));

    GnosisTxBuilder.Tx[] memory one = new GnosisTxBuilder.Tx[](1);
    one[0] = _executeCall(timelock, salt, txs);
    _emitBatch(executor, string.concat(name, '-execute'), one);
    if (!open) return;
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

  /// @dev Nothing is the next step (an operation is maturing, or everything is done).
  function _clearNext() internal {
    delete lastEmitted;
    delete lastEmittedTxs;
  }

  function _clearAlso() internal {
    delete alsoEmitted;
    delete alsoEmittedTxs;
  }

  /// @dev memory -> storage copy of a Tx array (element-wise: struct arrays cannot be assigned).
  function _store(GnosisTxBuilder.Tx[] storage dst, GnosisTxBuilder.Tx[] memory src) internal {
    while (dst.length > 0) {
      dst.pop();
    }
    for (uint256 i; i < src.length; i++) {
      dst.push(src[i]);
    }
  }

  /// @dev Applies a written batch in THIS VM, every call pranked from its signer (a throwaway
  /// account when execution is open), bubbling the first revert. A Safe Transaction Builder batch
  /// runs through MultiSend, so the targets see the Safe as msg.sender exactly like this.
  function _simulate(Emitted memory batch, GnosisTxBuilder.Tx[] storage txs) internal {
    address sender = batch.signer == address(0) ? makeAddr('anyone') : batch.signer;
    for (uint256 i; i < txs.length; i++) {
      vm.prank(sender);
      (bool ok, bytes memory ret) = txs[i].to.call{value: txs[i].value}(txs[i].data);
      if (!ok) {
        console2.log('[sim] REVERTED:', txs[i].note);
        assembly ('memory-safe') {
          revert(add(ret, 32), mload(ret))
        }
      }
    }
    console2.log('[sim] applied', batch.path);
    console2.log('      as', sender);
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

  /// @dev Scheduled at some point (waiting, ready or done).
  function _isOperation(
    address timelock,
    bytes32 salt,
    GnosisTxBuilder.Tx[] memory txs
  ) internal view returns (bool) {
    return TimelockController(payable(timelock)).isOperation(_operationId(timelock, salt, txs));
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
  // Signer routing and plan simulation
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// @dev `account` may send this call right now, per the AccessManager (no execution delay).
  function _canCall(address account, GnosisTxBuilder.Tx memory call) internal view returns (bool) {
    (bool allowed, uint32 delay) = IAccessManager(Cash.ACCESS_MANAGER).canCall(
      account,
      call.to,
      bytes4(call.data)
    );
    return allowed && delay == 0;
  }

  /// @dev Every call in `calls` must be sendable by `safe` right now (reverts with the first
  /// one that is not, e.g. a selector the timelock migration has moved behind the queue).
  function _requireCanCall(address safe, GnosisTxBuilder.Tx[] memory calls) internal view {
    for (uint256 i; i < calls.length; i++) {
      require(_canCall(safe, calls[i]), NoSigner(calls[i].note));
    }
  }

  /// @dev The first `n` entries of `txs`.
  function _take(
    GnosisTxBuilder.Tx[] memory txs,
    uint256 n
  ) internal pure returns (GnosisTxBuilder.Tx[] memory out) {
    out = new GnosisTxBuilder.Tx[](n);
    for (uint256 i; i < n; i++) {
      out[i] = txs[i];
    }
  }

  /// @dev Runs `configure` (a script's state machine returning its phase as uint256) and applies
  /// every batch it writes in this VM as its signer, letting `delay` pass when nothing is
  /// sendable, until it returns `complete`. Every remaining batch is thereby written AND proven
  /// to succeed in sequence against live state. Prints the queue in execution order.
  /// @return live the phase the chain is actually at (the first `configure` result)
  function _plan(
    function() internal returns (uint256) configure,
    uint256 complete,
    uint256 delay
  ) internal returns (uint256 live) {
    live = configure();
    uint256 phase = live;
    string[] memory queue = new string[](24);
    uint256 n;
    for (uint256 step = 1; phase != complete; step++) {
      require(step <= 24, PlanDidNotConverge(step));
      console2.log('');
      console2.log('--- plan step', step, ': simulating in this VM');
      bool next = bytes(lastEmitted.path).length != 0;
      bool also = bytes(alsoEmitted.path).length != 0;
      if (!next && !also) {
        vm.warp(block.timestamp + delay);
        console2.log('[sim] delay passed: the maturing operation is now Ready');
        queue[n++] = string.concat('   (', vm.toString(delay), 's delay)');
      }
      if (next) {
        _simulate(lastEmitted, lastEmittedTxs);
        queue[n++] = string.concat(_who(lastEmitted.signer), ' ', lastEmitted.path);
      }
      if (also) {
        _simulate(alsoEmitted, alsoEmittedTxs);
        queue[n++] = string.concat(
          _who(alsoEmitted.signer),
          ' ',
          alsoEmitted.path,
          ' (with the previous)'
        );
      }
      phase = configure();
    }
    console2.log('');
    console2.log('=== PLAN: every remaining batch written and simulated to COMPLETE ===');
    console2.log(
      'Queue, in execution order (each line waits for the one above, except (delay) and "with"):'
    );
    for (uint256 i; i < n; i++) {
      console2.log(string.concat(vm.toString(i + 1), '. ', queue[i]));
    }
    console2.log('Live next step (configure()):', live);
  }

  function _who(address signer) internal pure returns (string memory) {
    if (signer == Cash.OWNER_SAFE) return '[Admin Safe]   ';
    if (signer == Cash.TIMELOCK_SAFE) return '[Timelock Safe]';
    if (signer == address(0)) return '[anyone]       ';
    return vm.toString(signer);
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
    if (target == Hubs.CASH_HUB) return 'CashHub';
    if (target == Spokes.CASH_SPOKE) return 'CashSpoke';
    if (target == Hubs.CASH_HUB_PROXY_ADMIN) return 'CashHubProxyAdmin';
    if (target == Spokes.CASH_SPOKE_PROXY_ADMIN) return 'CashSpokeProxyAdmin';
    if (target == Spokes.TREASURY_SPOKE_PROXY_ADMIN) return 'TreasurySpokeProxyAdmin';
    if (target == Spokes.TREASURY_SPOKE) return 'TreasurySpoke';
    return vm.toString(target);
  }
}
