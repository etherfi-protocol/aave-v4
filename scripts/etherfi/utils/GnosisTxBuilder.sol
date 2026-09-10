// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VmSafe} from 'forge-std/Vm.sol';

/// @title GnosisTxBuilder
/// @notice Builds Safe{Wallet} Transaction Builder batches from raw CALL transactions: the JSON the
/// Safe web app imports (Transaction Builder app > "Load batch") plus a human-readable `.md` twin
/// listing every transaction with its note, so signers can compare what they sign to the plan.
library GnosisTxBuilder {
  VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256('hevm cheat code')))));

  string internal constant TX_BUILDER_VERSION = '1.16.5';

  struct Tx {
    address to;
    uint256 value;
    bytes data;
    string note;
  }

  /// @notice Writes `<dir><name>.json` (importable batch) and `<dir><name>.md` (readable twin).
  /// @return jsonPath Path of the written JSON batch.
  function write(
    string memory dir,
    string memory name,
    string memory description,
    address safe,
    Tx[] memory txs
  ) internal returns (string memory jsonPath) {
    vm.createDir(dir, true);
    jsonPath = string.concat(dir, name, '.json');
    vm.writeFile(jsonPath, toJson(block.chainid, safe, name, description, txs));
    vm.writeFile(
      string.concat(dir, name, '.md'),
      toMarkdown(block.chainid, safe, name, description, txs)
    );
  }

  /// @notice Safe Transaction Builder JSON (all transactions are CALLs with raw calldata).
  function toJson(
    uint256 chainId,
    address safe,
    string memory name,
    string memory description,
    Tx[] memory txs
  ) internal pure returns (string memory) {
    string memory items;
    for (uint256 i; i < txs.length; i++) {
      items = string.concat(
        items,
        i == 0 ? '' : ',\n',
        '    {\n      "to": "',
        vm.toString(txs[i].to),
        '",\n      "value": "',
        vm.toString(txs[i].value),
        '",\n      "data": "',
        vm.toString(txs[i].data),
        '",\n      "contractMethod": null,\n      "contractInputsValues": null\n    }'
      );
    }
    return
      string.concat(
        '{\n  "version": "1.0",\n  "chainId": "',
        vm.toString(chainId),
        '",\n  "meta": {\n    "name": "',
        name,
        '",\n    "description": "',
        description,
        '",\n    "txBuilderVersion": "',
        TX_BUILDER_VERSION,
        '",\n    "createdFromSafeAddress": "',
        vm.toString(safe),
        '"\n  },\n  "transactions": [\n',
        items,
        '\n  ]\n}\n'
      );
  }

  /// @notice Human-readable listing: one numbered entry per transaction with its note.
  function toMarkdown(
    uint256 chainId,
    address safe,
    string memory name,
    string memory description,
    Tx[] memory txs
  ) internal pure returns (string memory) {
    string memory out = string.concat(
      '# ',
      name,
      '\n\n',
      description,
      '\n\n- safe: ',
      vm.toString(safe),
      '\n- chainId: ',
      vm.toString(chainId),
      '\n- operation: CALL for every transaction\n\n'
    );
    for (uint256 i; i < txs.length; i++) {
      out = string.concat(
        out,
        vm.toString(i + 1),
        '. ',
        txs[i].note,
        '\n   - to: ',
        vm.toString(txs[i].to),
        '\n   - value: ',
        vm.toString(txs[i].value),
        '\n   - data: ',
        vm.toString(txs[i].data),
        '\n\n'
      );
    }
    return out;
  }
}
