#!/usr/bin/env bash
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# EIP-8321 Kurtosis devnet: fork, register hash-chain commitments, check reveals.
# Usage: scripts/kurtosis_eip8321.sh [--no-build] [--cleanup]
# Other clients: uncomment their participants in kurtosis-eip8321-params.yml.

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1 CLEANUP=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --cleanup) CLEANUP=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

ENCLAVE="${ENCLAVE:-eip8321}"
SLOTS_PER_EPOCH=8
COMMITMENT_REGISTRATION_DELAY=3
export NIMBUS_IMAGE="${NIMBUS_IMAGE:-nimbus-eip8321-minimal}"
export GRANDINE_IMAGE="${GRANDINE_IMAGE:-ghcr.io/lukassta/grandine:eip8321-minimal}"
export EIP8321_FORK_EPOCH="${EIP8321_FORK_EPOCH:-3}"

for cmd in docker kurtosis jq curl envsubst; do
  command -v "$cmd" > /dev/null || { echo "Missing $cmd" >&2; exit 1; }
done

if [[ "$BUILD" == 1 ]]; then
  docker build --build-arg PRESET=minimal -t "$NIMBUS_IMAGE" .
  docker build -t eip8321-genesis-generator docker/eip8321-genesis-generator
fi

# Pinned: later ethereum-package revisions need a newer Kurtosis than 1.22
ETHEREUM_PACKAGE_REF="${ETHEREUM_PACKAGE_REF:-5795b77e65235ad223d4d3b413b2739190bf60cc}"
kurtosis run --enclave "$ENCLAVE" "github.com/ethpandaops/ethereum-package@$ETHEREUM_PACKAGE_REF" \
  --args-file <(envsubst < kurtosis-eip8321-params.yml)

NIMBUS_SERVICES=$(kurtosis enclave inspect "$ENCLAVE" |
  grep -o 'cl-[0-9]*-nimbus-[a-z]*' | sort -u)
OTHER_SERVICES=$(kurtosis enclave inspect "$ENCLAVE" |
  grep -o 'cl-[0-9]*-[a-z]*-[a-z]*' | grep -v nimbus | sort -u)
BN_SERVICE=$(echo "$NIMBUS_SERVICES" | head -n1)
BN_URL=$(kurtosis port print "$ENCLAVE" "$BN_SERVICE" http)

head_epoch() {
  local slot best=0 svc url
  for svc in $NIMBUS_SERVICES $OTHER_SERVICES; do
    url=$(kurtosis port print "$ENCLAVE" "$svc" http) || continue
    slot=$(curl -sf "$url/eth/v1/beacon/headers/head" |
      jq -r '.data.header.message.slot') || continue
    (( slot > best )) && best=$slot
  done
  (( best > 0 )) || return 1
  echo $(( best / SLOTS_PER_EPOCH ))
}

wait_for_epoch() {
  echo "Waiting for epoch $1"
  local epoch failures=0
  while :; do
    if epoch=$(head_epoch); then
      failures=0
      (( epoch >= $1 )) && break
    elif (( ++failures >= 10 )); then
      echo "No beacon node reachable for 2 minutes" >&2; exit 1
    fi
    sleep 12
  done
}

wait_for_epoch "$EIP8321_FORK_EPOCH"

for svc in $NIMBUS_SERVICES; do
  echo "Registering RANDAO commitments on $svc"
  # Reuse the running node's flags so keys and network match
  # The running node holds the keystore locks, so register from a copy
  kurtosis service exec "$ENCLAVE" "$svc" '
    flags=$(tr "\0 " "\n\n" < /proc/1/cmdline |
      grep -E "^--(network|data-dir|secrets-dir)=" | tr "\n" " ")
    keys=$(tr "\0 " "\n\n" < /proc/1/cmdline | sed -n "s/^--validators-dir=//p")
    rm -rf /tmp/regkeys && cp -r "$keys" /tmp/regkeys &&
    /home/user/nimbus-eth2/build/nimbus_beacon_node $flags --validators-dir=/tmp/regkeys \
      deposits registerRandaoCommitment --all --rest-url=http://127.0.0.1:4000'
done

ACTIVATION_EPOCH=$(( EIP8321_FORK_EPOCH + COMMITMENT_REGISTRATION_DELAY + 1 ))
wait_for_epoch "$ACTIVATION_EPOCH"

RESULT=failure
REVEAL_SLOT=
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
for _ in $(seq 1 $(( 4 * SLOTS_PER_EPOCH ))); do
  for svc in $NIMBUS_SERVICES $OTHER_SERVICES; do
    url=$(kurtosis port print "$ENCLAVE" "$svc" http) || continue
    REVEAL_SLOT=$(curl -sf "$url/eth/v2/beacon/blocks/head" | jq -r --arg z "$ZERO" '.data.message |
      select(.body.hash_chain_reveal != $z and (.body.randao_reveal | startswith("0xc0"))) | .slot')
    [[ -n "$REVEAL_SLOT" ]] && { RESULT=success; break 2; }
  done
  sleep 12
done
echo "Hash chain reveal block slot: ${REVEAL_SLOT:-none}"

for svc in $NIMBUS_SERVICES $OTHER_SERVICES; do
  url=$(kurtosis port print "$ENCLAVE" "$svc" http) || continue
  echo "$svc head: $(curl -sf "$url/eth/v1/beacon/headers/head" | jq -r '.data | "\(.header.message.slot) \(.root)"')"
  [[ -n "$REVEAL_SLOT" ]] && curl -sf "$url/eth/v2/beacon/blocks/$REVEAL_SLOT" |
    jq -c '.data.message | {slot, proposer_index, state_root, hash_chain_reveal: .body.hash_chain_reveal, randao_reveal: .body.randao_reveal[0:10]}' |
    sed "s|^|$svc serves reveal block: |" || echo "$svc does not serve slot $REVEAL_SLOT"
  curl -sf "$url/eth/v2/debug/beacon/states/head" | jq -c --arg z "$ZERO" '.data | {slot, pending: (.pending_randao_commitments | length), registered: ([.randao_commitments[] | select(. != $z)] | length)}' |
    sed "s|^|$svc state: |"
done

finalized=$(curl -sf "$BN_URL/eth/v1/beacon/states/head/finality_checkpoints" |
  jq -r '.data.finalized.epoch')
echo "Finalized epoch: $finalized (head epoch $(head_epoch))"
(( finalized >= ACTIVATION_EPOCH - 2 )) || RESULT=failure

echo "test_result=$RESULT"

if [[ "$CLEANUP" == 1 ]]; then
  kurtosis enclave rm -f "$ENCLAVE"
fi

[[ "$RESULT" == success ]]
