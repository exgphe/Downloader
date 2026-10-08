#!/bin/sh
set -eu

DOWNLOADER_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v uv >/dev/null 2>&1; then
    DOWNLOADER_UV=$(command -v uv)
elif [ -x /opt/homebrew/bin/uv ]; then
    DOWNLOADER_UV=/opt/homebrew/bin/uv
elif [ -x /usr/local/bin/uv ]; then
    DOWNLOADER_UV=/usr/local/bin/uv
else
    echo "error: uv is required to package the embedded Python runtime." >&2
    exit 1
fi
export UV_CACHE_DIR="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/DownloaderRuntime}/uv-cache"
exec "$DOWNLOADER_UV" run --offline --no-project --script "$DOWNLOADER_SCRIPT_DIR/package_runtime.py"
