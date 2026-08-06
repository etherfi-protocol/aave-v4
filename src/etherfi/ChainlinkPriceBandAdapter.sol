// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.28;

import {
  IChainlinkAggregator,
  IChainlinkPriceBandAdapter
} from 'src/etherfi/interfaces/IChainlinkPriceBandAdapter.sol';

/// @title ChainlinkPriceBandAdapter
/// @notice Wraps a Chainlink price feed so that a single round cannot raise the reported price by
///         more than `BAND_BPS` over that feed's own previous round. Falls pass through untouched.
///
/// @dev WHY A BAND AND NOT A GROWTH CAP
///      Aave's CAPO adapters bound a *ratio* to a line that grows from a fixed snapshot. That is
///      the right shape for a slowly-accruing wrapper rate, and the wrong shape for a market price:
///      it cannot express a loose enough bound (`maxYearlyRatioGrowthPercent` is a uint16 in bps,
///      so the loosest possible is 655.35%/yr, i.e. 1.7955%/day), and it needs periodic
///      re-snapshotting or its line drifts so far above the market that it stops binding.
///
///      Measuring the two feeds this was built for settled the shape. Both are 0.5% deviation /
///      24h heartbeat, and elapsed time does not predict move size:
///        - SPY-USD (24/5) on OP: worst move vs the previous round +0.62%. Gaps over 12h produced
///          no larger a move (0.62%) than gaps under 12h (0.53%).
///        - PAXG/USD: worst +6.92% / -5.29% over 2,461 rounds and 362 days, and the relationship is
///          *inverted* - gaps under 12h carried the 6.92% move while gaps over 12h topped out at
///          0.94%.
///      That is the signature of a deviation-triggered feed: it publishes *because* the price
///      moved, so a long gap means nothing happened. Scaling an allowance by elapsed time therefore
///      grants the most room exactly when it is least needed. A flat band is the honest model.
///
/// @dev WHY UPWARD ONLY
///      A floor would convert a market loss into protocol bad debt: collateral keeps pricing above
///      what it is worth, liquidators will not bid, and the shortfall lands on suppliers. Aave's
///      own cap adapters clamp upward only for the same reason. If a downward bound is ever wanted
///      it belongs at the point of *ingestion* (reject the update, let staleness fire) rather than
///      here, where clamping would serve a knowingly wrong price indefinitely.
///
/// @dev SIZING THE BAND
///      Anchor it to market structure, not to fitted volatility. US equities have mandated
///      market-wide circuit breakers at -7% / -13% / -20%, where the last closes the session, so a
///      single session cannot move further than 20% - a 2000 bps band on an equity feed cannot
///      clamp a legitimate session by construction. For assets with no such halt, size from the
///      measured worst move over the consumer's staleness window plus margin. Both feeds above
///      clear 2000 bps with zero clamps across their full history.
///
///      A band that clamps in normal markets is worse than none: it trains operators to ignore it.
///
/// @dev STATELESS BY CONSTRUCTION
///      The reference is the feed's own previous round, read through `getRoundData`, so there is no
///      snapshot, no keeper, and no re-snapshot cadence for anyone to own and forget. The cost is
///      one extra staticcall per price read.
contract ChainlinkPriceBandAdapter is IChainlinkPriceBandAdapter {
  uint256 internal constant BPS = 10_000;

  /// @notice Tightest permitted band.
  /// @dev Both target feeds publish on a 0.5% deviation threshold, and that threshold is a trigger
  ///      rather than a bound - PAXG printed 6.92% in one round against it. A band under 1% would
  ///      clamp routine movement and pin the price to the previous round, so it is refused rather
  ///      than left as a footgun.
  uint16 public constant MIN_BAND_BPS = 100;

  /// @notice Loosest permitted band. A band at or above 100% cannot bind on any rise.
  uint16 public constant MAX_BAND_BPS = 10_000;

  /// @inheritdoc IChainlinkPriceBandAdapter
  IChainlinkAggregator public immutable FEED;

  /// @inheritdoc IChainlinkPriceBandAdapter
  uint16 public immutable BAND_BPS;

  /// @inheritdoc IChainlinkAggregator
  uint8 public immutable decimals;

  string private _description;

  /// @param feed The Chainlink feed to wrap. Must expose `getRoundData`, which is what makes the
  ///        previous-round reference possible.
  /// @param bandBps Maximum permitted rise over the previous round, in basis points.
  /// @param adapterDescription Human-readable description for this adapter.
  constructor(IChainlinkAggregator feed, uint16 bandBps, string memory adapterDescription) {
    if (address(feed) == address(0)) revert FeedIsZeroAddress();
    if (bandBps < MIN_BAND_BPS || bandBps > MAX_BAND_BPS) revert InvalidBand(bandBps);

    FEED = feed;
    BAND_BPS = bandBps;
    decimals = feed.decimals();
    _description = adapterDescription;
  }

  /// @inheritdoc IChainlinkAggregator
  function latestAnswer() external view returns (int256) {
    (, int256 answer, , , ) = _banded();
    return answer;
  }

  /// @inheritdoc IChainlinkAggregator
  /// @dev Reports the banded answer against the round's own id and timestamps, so a consumer's
  ///      staleness check still measures the underlying feed's age.
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    (roundId, answer, startedAt, updatedAt, ) = _banded();
    return (roundId, answer, startedAt, updatedAt, roundId);
  }

  /// @inheritdoc IChainlinkAggregator
  /// @dev Historical rounds are passed through unbanded: the band describes what this adapter will
  ///      report *now*, and rewriting history would misrepresent what the feed actually published.
  function getRoundData(
    uint80 roundId
  ) external view returns (uint80, int256, uint256, uint256, uint80) {
    return FEED.getRoundData(roundId);
  }

  /// @inheritdoc IChainlinkAggregator
  function latestTimestamp() external view returns (uint256) {
    return FEED.latestTimestamp();
  }

  /// @inheritdoc IChainlinkAggregator
  function latestRound() external view returns (uint256) {
    return FEED.latestRound();
  }

  /// @inheritdoc IChainlinkAggregator
  function description() external view returns (string memory) {
    return _description;
  }

  /// @inheritdoc IChainlinkPriceBandAdapter
  function rawAnswer() external view returns (int256) {
    (, , , , int256 raw) = _banded();
    return raw;
  }

  /// @inheritdoc IChainlinkPriceBandAdapter
  function referenceAnswer() external view returns (int256) {
    (int256 refPrice, ) = _reference();
    return refPrice;
  }

  /// @inheritdoc IChainlinkPriceBandAdapter
  function hasReference() external view returns (bool) {
    (, bool available) = _reference();
    return available;
  }

  /// @inheritdoc IChainlinkPriceBandAdapter
  function isCapped() external view returns (bool) {
    (, int256 answer, , , int256 raw) = _banded();
    return answer != raw;
  }

  /// @dev Reads the latest round and applies the band.
  /// @return roundId The feed's latest round id.
  /// @return answer The banded answer.
  /// @return startedAt The round's startedAt.
  /// @return updatedAt The round's updatedAt.
  /// @return raw The unmodified answer, for callers that want to know whether the band bound.
  function _banded()
    internal
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, int256 raw)
  {
    (roundId, raw, startedAt, updatedAt, ) = FEED.latestRoundData();
    if (raw <= 0) revert InvalidPrice();

    answer = raw;
    (int256 refPrice, bool available) = _reference();
    if (!available) return (roundId, answer, startedAt, updatedAt, raw);

    // refPrice is positive and bandBps <= 10_000, so this cannot overflow for any answer a
    // Chainlink aggregator can represent.
    int256 ceiling = refPrice + (refPrice * int256(uint256(BAND_BPS))) / int256(BPS);
    if (answer > ceiling) answer = ceiling;

    return (roundId, answer, startedAt, updatedAt, raw);
  }

  /// @dev The previous round's answer, within the same aggregator phase.
  ///
  ///      A Chainlink proxy round id packs `phaseId` in the high 16 bits and the aggregator's own
  ///      round in the low 64. Decrementing across a phase boundary reads a round that belongs to a
  ///      different aggregator, and in practice returns zero - `phase 2, round 0` on the live OP
  ///      SPY feed answers 0. So the phase is preserved and the first round of a phase is treated
  ///      as having no reference rather than banding against a bogus value.
  ///
  ///      Fails open: with no reference the raw answer passes through. That is the deliberate
  ///      choice over reverting, because a revert on a collateral price takes every action on the
  ///      reserve with it, including liquidation. `hasReference()` exposes the condition so it can
  ///      be alerted on instead.
  function _reference() internal view returns (int256 answer, bool available) {
    uint256 latest = FEED.latestRound();
    uint64 aggregatorRound = uint64(latest);
    if (aggregatorRound <= 1) return (0, false);

    uint80 previousId = uint80(
      (uint256(uint16(latest >> 64)) << 64) | uint256(aggregatorRound - 1)
    );

    try FEED.getRoundData(previousId) returns (
      uint80,
      int256 previous,
      uint256,
      uint256 previousUpdatedAt,
      uint80
    ) {
      if (previous <= 0 || previousUpdatedAt == 0) return (0, false);
      return (previous, true);
    } catch {
      return (0, false);
    }
  }
}
