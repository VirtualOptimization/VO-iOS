#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-room-collisions.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$project_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'RoomPlanExporter/Views/Scan/RoomViewerView.swift').read_text()
policy = source[source.index('struct FurnitureCollisionPolicy {'):source.index('// MARK: - General V-O asset reuse')]
(build / 'CollisionPolicy.swift').write_text('import Foundation\n' + policy)
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/module-cache" \
  "$build_dir/CollisionPolicy.swift" "$project_dir/Tests/RoomViewer/CollisionPolicyTests.swift" \
  -o "$build_dir/test-collisions"
"$build_dir/test-collisions"
