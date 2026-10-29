#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-challenge-tests.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$project_dir" "$build_dir" <<'PYMODELS'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'RoomPlanExporter/Services/RoomOptimizerService.swift').read_text()
models = source[source.index('struct RoomVersionDetail:'):source.index('// MARK: - RoomOptimizerService')]
(build / 'RoomLayoutModels.swift').write_text('import Foundation\nimport simd\n' + models)
PYMODELS
swiftc -swift-version 5 -parse-as-library \
  "$build_dir/RoomLayoutModels.swift" \
  "$project_dir/RoomPlanExporter/Services/APIConfig.swift" \
  "$project_dir/Tests/Challenge/Support.swift" \
  "$project_dir/RoomPlanExporter/Challenge/ChallengeService.swift" \
  "$project_dir/RoomPlanExporter/Challenge/ChallengeSessionStore.swift" \
  "$project_dir/RoomPlanExporter/Challenge/ChallengeViewModel.swift" \
  "$project_dir/Tests/Challenge/ChallengeFlowTests.swift" \
  "$project_dir/Tests/Challenge/ChallengeAPITests.swift" \
  -o "$build_dir/challenge-tests"
"$build_dir/challenge-tests"
