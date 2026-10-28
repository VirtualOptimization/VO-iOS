#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-challenge-tests.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
swiftc -swift-version 5 -parse-as-library \
  "$project_dir/RoomPlanExporter/Services/APIConfig.swift" \
  "$project_dir/Tests/Challenge/Support.swift" \
  "$project_dir/RoomPlanExporter/Challenge/ChallengeService.swift" \
  "$project_dir/RoomPlanExporter/Challenge/ChallengeSessionStore.swift" \
  "$project_dir/RoomPlanExporter/Challenge/ChallengeViewModel.swift" \
  "$project_dir/Tests/Challenge/ChallengeFlowTests.swift" \
  -o "$build_dir/challenge-tests"
"$build_dir/challenge-tests"
