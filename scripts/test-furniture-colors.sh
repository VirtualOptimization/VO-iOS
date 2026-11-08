#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-furniture-colors.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$project_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'RoomPlanExporter/Services/RoomOptimizerService.swift').read_text()
models = source[source.index('struct RoomVersionDetail:'):source.index('// MARK: - RoomOptimizerService')]
(build / 'Models.swift').write_text('import Foundation\nimport simd\n' + models)
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/module-cache" \
  "$build_dir/Models.swift" "$project_dir/Tests/RoomViewer/FurnitureColorTests.swift" \
  -o "$build_dir/test-colors"
"$build_dir/test-colors"
