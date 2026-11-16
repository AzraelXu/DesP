#!/bin/bash
# Deploy this git checkout to the shared read-only install.
# Usage: ./deploy.sh [destination]
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="${1:-/opt/desmond_md_pipeline}"

if [[ "$(id -u)" -eq 0 ]]; then
    RSYNC=(rsync)
    CHOWN=(chown)
else
    RSYNC=(sudo rsync)
    CHOWN=(sudo chown)
fi

echo "Deploying ${SRC} -> ${DST}"
"${RSYNC[@]}" -a --delete \
    --exclude .git \
    --exclude projects \
    --exclude results \
    --exclude .gpu_locks \
    "${SRC}/" "${DST}/"
"${CHOWN[@]}" -R root:root "${DST}"
echo "Done. Verify with: ${DST}/scripts/check_env.sh"
