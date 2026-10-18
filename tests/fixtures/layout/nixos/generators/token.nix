# A generator of the fixture: a random token, its first bytes public.
{ pkgs }:
{
  description = "a token, half of it public";
  runtimeInputs = [ pkgs.coreutils ];
  files = {
    "token.pub" = { };
    "secret" = {
      secret = true;
    };
  };
  script = ''
    head -c 16 /dev/urandom | base32 | tr -d '=' > "$out/secret"
    cut -c1-8 "$out/secret" > "$out/token.pub"
  '';
}
