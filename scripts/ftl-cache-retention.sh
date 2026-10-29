# ftl-cache-retention: prune a file:// binary cache down to the closures of
# the last N promoted generations per attribute.
#
# Usage: ftl-cache-retention <cacheDir> <promoted.jsonl> <keepGenerations>
#
# The JSONL file is appended by ftl-pipeline on every promotion with lines
# like {"attr":"nixos-alpha","rev":"...","date":"...","outPath":"/nix/store/..."}.
# Everything reachable (via narinfo References) from the kept generations
# stays; every other .narinfo and nar file is deleted. The JSONL itself is
# trimmed to the kept lines.

cache="$1"
jsonl="$2"
keep="$3"

[ -d "$cache" ] || {
  echo "ftl-cache-retention: no cache dir '$cache'" >&2
  exit 0
}
[ -s "$jsonl" ] || {
  echo "ftl-cache-retention: no promotion manifest '$jsonl'" >&2
  exit 0
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Last N lines per attr (newest last in the file).
tac "$jsonl" | jq -c . | awk -v n="$keep" '
  { line=$0; attr=""; if (match(line, /"attr":"[^"]*"/)) attr=substr(line, RSTART+8, RLENGTH-9) }
  attr != "" && count[attr]++ < n { print line }
' >"$tmp/keep.jsonl"
tac "$tmp/keep.jsonl" >"$tmp/trimmed.jsonl"

jq -r '.outPath // empty' "$tmp/keep.jsonl" | sort -u >"$tmp/roots"

# BFS over narinfo References to collect the kept closure (by hash part).
: >"$tmp/seen"
sed 's|^/nix/store/||; s|-.*||' "$tmp/roots" >"$tmp/queue"
while [ -s "$tmp/queue" ]; do
  : >"$tmp/next"
  while read -r h; do
    grep -qxF "$h" "$tmp/seen" && continue
    echo "$h" >>"$tmp/seen"
    ni="$cache/$h.narinfo"
    [ -f "$ni" ] || continue
    # "References: <basename> <basename> ..."
    sed -n 's/^References: *//p' "$ni" | tr ' ' '\n' | sed '/^$/d; s/-.*//' >>"$tmp/next"
  done <"$tmp/queue"
  sort -u "$tmp/next" >"$tmp/queue"
done
sort -u "$tmp/seen" >"$tmp/kept-hashes"

# nar files referenced by kept narinfos
: >"$tmp/kept-nars"
while read -r h; do
  ni="$cache/$h.narinfo"
  [ -f "$ni" ] && sed -n 's/^URL: *//p' "$ni" >>"$tmp/kept-nars"
done <"$tmp/kept-hashes"
sort -u -o "$tmp/kept-nars" "$tmp/kept-nars"

removed_info=0 removed_nar=0
for ni in "$cache"/*.narinfo; do
  [ -e "$ni" ] || break
  h="$(basename "$ni" .narinfo)"
  if ! grep -qxF "$h" "$tmp/kept-hashes"; then
    rm -f "$ni"
    removed_info=$((removed_info + 1))
  fi
done

if [ -d "$cache/nar" ]; then
  while IFS= read -r f; do
    rel="nar/$(basename "$f")"
    if ! grep -qxF "$rel" "$tmp/kept-nars"; then
      rm -f "$f"
      removed_nar=$((removed_nar + 1))
    fi
  done < <(find "$cache/nar" -type f)
fi

cp "$tmp/trimmed.jsonl" "$jsonl"
echo "ftl-cache-retention: kept $(wc -l <"$tmp/kept-hashes") paths, removed $removed_info narinfos / $removed_nar nars" >&2
