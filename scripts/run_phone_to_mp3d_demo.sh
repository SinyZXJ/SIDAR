#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/outputs/demo}"

python3 -m phone_scene_to_isaac.cli make-demo-render "${OUT}/renders"
python3 -m phone_scene_to_isaac.cli render-to-bag "${OUT}/renders" "${OUT}/rosbag2"

echo "Demo MP3D-compatible bag: ${OUT}/rosbag2"
