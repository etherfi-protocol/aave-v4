#!/usr/bin/env bash
# ether.fi Cash Aave V4 — full launch dress rehearsal on a doctored OP Mainnet fork.
#
# Runs every pre-launch check end to end and prints PASS/FAIL per step:
#   1. toolchain + repo sanity
#   2. registry pins present (no TBD / zero addresses)
#   3. live deployer nonce == 3 on OP Mainnet
#   4. canonical LiquidationLogic bytecode fetched from Ethereum
#   5. anvil fork of OP Mainnet started
#   6. LiquidationLogic etched at the canonical address on the fork (if absent)
#   7. build with FOUNDRY_LIBRARIES linking the canonical library
#   8. instance deployment SIMULATED as the real deployer (report vs registry assert)
#   9. read-only preflight validator against the fork
#  10. two-phase fork rehearsal test (deploy payloads -> Safe-context execute -> verify)
#
# Usage:  OP_ARCHIVE_RPC=<url> ./etherfi-rehearse-all.sh
# Run from the repo root of etherfi-protocol/aave-v4 (branch with the canonical-library re-pin).
#
# NOTE: step 6 makes the rehearsal ASSUME Aave deploys LiquidationLogic on OP at the same
# address as Ethereum mainnet. That assumption is not confirmed by Aave — this script tests
# ether.fi's side of the launch only.

set -uo pipefail

# ------------------------------------------------------------------ config
DEPLOYER=0xf8a86ea1Ac39EC529814c377Bd484387D395421e
LIB_ADDR=0x88dF535473C5adf1f57789734A05E555F7Deb8DB
LIB_LINK="src/spoke/libraries/LiquidationLogic.sol:LiquidationLogic:${LIB_ADDR}"
ETH_RPC="${ETH_RPC:-https://ethereum-rpc.publicnode.com}"
OP_ARCHIVE_RPC="${OP_ARCHIVE_RPC:?set OP_ARCHIVE_RPC to an OP Mainnet archive RPC url}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
FORK_RPC="http://127.0.0.1:${ANVIL_PORT}"
REGISTRY=src/etherfi/AaveV4EtherfiCash.sol
LOG_DIR="$(mktemp -d /tmp/etherfi-rehearsal.XXXXXX)"

