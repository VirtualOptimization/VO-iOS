#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-assistant-advice.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$project_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'RoomPlanExporter/Services/RoomOptimizerService.swift').read_text()
models = source[source.index('struct RoomVersionDetail:'):source.index('// MARK: - RoomOptimizerService')]
viewmodel = (root / 'RoomPlanExporter/ViewModels/AssistantViewModel.swift').read_text()
commands = viewmodel[viewmodel.index('enum FurnitureChatCommand {'):]
(build / 'Models.swift').write_text('import Foundation\nimport simd\n' + models + commands)
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/module-cache" \
  "$build_dir/Models.swift" "$project_dir/RoomPlanExporter/Services/RoomFitCalculator.swift" \
  "$project_dir/Tests/RoomViewer/AssistantAdviceTests.swift" -o "$build_dir/test-advice"
"$build_dir/test-advice"
