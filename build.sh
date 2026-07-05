#!/bin/sh
set -e

# Read metadata from Makefile
MAKEFILE="theme-blue/Makefile"
if [ ! -f "$MAKEFILE" ]; then
    echo "Error: $MAKEFILE not found." >&2
    exit 1
fi

PLUGIN_NAME=$(grep '^PLUGIN_NAME=' "$MAKEFILE" | awk -F'=' '{print $2}' | tr -d '[[:space:]]')
PLUGIN_VERSION=$(grep '^PLUGIN_VERSION=' "$MAKEFILE" | awk -F'=' '{print $2}' | tr -d '[[:space:]]')
PLUGIN_COMMENT=$(grep '^PLUGIN_COMMENT=' "$MAKEFILE" | awk -F'=' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
PLUGIN_MAINTAINER=$(grep '^PLUGIN_MAINTAINER=' "$MAKEFILE" | awk -F'=' '{print $2}' | tr -d '[[:space:]]')

if [ -z "$PLUGIN_NAME" ] || [ -z "$PLUGIN_VERSION" ]; then
    echo "Error: Could not parse PLUGIN_NAME or PLUGIN_VERSION from $MAKEFILE." >&2
    exit 1
fi

PKG_NAME="os-${PLUGIN_NAME}-devel"
PKG_FILENAME="${PKG_NAME}-${PLUGIN_VERSION}.txz"

echo "Building package: $PKG_NAME version $PLUGIN_VERSION"

# Staging area setup
STAGE_DIR="build_stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# Stage all files from theme-blue/src
SRC_DIR="theme-blue/src"
if [ -d "$SRC_DIR" ]; then
    cp -r "$SRC_DIR"/* "$STAGE_DIR"/
fi

# Rename staging files path to usr/local
mkdir -p "$STAGE_DIR/usr/local"
mv "$STAGE_DIR/opnsense" "$STAGE_DIR/usr/local/"

# Prepare Manifest files
MANIFEST_PATH="$STAGE_DIR/+MANIFEST"
COMPACT_MANIFEST_PATH="$STAGE_DIR/+COMPACT_MANIFEST"

# Helper function to get SHA256 in a portable way
get_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$1"
    else
        echo "Error: no sha256 or sha256sum command found" >&2
        exit 1
    fi
}

# Helper function to get file size in bytes in a portable way
get_size() {
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1"
}

# Find all files inside the stage directory, relative to staging root.
# Calculate flatsize and list of files.
(
    cd "$STAGE_DIR"
    find usr -type f
) | while read -r file_path; do
    abs_path="/$file_path"
    file_size=$(get_size "$STAGE_DIR/$file_path")
    file_hash=$(get_sha256 "$STAGE_DIR/$file_path")
    echo "$abs_path:$file_size:$file_hash" >> "$STAGE_DIR/file_list.tmp"
done

# Read file list and construct manifest values
FLAT_SIZE=0
FILES_JSON=""
if [ -f "$STAGE_DIR/file_list.tmp" ]; then
    while IFS=":" read -r abs_path file_size file_hash; do
        FLAT_SIZE=$((FLAT_SIZE + file_size))
        if [ -n "$FILES_JSON" ]; then
            FILES_JSON+=","
        fi
        FILES_JSON+="\"$abs_path\":\"1\$$file_hash\""
    done < "$STAGE_DIR/file_list.tmp"
fi

python3 - "$COMPACT_MANIFEST_PATH" "$MANIFEST_PATH" "$FLAT_SIZE" "$PKG_NAME" "$PLUGIN_VERSION" "$PLUGIN_COMMENT" "$PLUGIN_MAINTAINER" "$FILES_JSON" <<'PY'
import json
import sys
from pathlib import Path

compact_manifest_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
flatsize = int(sys.argv[3])
pkg_name = sys.argv[4]
pkg_version = sys.argv[5]
pkg_comment = sys.argv[6]
pkg_maintainer = sys.argv[7]
files_json = sys.argv[8]

compact_manifest = {
    "name": pkg_name,
    "origin": f"opnsense/{pkg_name}",
    "version": pkg_version,
    "comment": pkg_comment,
    "maintainer": pkg_maintainer,
    "www": "https://github.com/trifoil/opnsense-blue-theme",
    "abi": "FreeBSD:*:*",
    "arch": "freebsd:*:*",
    "prefix": "/usr/local",
    "flatsize": flatsize,
    "licenselogic": "single",
    "licenses": ["MIT"],
    "desc": "",
    "categories": ["misc"],
    "annotations": {"FreeBSD_version": "1400000"},
}

files = {}
if files_json:
    for item in files_json.split(','):
        if ':' not in item:
            continue
        key, value = item.split(':', 1)
        key = key[1:-1]
        value = value[1:-1]
        files[key] = value

with compact_manifest_path.open("w", encoding="utf-8") as fh:
    json.dump(compact_manifest, fh, separators=(",", ":"))

manifest = dict(compact_manifest)
manifest["files"] = files
with manifest_path.open("w", encoding="utf-8") as fh:
    json.dump(manifest, fh, separators=(",", ":"))
PY

rm -f "$STAGE_DIR/file_list.tmp"

# Build package using tar.
# To be valid:
# 1. +COMPACT_MANIFEST and +MANIFEST must be the first files in the archive.
# 2. File owner/group must be root/wheel (0/0).
# 3. File paths inside tar must start with leading slash.
# Create a list of files (manifests first) and archive only files (no directory entries)
TAR_LIST="$STAGE_DIR/tar_list.txt"
rm -f "$TAR_LIST"
printf "+COMPACT_MANIFEST\n+MANIFEST\n" > "$TAR_LIST"
# Append all regular files under usr/ (relative paths)
(cd "$STAGE_DIR" && find usr -type f | sed 's#^#./#') >> "$TAR_LIST"

# Use tar with listfile to ensure manifests are first and only files are archived.
# Use --transform to add the leading / for the usr tree and set owner/group to root:wheel.
tar -cvJf "$PKG_FILENAME" -C "$STAGE_DIR" --owner=root:0 --group=wheel:0 --transform 's|^\./usr|/usr|' -P -T "$TAR_LIST"

rm -f "$TAR_LIST"

# Clean up
rm -rf "$STAGE_DIR"

echo "Package created successfully: $PKG_FILENAME"
