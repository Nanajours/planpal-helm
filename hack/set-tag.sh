#!/bin/sh
set -eu

if [ $# -lt 3 ]; then
  echo "usage: $0 <values-file> <tag> <workload> [workload...]" >&2
  exit 2
fi

file=$1; tag=$2; shift 2
names=$(printf '%s,' "$@" | sed 's/,$//')

tmp="$file.tmp"
trap 'rm -f "$tmp"' EXIT INT TERM

awk -v names="$names" -v tag="$tag" '
BEGIN { n = split(names, a, ","); for (i = 1; i <= n; i++) want[a[i]] = 1 }
/^  [A-Za-z0-9_-]+:[ \t]*$/ { cur = $1; sub(/:$/, "", cur); inw = (cur in want) }
inw && /^    tag:[ \t]/ { print "    tag: " tag; hits[cur] = 1; next }
{ print }
END {
  for (k in want) if (!(k in hits)) { print "no tag: line under workload " k > "/dev/stderr"; bad = 1 }
  exit bad ? 1 : 0
}
' "$file" > "$tmp"

mv "$tmp" "$file"
echo "set tag=$tag for: $names"
