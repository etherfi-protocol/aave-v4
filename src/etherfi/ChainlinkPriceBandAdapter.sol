// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.28;

import {
  IChainlinkAggregator,
  IChainlinkPriceBandAdapter
} from 'src/etherfi/interfaces/IChainlinkPriceBandAdapter.sol';

/// @title ChainlinkPriceBandAdapter
/// @notice Wraps a Chainlink price feed so that a single round cannot move the reported price by
///         more than `BAND_BPS` in either direction, measured against that feed's own previous
///         round. A rate limiter on price change, not a hard ceiling or floor.
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
/// @dev WHY BOTH DIRECTIONS
///      A manipulated *downward* print is as damaging as an upward one, and lands on a different
///      party: healthy positions are marked underwater and liquidated at a price that never
///      existed, which is irreversible for the borrower. An upward-only bound leaves that open.
///
///      The usual objection to a floor - that it hides insolvency and lets bad debt accrue - does
///      not apply here, because the reference is the FEED's own previous round, never this
///      adapter's clamped output. A genuine crash therefore converges in a bounded number of
///      rounds rather than being held up indefinitely. With a 20% band:
///
///        round N    feed 100  ->  reports 100
///        round N+1  feed  50  ->  reference 100, floor 80  ->  reports 80   (one round behind)
///        round N+2  feed  50  ->  reference  50, floor 40  ->  reports 50   (caught up)
///
///      In general a move of X% converges in ceil(X / BAND_BPS) rounds, so the band is a rate
///      limit on price change rather than a bound on price. That is what makes a floor safe: it
///      buys time to notice a manipulation without ever permanently mispricing collateral.
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
///      With a two-sided band the choice also sets how fast a real crash propagates: a move of X%
///      needs ceil(X / BAND_BPS) rounds to be fully reflected. At 2000 bps a 40% crash is one round
///      behind; at 100 bps it would be nineteen, which is why the floor on BAND_BPS is not 100.
///
/// @dev STATELESS BY CONSTRUCTION
///      The reference is the feed's own previous round, read through `getRoundData`, so there is no
///      snapshot, no keeper, and no re-snapshot cadence for anyone to own and forget. The cost is
///      one extra staticcall per price read.
contract ChainlinkPriceBandAdapter is IChainlinkPriceBandAdapter {
  uint256 internal constant BPS = 10_000;

  /// @notice Tightest permitted band.
  /// @dev Two constraints meet here. Both target feeds publish on a 0.5% deviation threshold, and
  ///      that threshold is a trigger rather than a bound - PAXG printed 6.92% in one round against
  ///      it - so a band near the threshold would clamp routine movement. And because the band is
  ///      two-sided, it also rate-limits how fast a genuine crash reaches consumers: X% takes
  ///      ceil(X / BAND_BPS) rounds. 500 bps is ten times the deviation threshold and bounds a 50%
  ///      crash to ten rounds. Tighter than this is refused rather than left as a footgun.
  uint16 public constant MIN_BAND_BPS = 500;

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

    // refPrice is positive and BAND_BPS <= 10_000, so neither bound can overflow for any answer a
    // Chainlink aggregator can represent, and the floor cannot go negative.
    int256 delta = (refPrice * int256(uint256(BAND_BPS))) / int256(BPS);
    int256 ceiling = refPrice + delta;
    int256 floor = refPrice - delta;
    if (answer > ceiling) answer = ceiling;
    else if (answer < floor) answer = floor;

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
