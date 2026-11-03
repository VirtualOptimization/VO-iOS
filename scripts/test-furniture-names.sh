#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-furniture-names.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$project_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
models = (root / 'RoomPlanExporter/Services/RoomOptimizerService.swift').read_text()
models = models[models.index('struct RoomVersionDetail:'):models.index('// MARK: - RoomOptimizerService')]
viewer = (root / 'RoomPlanExporter/Views/Scan/RoomViewerView.swift').read_text()
pose = viewer[viewer.index('struct FurniturePoseEdit:'):viewer.index('/// 3D 뷰 안에서')]
scanner = (root / 'RoomPlanExporter/Views/Furniture/LiDARFurnitureScanView.swift').read_text()
draft = scanner[scanner.index('struct MeasuredFurnitureDraft:'):scanner.index('private struct FurnitureColorChoice:')]
(build / 'Models.swift').write_text('import Foundation\nimport simd\n' + models + pose + draft)
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/module-cache" \
  "$build_dir/Models.swift" "$project_dir/Tests/RoomViewer/FurnitureNameTests.swift" \
  -o "$build_dir/test-names"
"$build_dir/test-names"
