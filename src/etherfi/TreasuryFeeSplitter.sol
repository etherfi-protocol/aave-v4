// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from 'src/dependencies/openzeppelin/Ownable2Step.sol';
import {SafeERC20, IERC20} from 'src/dependencies/openzeppelin/SafeERC20.sol';
import {ReentrancyGuardTransient} from 'src/dependencies/openzeppelin/ReentrancyGuardTransient.sol';
import {MathUtils} from 'src/libraries/math/MathUtils.sol';
import {PercentageMath} from 'src/libraries/math/PercentageMath.sol';
import {IHubBase} from 'src/hub/interfaces/IHubBase.sol';
import {ITreasurySpoke} from 'src/spoke/interfaces/ITreasurySpoke.sol';

/// @title TreasuryFeeSplitter
/// @author ether.fi
/// @notice Owns the ether.fi Cash Aave V4 TreasurySpoke and splits its fees between two
///         recipients fixed at deployment.
/// @dev Follows the Aave V3 `RevenueSplitter` (aave-v3-origin, removed in b2e83fb3): two immutable
///      recipients, an immutable split for recipient A with recipient B taking the remainder, and
///      permissionless `splitRevenue` / `splitNativeRevenue()`.
///
///      The difference is forced by V4: the TreasurySpoke is the Hub `feeReceiver` and holds fees
///      as Hub shares, and `TreasurySpoke.withdraw` pays out only to its owner. So instead of
///      receiving tokens, this contract owns the TreasurySpoke and `splitRevenue` withdraws each
///      token's fees before splitting them. Only what each withdrawal delivers is split; tokens
///      sent here directly stay until the owner moves them with `rescueToken`.
///
///      A TreasurySpoke can be the fee receiver on several Hubs. The owner keeps an allowlist of
///      the Hubs fees may be split from, so a new Hub needs no redeploy or ownership handover.
///
///      Fees reach the TreasurySpoke only once `Hub.mintFeeShares` runs (HUB_FEE_MINTER_ROLE on
///      the Hub AccessManager). This contract does not mint.
///
///      The owner (the Lend timelock) keeps every owner power over the TreasurySpoke through
///      `executeOnTreasury`, including `transferOwnership` to hand it back.
contract TreasuryFeeSplitter is Ownable2Step, ReentrancyGuardTransient {
  using SafeERC20 for IERC20;
  using PercentageMath for uint256;

  /// @notice The TreasurySpoke this contract owns and withdraws from.
  ITreasurySpoke public immutable TREASURY_SPOKE;

  address payable public immutable RECIPIENT_A;
  address payable public immutable RECIPIENT_B;

  /// @notice Recipient A's share in basis points; recipient B receives the remainder.
  uint16 public immutable SPLIT_PERCENTAGE_RECIPIENT_A;

  /// @notice Hubs that `splitRevenue` may withdraw from.
  mapping(address hub => bool) public isHubAllowed;

  event HubAllowedUpdated(address indexed hub, bool allowed);
  event RevenueSplit(address indexed hub, address indexed token, uint256 amountA, uint256 amountB);
  event NativeRevenueSplit(uint256 amountA, uint256 amountB, bool sentA, bool sentB);
  event TreasuryCallExecuted(bytes data, bytes result);
  event TokenRescued(address indexed token, address indexed to, uint256 amount);

  error InvalidAddress();
  error InvalidPercentSplit();
  error SameRecipients();
  error HubNotAllowed(address hub);

  /// @param treasurySpoke The TreasurySpoke to own. Ownership is transferred separately
  ///        (two-step: the current owner calls `transferOwnership`, then this contract's owner
  ///        calls `executeOnTreasury(acceptOwnership())`).
  /// @param hubs The Hubs initially allowed for `splitRevenue`.
  /// @param initialOwner The owner of this contract (the Lend timelock).
  /// @param recipientA Receives `splitPercentageRecipientA` of every split.
  /// @param recipientB Receives the remainder of every split; must differ from `recipientA`.
  /// @param splitPercentageRecipientA Recipient A's share in basis points, in (0, 10_000).
  constructor(
    address treasurySpoke,
    address[] memory hubs,
    address initialOwner,
    address recipientA,
    address recipientB,
    uint16 splitPercentageRecipientA
  ) Ownable(initialOwner) {
    if (treasurySpoke == address(0) || recipientA == address(0) || recipientB == address(0)) {
      revert InvalidAddress();
    }
    if (recipientA == recipientB) {
      revert SameRecipients();
    }
    if (
      splitPercentageRecipientA == 0 ||
      splitPercentageRecipientA >= PercentageMath.PERCENTAGE_FACTOR
    ) {
      revert InvalidPercentSplit();
    }

    TREASURY_SPOKE = ITreasurySpoke(treasurySpoke);
    RECIPIENT_A = payable(recipientA);
    RECIPIENT_B = payable(recipientB);
    SPLIT_PERCENTAGE_RECIPIENT_A = splitPercentageRecipientA;
    for (uint256 i; i < hubs.length; ++i) {
      _setHubAllowed(hubs[i], true);
    }
  }

  /// @notice Withdraws each token's fees on `hub` from the TreasurySpoke and splits them between
  ///         the recipients. Callable by anyone.
  /// @dev Withdraws the whole supplied position, capped at the Hub's available liquidity so a
  ///      highly utilized asset is drained as far as possible instead of reverting the batch.
  ///      Tokens with nothing to withdraw are skipped, and so is a recipient whose share rounds
  ///      to zero. Reverts on a token the Hub does not list.
  /// @param hub The Hub to withdraw from; must be allowed.
  /// @param tokens The Hub underlyings to withdraw and split.
  function splitRevenue(address hub, IERC20[] calldata tokens) external nonReentrant {
    if (!isHubAllowed[hub]) {
      revert HubNotAllowed(hub);
    }
    IHubBase targetHub = IHubBase(hub);

    for (uint256 i; i < tokens.length; ++i) {
      IERC20 token = tokens[i];
      uint256 assetId = targetHub.getAssetId(address(token));
      uint256 amount = MathUtils.min(
        targetHub.getSpokeAddedAssets(assetId, address(TREASURY_SPOKE)),
        targetHub.getAssetLiquidity(assetId)
      );
      if (amount == 0) {
        continue;
      }

      uint256 balanceBefore = token.balanceOf(address(this));
      TREASURY_SPOKE.withdraw(hub, address(token), amount);
      uint256 withdrawn = token.balanceOf(address(this)) - balanceBefore;

      uint256 amountA = withdrawn.percentMulDown(SPLIT_PERCENTAGE_RECIPIENT_A);
      uint256 amountB = withdrawn - amountA;

      // skip zero shares: some ERC-20s revert on zero transfers, which would block the batch
      if (amountA > 0) {
        token.safeTransfer(RECIPIENT_A, amountA);
      }
      if (amountB > 0) {
        token.safeTransfer(RECIPIENT_B, amountB);
      }
      emit RevenueSplit(hub, address(token), amountA, amountB);
    }
  }

  /// @notice Splits this contract's native balance between the recipients. Callable by anyone.
  /// @dev Kept for parity with the Aave V3 RevenueSplitter; the Hub holds no native currency.
  ///      As there, a failed send does not revert, so one recipient cannot block the other.
  ///      A share that rounds to zero is not sent and counts as sent.
  function splitNativeRevenue() external nonReentrant {
    uint256 balance = address(this).balance;
    if (balance == 0) {
      return;
    }

    uint256 amountA = balance.percentMulDown(SPLIT_PERCENTAGE_RECIPIENT_A);
    uint256 amountB = balance - amountA;

    bool sentA = _sendNative(RECIPIENT_A, amountA);
    bool sentB = _sendNative(RECIPIENT_B, amountB);
    emit NativeRevenueSplit(amountA, amountB, sentA, sentB);
  }

  /// @notice Allows or disallows `hub` for `splitRevenue`.
  function setHubAllowed(address hub, bool allowed) external onlyOwner {
    _setHubAllowed(hub, allowed);
  }

  /// @notice Calls the TreasurySpoke as its owner, preserving every owner power over it.
  /// @dev Used for `acceptOwnership` after the handover, `transferOwnership` to hand it back,
  ///      and `supplySkimmed`, `transfer` or `withdraw` outside the split. A plain `withdraw`
  ///      leaves the tokens here; `rescueToken` moves them on.
  function executeOnTreasury(bytes calldata data) external onlyOwner returns (bytes memory result) {
    bool success;
    (success, result) = address(TREASURY_SPOKE).call(data);
    if (!success) {
      assembly ('memory-safe') {
        revert(add(result, 0x20), mload(result))
      }
    }
    emit TreasuryCallExecuted(data, result);
  }

  /// @notice Moves ERC-20 tokens held by this contract. `splitRevenue` never leaves a balance
  ///         here, so anything held came from an owner `withdraw` or a direct transfer.
  function rescueToken(address token, address to, uint256 amount) external onlyOwner {
    if (to == address(0)) revert InvalidAddress();
    IERC20(token).safeTransfer(to, amount);
    emit TokenRescued(token, to, amount);
  }

  receive() external payable {}

  function _setHubAllowed(address hub, bool allowed) internal {
    if (hub == address(0)) revert InvalidAddress();
    isHubAllowed[hub] = allowed;
    emit HubAllowedUpdated(hub, allowed);
  }

  /// @dev Failures do not revert, matching the Aave V3 RevenueSplitter; the caller records them.
  function _sendNative(address payable to, uint256 amount) internal returns (bool sent) {
    if (amount == 0) {
      return true;
    }
    (sent, ) = to.call{value: amount}('');
  }
}
