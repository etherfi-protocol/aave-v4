// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from 'src/dependencies/openzeppelin/TimelockController.sol';

/**
 * @title EtherFiTimelock
 * @author ether.fi
 * @notice Timelock that owns the RoleRegistry, putting role administration and contract
 *         upgrades behind an execution delay.
 * @dev Verbatim copy of cash-v3 `src/timelock/EtherFiTimelock.sol`
 *      (https://github.com/etherfi-protocol/cash-v3/blob/master/src/timelock/EtherFiTimelock.sol);
 *      only the import path differs (this repo vendors OpenZeppelin under src/dependencies).
 *      Here it sits in front of the ether.fi Cash Aave V4 AccessManager, the ProxyAdmins and the
 *      TreasurySpoke instead of the cash RoleRegistry. No immutables, so
 *      `type(EtherFiTimelock).runtimeCode` is the exact expected on-chain code.
 */
contract EtherFiTimelock is TimelockController {
  constructor(
    uint256 minDelay,
    address[] memory proposers,
    address[] memory executors,
    address admin
  ) TimelockController(minDelay, proposers, executors, admin) {}
}
