#!/usr/bin/env bash
set -euo pipefail

# Stream-extract RAPIDS/cuVS wiki-all. The archive is split into 10 tar parts.
# Storing both the split tarballs and extracted fp32 files exceeds the free
# space on many artifact machines, so this script uses curl | tar.

OUT_DIR="${1:-/path/to/wiki_all_88M}"
URL_PREFIX="https://data.rapids.ai/raft/datasets/wiki_all/wiki_all.tar"

mkdir -p "${OUT_DIR}"

echo "Downloading and extracting RAPIDS wiki-all to ${OUT_DIR}"
echo "This is a ~251GB fp32 embedding dataset and may take several hours."
echo "Source: RAPIDS/cuVS wiki-all dataset archive at ${URL_PREFIX}.{00..9}"

curl -L --fail --retry 5 --retry-delay 10 --connect-timeout 30 \
  "${URL_PREFIX}".{00..9} | tar -xf - -C "${OUT_DIR}"

echo "Done. Extracted files:"
find "${OUT_DIR}" -maxdepth 2 -type f -printf "%p\t%k KB\n" | sort
