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
SLOTS_PER_EPOCH=32
COMMITMENT_REGISTRATION_DELAY=3
export NIMBUS_IMAGE="${NIMBUS_IMAGE:-nimbus-eip8321}"
export EIP8321_FORK_EPOCH="${EIP8321_FORK_EPOCH:-3}"

for cmd in docker kurtosis jq curl envsubst; do
  command -v "$cmd" > /dev/null || { echo "Missing $cmd" >&2; exit 1; }
done

if [[ "$BUILD" == 1 ]]; then
  docker build -t "$NIMBUS_IMAGE" .
  docker build -t eip8321-genesis-generator docker/eip8321-genesis-generator
fi

kurtosis run --enclave "$ENCLAVE" github.com/ethpandaops/ethereum-package \
  --args-file <(envsubst < kurtosis-eip8321-params.yml)

NIMBUS_SERVICES=$(kurtosis enclave inspect "$ENCLAVE" |
  grep -o 'cl-[0-9]*-nimbus-[a-z]*' | sort -u)
BN_SERVICE=$(echo "$NIMBUS_SERVICES" | head -n1)
BN_URL=$(kurtosis port print "$ENCLAVE" "$BN_SERVICE" http)

head_epoch() {
  local slot
  slot=$(curl -sf "$BN_URL/eth/v1/beacon/headers/head" |
    jq -r '.data.header.message.slot') || slot=0
  echo $(( slot / SLOTS_PER_EPOCH ))
}

wait_for_epoch() {
  echo "Waiting for epoch $1"
  until (( $(head_epoch) >= $1 )); do sleep 12; done
}

wait_for_epoch "$EIP8321_FORK_EPOCH"

for svc in $NIMBUS_SERVICES; do
  echo "Registering RANDAO commitments on $svc"
  # Reuse the running node's flags so keys and network match
  kurtosis service exec "$ENCLAVE" "$svc" '
    flags=$(tr "\0" "\n" < /proc/1/cmdline |
      grep -E "^--(network|data-dir|validators-dir|secrets-dir)=" | tr "\n" " ")
    /home/user/nimbus-eth2/build/nimbus_beacon_node $flags \
      deposits registerRandaoCommitment --all --rest-url=http://127.0.0.1:4000'
done

ACTIVATION_EPOCH=$(( EIP8321_FORK_EPOCH + COMMITMENT_REGISTRATION_DELAY + 1 ))
wait_for_epoch "$ACTIVATION_EPOCH"

RESULT=failure
for _ in $(seq 1 $(( 2 * SLOTS_PER_EPOCH ))); do
  curl -sf "$BN_URL/eth/v2/beacon/blocks/head" | jq -e '.data.message.body |
    (.hash_chain_reveal // "0x00" | test("[^0x]")) and (.randao_reveal | startswith("0xc0"))' > /dev/null &&
    { RESULT=success; break; }
  sleep 12
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
