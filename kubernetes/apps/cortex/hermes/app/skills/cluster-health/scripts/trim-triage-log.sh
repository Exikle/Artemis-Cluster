#!/usr/bin/env bash
# Retention for an append-only triage log in /opt/data/workspace/cluster-health/.
# Usage: trim-triage-log.sh <triage.md> <keep-N> <archive-dir>
# Keeps the header (everything before the first "- 20..." entry) plus the newest N entries in
# <triage.md>; every older entry goes to <archive-dir>/<name>.archive.md (appended).
# A "- 20..." line starts an entry; following non-entry lines belong to it. Writes <triage.md>.new
# and <archive-dir> only; review, then mv <triage.md>.new <triage.md>.
set -euo pipefail
F="${1:?usage: trim-triage-log.sh <triage.md> <keep-N> <archive-dir>}"
N="${2:?keep-N}"
OUT="${3:?archive-dir}"
mkdir -p "$OUT"
NAME="$(basename "$F" .md)"
TOTAL=$(grep -c -E '^- (\*\*)?20[0-9]{2}-' "$F" || true)
DROP=$(( TOTAL > N ? TOTAL - N : 0 ))
awk -v drop="$DROP" -v arch="$OUT/$NAME.archive.md" '
  /^- (\*\*)?20[0-9][0-9]-/ { seen++ }
  seen == 0            { print; next }
  seen <= drop         { print >> arch; next }
                       { print }
' "$F" > "$F.new"
echo "entries: $TOTAL, kept: $(( TOTAL - DROP )), archived: $DROP"
echo "new file: $F.new ($(wc -c < "$F.new") bytes); archive: $OUT/$NAME.archive.md"
