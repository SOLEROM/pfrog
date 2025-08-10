#!/usr/bin/env bash
set -euo pipefail

show_help() {
cat <<'EOF'
Usage: buildCmp.sh <source_dir> <artifact_file>

Compare mtimes:
  source newer   -> exit 0, "rebuild"
  artifact newer -> exit 2, "update source"
  same           -> exit 1, "up-to-date"

Notes: Uses directory entry mtime only.
EOF
}

# Args / help
if [[ ${1:-} == "--help" || $# -ne 2 ]]; then
  show_help; [[ ${1:-} == "--help" ]] && exit 0 || exit 4
fi

src="$1"; art="$2"

# Validate
[[ -d "$src" ]] || { echo "Error: not a directory: $src" >&2; exit 5; }
[[ -f "$art" ]] || { echo "Error: not a file: $art" >&2; exit 6; }

src_mtime=$(stat -c %Y "$src")
art_mtime=$(stat -c %Y "$art")

if (( src_mtime > art_mtime )); then
  echo "source is newer -> update artifact ; return 1"
  exit 1
elif (( art_mtime > src_mtime )); then
  echo "artifact is newer -> update source ; return 2"
  exit 2
else
  echo "source is up-to-date with artifact ; return 0"
  exit 0
fi