# ------------------------------------------------------------------ helpers
STEP=0
PASS_COUNT=0
step()  { STEP=$((STEP+1)); printf '\n\033[1m[step %2d] %s\033[0m\n' "$STEP" "$1"; }
pass()  { PASS_COUNT=$((PASS_COUNT+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && { echo '  --- last log lines ---'; tail -20 "$2" | sed 's/^/  /'; }; summary 1; }
info()  { printf '  \033[2minfo\033[0m  %s\n' "$1"; }
summary() {
  printf '\n\033[1m== result: %d/%d steps passed — %s ==\033[0m\n' \
    "$PASS_COUNT" "$STEP" "$( [[ "${1:-0}" == 0 ]] && echo 'REHEARSAL PASSED' || echo 'REHEARSAL FAILED' )"
  echo "logs: $LOG_DIR"
  exit "${1:-0}"
}
ANVIL_PID=""
cleanup() { [[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null; }
trap cleanup EXIT

# ------------------------------------------------------------------ 1. toolchain + repo
step "toolchain and repo sanity"
for bin in forge cast anvil python3; do
  command -v "$bin" >/dev/null || fail "$bin not found in PATH"
done
[[ -f foundry.toml && -f "$REGISTRY" && -d scripts/etherfi ]] \
  || fail "run from the repo root of etherfi-protocol/aave-v4 (missing $REGISTRY)"
info "branch: $(git branch --show-current 2>/dev/null || echo '?') @ $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
pass "forge/cast/anvil present, repo layout ok"

# ------------------------------------------------------------------ 2. registry pins
step "registry pins in $REGISTRY (no TBD / zero addresses)"
# strip comment lines, then look for real placeholder ASSIGNMENTS (not docs mentioning them)
if grep -vE '^\s*(///|//|\*)' "$REGISTRY" \
   | grep -nE 'TBD|=\s*address\(0\)|=\s*0x0{40}' >"$LOG_DIR/registry.log"; then
  fail "registry contains placeholder (zero/TBD) address constants — payload will silently skip staged assets" "$LOG_DIR/registry.log"
fi
CASH_SPOKE=$(grep -oE 'CASH_SPOKE = (0x[0-9a-fA-F]{40})' "$REGISTRY" | head -1 | awk '{print $3}')
CASH_IMPL=$(grep -oE 'CASH_SPOKE_IMPLEMENTATION = (0x[0-9a-fA-F]{40})' "$REGISTRY" | head -1 | awk '{print $3}')
[[ -n "$CASH_SPOKE" && -n "$CASH_IMPL" ]] || fail "could not parse CASH_SPOKE pins from registry"
info "CASH_SPOKE                $CASH_SPOKE"
info "CASH_SPOKE_IMPLEMENTATION $CASH_IMPL"
info "eyeball-check these against the LATEST re-pin (post canonical-library relink)"
pass "registry fully pinned"

# ------------------------------------------------------------------ 3. deployer nonce
step "live deployer nonce on OP Mainnet (must be exactly 3)"
NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$OP_ARCHIVE_RPC") || fail "could not query nonce via OP_ARCHIVE_RPC"
if [[ "$NONCE" != "3" ]]; then
  fail "deployer $DEPLOYER is at nonce $NONCE, expected 3 — nonce-dependent pins (AaveOracle, Cash Spoke) are INVALID"
fi
pass "deployer at nonce 3"

# ------------------------------------------------------------------ 4. canonical library bytecode
step "fetch canonical LiquidationLogic bytecode from Ethereum mainnet"
LIB_CODE=$(cast code "$LIB_ADDR" --rpc-url "$ETH_RPC") || fail "could not query $ETH_RPC"
[[ "$LIB_CODE" != "0x" && ${#LIB_CODE} -gt 100 ]] || fail "no code at $LIB_ADDR on Ethereum mainnet"
info "runtime code: $(( (${#LIB_CODE} - 2) / 2 )) bytes"
pass "canonical library bytecode fetched"

# ------------------------------------------------------------------ 5. anvil fork
step "start anvil fork of OP Mainnet on port $ANVIL_PORT"
anvil --fork-url "$OP_ARCHIVE_RPC" --port "$ANVIL_PORT" --auto-impersonate --silent >"$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 30); do
  CHAIN_ID=$(cast chain-id --rpc-url "$FORK_RPC" 2>/dev/null) && break
  sleep 1
done
[[ "${CHAIN_ID:-}" == "10" ]] || fail "anvil fork did not come up as chainid 10" "$LOG_DIR/anvil.log"
pass "fork live (chainid 10, pid $ANVIL_PID)"

# ------------------------------------------------------------------ 6. etch library on fork
step "LiquidationLogic code at $LIB_ADDR on the fork"
FORK_LIB=$(cast code "$LIB_ADDR" --rpc-url "$FORK_RPC")
if [[ "$FORK_LIB" == "0x" ]]; then
  info "not deployed on OP yet — etching Ethereum bytecode (ASSUMPTION: same address on OP)"
  cast rpc anvil_setCode "$LIB_ADDR" "$LIB_CODE" --rpc-url "$FORK_RPC" >/dev/null \
    || fail "anvil_setCode failed"
  [[ "$(cast code "$LIB_ADDR" --rpc-url "$FORK_RPC")" == "$LIB_CODE" ]] || fail "etch verification failed"
  pass "library etched on fork (SIMULATED — real OP deployment still pending on Aave)"
else
  [[ "$FORK_LIB" == "$LIB_CODE" ]] || fail "library IS on OP but bytecode differs from Ethereum — stop and investigate"
  pass "library already live on OP with byte-identical code (no etch needed)"
fi

# ------------------------------------------------------------------ 7. linked build
step "forge build with FOUNDRY_LIBRARIES=$LIB_LINK"
export FOUNDRY_LIBRARIES="$LIB_LINK"
forge build >"$LOG_DIR/build.log" 2>&1 || fail "build failed" "$LOG_DIR/build.log"
pass "compiled with canonical library linked"

# ------------------------------------------------------------------ 8a. config engine on fork
step "config engine at pinned address on the fork (deploy if absent)"
ENGINE=$(grep -oE 'CONFIG_ENGINE = (0x[0-9a-fA-F]{40})' "$REGISTRY" | head -1 | awk '{print $3}')
[[ -n "$ENGINE" ]] || fail "could not parse CONFIG_ENGINE from registry"
if [[ "$(cast code "$ENGINE" --rpc-url "$FORK_RPC")" == "0x" ]]; then
  # CREATE2 via the Safe Singleton Factory -> address is sender-independent, so any
  # funded anvil account works; the real deployer's nonce-3 state stays untouched.
  ANVIL_ACCT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  SKIP_PROMPT=true forge script scripts/etherfi/DeployEtherfiCashConfigEngine.s.sol:DeployEtherfiCashConfigEngineScript \
    --rpc-url "$FORK_RPC" --sender "$ANVIL_ACCT" --unlocked --broadcast \
    >"$LOG_DIR/engine-deploy.log" 2>&1 \
    || fail "config engine deployment failed" "$LOG_DIR/engine-deploy.log"
  [[ "$(cast code "$ENGINE" --rpc-url "$FORK_RPC")" != "0x" ]] \
    || fail "engine deploy ran but no code at pinned $ENGINE — engine prediction is wrong" "$LOG_DIR/engine-deploy.log"
  pass "config engine deployed on fork at pinned $ENGINE"
else
  pass "config engine already live at pinned $ENGINE"
fi

# ------------------------------------------------------------------ 8b. instance deploy (BROADCAST to fork)
step "instance deployment BROADCAST to fork as impersonated $DEPLOYER (report-vs-registry assert)"
FORK_NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$FORK_RPC")
[[ "$FORK_NONCE" == "3" ]] || fail "deployer nonce on fork is $FORK_NONCE, expected 3 — did an earlier step send a tx from it?"
cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$FORK_RPC" >/dev/null  # 100 ETH gas money
SKIP_PROMPT=true forge script scripts/etherfi/DeployEtherfiCashInstance.s.sol:DeployEtherfiCashInstanceScript \
  --rpc-url "$FORK_RPC" --sender "$DEPLOYER" --unlocked --broadcast \
  >"$LOG_DIR/deploy-sim.log" 2>&1 \
  || fail "instance deployment reverted — check for ReportMismatch(name, actual, expected)" "$LOG_DIR/deploy-sim.log"
grep -q 'ReportMismatch' "$LOG_DIR/deploy-sim.log" \
  && fail "ReportMismatch in deployment output" "$LOG_DIR/deploy-sim.log"
CASH_SPOKE_CODE=$(cast code "$CASH_SPOKE" --rpc-url "$FORK_RPC")
[[ "$CASH_SPOKE_CODE" != "0x" ]] || fail "no code at pinned CASH_SPOKE $CASH_SPOKE after deployment"
pass "instance live on fork; every report address matches the AaveV4EtherfiCash registry"

# ------------------------------------------------------------------ 9. preflight validator
step "read-only preflight validator against the fork"
forge script scripts/etherfi/ValidateEtherfiCashLaunch.s.sol:ValidateEtherfiCashLaunchScript \
  --rpc-url "$FORK_RPC" >"$LOG_DIR/validate.log" 2>&1 \
  || fail "validator script reverted" "$LOG_DIR/validate.log"
grep -q 'blockers: 0' "$LOG_DIR/validate.log" || grep -q 'READY' "$LOG_DIR/validate.log" \
  || fail "preflight reports blockers" "$LOG_DIR/validate.log"
pass "preflight clean"

# ------------------------------------------------------------------ 10. two-phase fork rehearsal
step "two-phase fork rehearsal (payloads -> Safe-context delegatecall -> field-by-field verify)"
forge test --match-path tests/etherfi/EtherfiCashLaunchFork.t.sol \
  --fork-url "$FORK_RPC" -vv >"$LOG_DIR/rehearsal.log" 2>&1 \
  || fail "fork rehearsal test failed" "$LOG_DIR/rehearsal.log"
grep -qE '\[PASS\].*test_fork_fullLaunchRehearsal' "$LOG_DIR/rehearsal.log" \
  || fail "test_fork_fullLaunchRehearsal did not pass (skipped or renamed?)" "$LOG_DIR/rehearsal.log"
pass "full two-phase launch rehearsal passed"

summary 0
