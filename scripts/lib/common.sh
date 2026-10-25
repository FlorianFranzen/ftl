# Shared by ftl-layers and ftl-pipeline (modules/scripts.nix puts it in front
# of each). Each script defines `log` and sets FTL_NTFY_TITLE.

# notify <message>: to the ntfy topic, if there is one; a failure is logged
notify() {
  [ -n "${FTL_NTFY_URL:-}" ] || return 0
  curl -fsS -m 10 -H "Title: ${FTL_NTFY_TITLE:-ftl}" -d "$1" "$FTL_NTFY_URL" >/dev/null ||
    log "ntfy notification failed"
}

# verify_commit <sha> [<git command>...]: 0 iff the commit is signed by a
# trusted key (FTL_VERIFY_MODE none|ssh|gpg, FTL_ALLOWED_SIGNERS,
# FTL_VERIFY_GPG_HOME). The git command defaults to `git`, e.g. `git -C dir`.
verify_commit() {
  local sha="$1" validity
  shift
  local git=("$@")
  [ "${#git[@]}" -gt 0 ] || git=(git)
  case "$FTL_VERIFY_MODE" in
  none) return 0 ;;
  ssh)
    validity="$("${git[@]}" -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=${FTL_ALLOWED_SIGNERS:?}" \
      log -1 --format='%G?' "$sha")"
    ;;
  gpg)
    # a temporary assignment before a function call (g) reaches git too, in
    # bash's default mode; under `set -o posix` it would persist instead
    validity="$(GNUPGHOME="${FTL_VERIFY_GPG_HOME:?}" "${git[@]}" -c gpg.format=openpgp log -1 --format='%G?' "$sha")"
    ;;
  *)
    log "unknown FTL_VERIFY_MODE '$FTL_VERIFY_MODE'"
    return 1
    ;;
  esac
  # ssh: only G = signed by a listed principal (U = valid but unlisted key).
  # gpg: the keyring holds only trusted keys, U only means "no ownertrust".
  case "$FTL_VERIFY_MODE:$validity" in
  *:G | gpg:U) return 0 ;;
  *)
    log "commit $sha has an invalid or untrusted signature (status=$validity)"
    return 1
    ;;
  esac
}
