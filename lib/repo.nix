# The fleet's repository, as mkFlake's `repo` gives it: a git URL
# (https://…, ssh://…, git@host:path, file://…) or a flake reference
# (github:owner/repo, gitlab:owner/repo, sourcehut:~owner/repo,
# git+https://…?ref=…). Whatever fetches it with git (ftl-layers, ftl-status,
# comin) needs the git URL; `gitUrl` makes one of either.
{ lib }:
let
  split = ref: lib.splitString "?" ref;
  withoutQuery = ref: builtins.head (split ref);
  # ?host=… of a github:/gitlab:/sourcehut: reference (self-hosted forges)
  queryParam =
    name: ref:
    let
      query = lib.concatStringsSep "?" (builtins.tail (split ref));
      pairs = map (lib.splitString "=") (lib.splitString "&" query);
      found = lib.filter (p: builtins.length p == 2 && builtins.head p == name) pairs;
    in
    if found == [ ] then null else builtins.elemAt (builtins.head found) 1;

  # owner/repo of a forge reference, without a ref or query; Nix spells a
  # GitLab subgroup as group%2Fsub
  ownerRepo =
    scheme: ref:
    let
      parts = lib.splitString "/" (withoutQuery (lib.removePrefix "${scheme}:" ref));
    in
    assert lib.assertMsg (
      builtins.length parts >= 2
    ) "ftl: repo '${ref}' is not ${scheme}:<owner>/<repo>[/<ref>]";
    builtins.replaceStrings [ "%2F" "%2f" ] [ "/" "/" ]
      "${builtins.elemAt parts 0}/${builtins.elemAt parts 1}";

  forge =
    scheme: defaultHost: suffix: ref:
    let
      host = queryParam "host" ref;
    in
    "https://${if host != null then host else defaultHost}/${ownerRepo scheme ref}${suffix}";
in
{
  gitUrl =
    repo:
    if repo == null then
      null
    else if lib.hasPrefix "github:" repo then
      forge "github" "github.com" ".git" repo
    else if lib.hasPrefix "gitlab:" repo then
      forge "gitlab" "gitlab.com" ".git" repo
    else if lib.hasPrefix "sourcehut:" repo then
      forge "sourcehut" "git.sr.ht" "" repo
    else if lib.hasPrefix "git+" repo then
      withoutQuery (lib.removePrefix "git+" repo)
    else
      repo;
}
