#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-furniture-rotation.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$project_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'RoomPlanExporter/Views/Scan/RoomViewerView.swift').read_text()
rotation = source[source.index('enum FurniturePlacementRotation {'):source.index('/// 편집 모드에서 옮긴 가구의 새 위치')]
pose = source[source.index('struct FurniturePoseEdit:'):source.index('/// 3D 뷰 안에서')]
(build / 'Rotation.swift').write_text('import Foundation\nimport simd\n' + rotation + pose)
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/module-cache" \
  "$build_dir/Rotation.swift" "$project_dir/Tests/RoomViewer/FurnitureRotationTests.swift" \
  -o "$build_dir/test-rotation"
"$build_dir/test-rotation"
