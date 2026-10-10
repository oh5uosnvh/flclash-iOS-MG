#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Reproduce the shipped regression with the SAME test and original source.
git show 687bbf0c8264adcaf55f6ff44a7252ef7405f8be:ios/NECore/PacketTunnelSharedStateStore.swift > "$work/Before.swift"
swiftc -swift-version 5 "$work/Before.swift" tool/ios/LaunchPayloadTests.swift -o "$work/before"
if "$work/before" > "$work/before.log" 2>&1; then
  cat "$work/before.log"
  echo 'FAIL: negative control unexpectedly passed' >&2
  exit 1
fi
cat "$work/before.log"
grep -q '^FAIL flat app start options$' "$work/before.log"
echo 'PASS reproduced original flat-payload regression'
# The after-build compiles the real SharedLocation source alongside the
# extension store, mirroring the target linking of libShared.a.
swiftc -swift-version 5 -D PROVIDER_CONFIGURATION_FALLBACK -D PAYLOAD_COMPRESSION \
  ios/Shared/SharedLocation.swift \
  ios/Shared/PayloadCompression.swift \
  ios/NECore/PacketTunnelSharedStateStore.swift \
  tool/ios/LaunchPayloadTests.swift -o "$work/after"
"$work/after"
# Shared container mapping policy: expected group first, single renamed
# authorized group mapped, ambiguous/none refused.
swiftc -swift-version 5 \
  ios/Shared/SharedLocation.swift \
  tool/ios/SharedLocationTests.swift -o "$work/shared_location"
"$work/shared_location"
echo 'PASS shared container mapping regression'
