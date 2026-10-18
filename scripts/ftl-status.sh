# ftl-status: show the build/promotion state of the environment.
#
# Environment (baked in by the fleet.client module):
#   FTL_STATUS_URL   URL of the builder's status JSON (optional)
#   FTL_REPO_URL     git URL (fallback: list promoted refs)

if [ -n "${FTL_STATUS_URL:-}" ] && out="$(curl -fsS -m 10 "$FTL_STATUS_URL" 2>/dev/null)"; then
  echo "$out" | jq -r '
    "environment: \(.environment)   lane: \(.lane)   run: \(.run)",
    "candidate:   \(.candidate)   promoted: \(.promoted)",
    "",
    (.attrs | to_entries[] |
      "  \(if .value.status == "ok" then "✓" elif .value.status == "skipped" then "-" else "✗" end) \(.key) [\(.value.importance)] \(.value.status)")'
else
  echo "status page unavailable; branches on $FTL_REPO_URL:"
  git ls-remote --heads "${FTL_REPO_URL:?}" |
    awk '{ printf "  %s  %s\n", substr($1, 1, 12), $2 }'
fi
