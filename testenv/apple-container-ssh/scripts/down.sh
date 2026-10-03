#!/usr/bin/env bash
# Stop and remove Apple-container Queue SSH children (leave buildkit alone).
set -euo pipefail

if ! command -v container >/dev/null 2>&1; then
  echo "container CLI not found (Apple container)" >&2
  exit 1
fi

for name in child-1 child-2 \
            distsshqueue-child-1 distsshqueue-child-2 distsshqueue-worker-1 distsshqueue-worker-2 \
            dskq-child-1 dskq-child-2 dskq-worker-1 dskq-worker-2; do
  container stop "${name}" >/dev/null 2>&1 || true
  container rm "${name}" >/dev/null 2>&1 || true
done
echo "Removed child-1 and child-2 (and leftover distsshqueue-* / dskq-* names, if they existed)"
