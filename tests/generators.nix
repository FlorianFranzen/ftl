# The generators as programs: each writes exactly the files it declares.
{
  pkgs,
  ftl,
  fixture,
  inputs,
  ...
}:
let
  f = ftl.lib.mkFlake {
    src = fixture;
    inherit inputs;
    name = "generators";
    home = {
      bases = {
        terminal = [ "terminal" ];
        desktop = [
          "terminal"
          "desktop"
        ];
      };
      username = "alice";
    };
  };
  programs = f.packages.x86_64-linux;

  check = name: files: ''
    mkdir -p "$TMPDIR/${name}" "$TMPDIR/in/${name}"
    HOST=alpha ${programs."generate-${name}"}/bin/generate-${name} "$TMPDIR/${name}" "$TMPDIR/in/${name}"
    for file in ${toString files}; do
      test -s "$TMPDIR/${name}/$file" || { echo "${name} did not write $file"; exit 1; }
    done
    [ "$(ls "$TMPDIR/${name}" | wc -l)" = ${toString (builtins.length files)} ] || { echo "${name} wrote more than it declares"; ls "$TMPDIR/${name}"; exit 1; }
  '';
in
pkgs.runCommand "generators"
  {
    nativeBuildInputs = [
      pkgs.ssh-to-age
      pkgs.openssl
    ];
  }
  (
    check "host-keys" (builtins.attrNames f.fleet.generators.host-keys.files)
    + check "age-key" (builtins.attrNames f.fleet.generators.age-key.files)
    + check "token" (builtins.attrNames f.fleet.generators.token.files)
    + check "ca" (builtins.attrNames f.fleet.generators.ca.files)
    + ''
      # a generator with inputs reads them under $in/<generator>/<file>
      mkdir -p "$TMPDIR/in/cert/ca" "$TMPDIR/in/cert/host-keys"
      cp "$TMPDIR/ca/ca.pub" "$TMPDIR/ca/ca.key" "$TMPDIR/in/cert/ca/"
      cp "$TMPDIR/host-keys/ssh.pub" "$TMPDIR/in/cert/host-keys/"
    ''
    + check "cert" (builtins.attrNames f.fleet.generators.cert.files)
    + ''
      # the host key is a sops recipient after ssh-to-age
      ssh-to-age < "$TMPDIR/host-keys/ssh.pub" | grep -q '^age1'
      grep -q '^age1' "$TMPDIR/age-key/sops.age"
      # the certificate was signed by the CA and names the host key
      openssl verify -CAfile "$TMPDIR/ca/ca.pub" "$TMPDIR/cert/cert.pub"
      grep -q "^# $(cut -d' ' -f1,2 "$TMPDIR/host-keys/ssh.pub")$" "$TMPDIR/cert/cert.pub"
      touch "$out"
    ''
  )
