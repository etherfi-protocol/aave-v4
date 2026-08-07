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
///      WIDEN_PERIOD is the second dial and bounds that in wall-clock time. Size it to how long
///      triaging a clamp realistically takes - an hour is a reasonable default for an alert that
///      pages a human - not to the feed's heartbeat.
///
/// @dev THE REFERENCE IS ANCHORED IN TIME, NOT IN ROUND INDEX
///      Bounding a round against its immediate predecessor bounds nothing when rounds are cheap.
///      Compounding at 20% a round, four rounds halve a price and thirteen produce a ten-fold move,
///      with every single step passing the check. This is not hypothetical: the live PAXG feed on
///      Optimism has published three rounds inside one block, and its minimum observed gap between
///      rounds is zero seconds.
///
///      So the reference is the newest round at least `REFERENCE_AGE` old. A burst of rounds all
///      measure against the same anchor, and the total move is bounded by one band per
///      `REFERENCE_AGE` no matter how many rounds are posted. The guarantee changes from "20% per
///      round", which is meaningless when rounds are free, to "20% per hour", which is not.
///
///      Sized against measurement: the worst one-hour move in the full history of these feeds is
///      7.50% for PAXG and 1.54% for SPY, both comfortably inside a 2000 bps band, so a one-hour
///      anchor never binds on honest movement.
///
///      The residual, stated plainly: a `view` function has to bound its lookback for gas, so an
///      attacker who floods more than `MAX_LOOKBACK` rounds inside the window falls back to the
///      oldest reachable round and escapes at one band per `MAX_LOOKBACK` rounds. Closing that
///      completely needs stored state, which this cannot have. `referenceIsAnchored()` reports when
///      the fallback is in use.
///
/// @dev THE BAND WIDENS WITH THE AGE OF THE ROUND
///      A fixed band has a failure mode that only shows up when a big move is followed by a quiet
///      market. The clamp holds, the price stops moving, so the feed's deviation trigger never fires
///      again, and the remaining move is not reported until the heartbeat elapses - up to 24h on
///      these feeds. Clamped upward that under-prices collateral; clamped downward it over-prices
///      it, and liquidations that should fire do not.
///
///      So the band grows linearly with how long the current round has been the latest:
///
///        effectiveBand = BAND_BPS * (1 + age / WIDEN_PERIOD)
///
///      A clamp is then a decaying speed bump rather than a wall. It is full strength on arrival,
///      when a bad print is most likely to be acted on by a liquidator, and releases over the
///      following hours if the feed keeps insisting.
///
///      Read the trade honestly: this WEAKENS protection against a sustained manipulation, because a
///      value the attacker holds flat is accepted in hours rather than at the next heartbeat. The
///      protection was always bounded at one round; widening bounds it in wall-clock time too. It is
///      the right trade only if a clamp is actually alerted on and acted upon - `isCapped()` is an
///      alert with a deadline, and WIDEN_PERIOD sets that deadline.
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

  /// @notice Tightest permitted widen period. Shorter than this and the band releases before anyone
  ///         could plausibly triage a clamp.
  uint32 public constant MIN_WIDEN_PERIOD = 15 minutes;

  /// @notice Longest permitted widen period. Beyond this the widening does not meaningfully bound
  ///         the mispricing window, which is the whole reason it exists.
  uint32 public constant MAX_WIDEN_PERIOD = 2 days;

  /// @dev Ceiling on the widened band, so a feed that dies does not overflow the delta arithmetic.
  ///      At 100x the band nothing meaningful is being clamped anyway.
  uint256 internal constant MAX_EFFECTIVE_BAND_BPS = 1_000_000;

  /// @notice Shortest permitted reference age.
  uint32 public constant MIN_REFERENCE_AGE = 5 minutes;

  /// @notice Longest permitted reference age. Beyond this the reference predates a full heartbeat
  ///         on these feeds and the band would start binding on ordinary movement.
  uint32 public constant MAX_REFERENCE_AGE = 12 hours;

  /// @notice How many rounds back the search for an anchor will walk before giving up.
  /// @dev Every step is a staticcall, so this is a gas bound as much as a security one. The normal
  ///      case exits on the first step, because these feeds publish far less often than the anchor
  ///      window. Only a burst walks further.
  uint256 public constant MAX_LOOKBACK = 16;

  /// @inheritdoc IChainlinkPriceBandAdapter
  IChainlinkAggregator public immutable FEED;

  /// @inheritdoc IChainlinkPriceBandAdapter
  uint16 public immutable BAND_BPS;

  /// @inheritdoc IChainlinkPriceBandAdapter
  uint32 public immutable WIDEN_PERIOD;

  /// @inheritdoc IChainlinkPriceBandAdapter
  uint32 public immutable REFERENCE_AGE;

  /// @inheritdoc IChainlinkAggregator
  uint8 public immutable decimals;

  string private _description;

  /// @param feed The Chainlink feed to wrap. Must expose `getRoundData`, which is what makes the
  ///        previous-round reference possible.
  /// @param bandBps Band applied to a freshly published round, in basis points.
  /// @param widenPeriod Seconds of round age that add one further `bandBps` to the band. Size it to
  ///        how long triaging a clamp actually takes: it is the deadline on acting before the clamp
  ///        starts releasing.
  /// @param adapterDescription Human-readable description for this adapter.
  /// @param referenceAge How far back the reference round must sit, in seconds. This is the unit
  ///        the band is denominated in: at 2000 bps and one hour, the bound is 20% per hour.
  constructor(
    IChainlinkAggregator feed,
    uint16 bandBps,
    uint32 widenPeriod,
    uint32 referenceAge,
    string memory adapterDescription
  ) {
    if (address(feed) == address(0)) revert FeedIsZeroAddress();
    if (bandBps < MIN_BAND_BPS || bandBps > MAX_BAND_BPS) revert InvalidBand(bandBps);
    if (widenPeriod < MIN_WIDEN_PERIOD || widenPeriod > MAX_WIDEN_PERIOD) {
      revert InvalidWidenPeriod(widenPeriod);
    }
    if (referenceAge < MIN_REFERENCE_AGE || referenceAge > MAX_REFERENCE_AGE) {
      revert InvalidReferenceAge(referenceAge);
    }

    FEED = feed;
    BAND_BPS = bandBps;
    WIDEN_PERIOD = widenPeriod;
    REFERENCE_AGE = referenceAge;
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
    (int256 refPrice, , ) = _reference();
    return refPrice;
  }

  /// @inheritdoc IChainlinkPriceBandAdapter
  function hasReference() external view returns (bool) {
    (, bool available, ) = _reference();
    return available;
  }

  /// @inheritdoc IChainlinkPriceBandAdapter
  function referenceIsAnchored() external view returns (bool) {
    (, , bool anchored) = _reference();
    return anchored;
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
    (int256 refPrice, bool available, ) = _reference();
    if (!available) return (roundId, answer, startedAt, updatedAt, raw);

    uint256 eff = _effectiveBandBps(updatedAt);
    // refPrice is positive and eff is capped at MAX_EFFECTIVE_BAND_BPS, so the delta cannot overflow
    // for any answer a Chainlink aggregator can represent.
    int256 delta = (refPrice * int256(eff)) / int256(BPS);
    int256 ceiling = refPrice + delta;
    // Once the widened band reaches 100% the floor would be non-positive, which is simply no lower
    // bound at all. Report it as 1 wei so the invariant "never returns a non-positive price" holds
    // without the floor doing any work.
    int256 floor = eff >= BPS ? int256(1) : refPrice - delta;
    if (answer > ceiling) answer = ceiling;
    else if (answer < floor) answer = floor;

    return (roundId, answer, startedAt, updatedAt, raw);
  }

  /// @inheritdoc IChainlinkPriceBandAdapter
  function effectiveBandBps() external view returns (uint256) {
    (, , , uint256 updatedAt, ) = FEED.latestRoundData();
    return _effectiveBandBps(updatedAt);
  }

  /// @inheritdoc IChainlinkPriceBandAdapter
  function roundAge() external view returns (uint256) {
    (, , , uint256 updatedAt, ) = FEED.latestRoundData();
    return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
  }

  /// @dev `BAND_BPS * (1 + age / WIDEN_PERIOD)`, so the band is exactly `BAND_BPS` on a freshly
  ///      published round and gains another `BAND_BPS` for every `WIDEN_PERIOD` it goes unrefreshed.
  ///      A round timestamped in the future (clock skew between the feed and this chain) reads as
  ///      age zero rather than underflowing.
  function _effectiveBandBps(uint256 updatedAt) internal view returns (uint256) {
    uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    uint256 eff = uint256(BAND_BPS) + (uint256(BAND_BPS) * age) / WIDEN_PERIOD;
    return eff > MAX_EFFECTIVE_BAND_BPS ? MAX_EFFECTIVE_BAND_BPS : eff;
  }

  /// @dev The newest round that is at least `REFERENCE_AGE` old, within the same aggregator phase.
  ///
  ///      Walking back in TIME rather than taking `latestRound - 1` is what makes the band a bound
  ///      per hour instead of per round. A burst of rounds inside the window all resolve to the same
  ///      anchor, so posting more rounds buys no further movement.
  ///
  ///      A Chainlink proxy round id packs `phaseId` in the high 16 bits and the aggregator's own
  ///      round in the low 64. Decrementing across a phase boundary reads a different aggregator and
  ///      in practice answers zero - `phase 2, round 0` on the live OP SPY feed does exactly that.
  ///      So the phase is fixed for the whole walk, and the start of a phase ends it.
  ///
  ///      Fails open: with no usable round the raw answer passes through, rather than reverting. A
  ///      revert on a collateral price takes every action on the reserve with it, liquidation
  ///      included. `hasReference()` and `referenceIsAnchored()` expose both degraded states.
  function _reference() internal view returns (int256 answer, bool available, bool anchored) {
    uint256 latest = FEED.latestRound();
    uint64 round = uint64(latest);
    if (round <= 1) return (0, false, false);

    uint256 phase = uint256(uint16(latest >> 64)) << 64;
    uint256 cutoff = block.timestamp > REFERENCE_AGE ? block.timestamp - REFERENCE_AGE : 0;

    for (uint256 i = 0; i < MAX_LOOKBACK; ++i) {
      round -= 1;
      try FEED.getRoundData(uint80(phase | uint256(round))) returns (
        uint80,
        int256 previous,
        uint256,
        uint256 previousUpdatedAt,
        uint80
      ) {
        // A hole in history ends the walk; keep whatever was already reached.
        if (previous <= 0 || previousUpdatedAt == 0) break;
        answer = previous;
        available = true;
        if (previousUpdatedAt <= cutoff) return (answer, true, true);
      } catch {
        break;
      }
      if (round <= 1) break;
    }

    // The lookback ran out or the phase began. Whatever was reached is the furthest back available
    // and therefore the most conservative reference on offer, but it is NOT anchored in time and
    // callers are told so.
    return (answer, available, false);
  }
}
