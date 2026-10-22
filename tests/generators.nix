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
        # ftl's own: the fleet's CA, and a host certificate signed by it, for the
      # host's name, as server and as client
      mkdir -p "$TMPDIR/fleet-ca" "$TMPDIR/in/fleet-ca" "$TMPDIR/host-tls" "$TMPDIR/in/host-tls/fleet-ca"
      HOST=fleet ${programs.generate-fleet-ca}/bin/generate-fleet-ca "$TMPDIR/fleet-ca" "$TMPDIR/in/fleet-ca"
      cp "$TMPDIR/fleet-ca/fleet-ca.pub" "$TMPDIR/fleet-ca/fleet-ca.key" "$TMPDIR/in/host-tls/fleet-ca/"
      echo '{ "tls": { "names": [ "alpha.mesh" ], "addresses": [ "10.0.0.1" ] } }' >"$TMPDIR/alpha.json"
      HOST=alpha HOST_JSON="$TMPDIR/alpha.json" ${programs.generate-host-tls}/bin/generate-host-tls "$TMPDIR/host-tls" "$TMPDIR/in/host-tls"
      [ "$(ls "$TMPDIR/host-tls" | sort | tr '\n' ' ')" = "tls.key tls.pub " ] || { echo "host-tls wrote other files"; ls "$TMPDIR/host-tls"; exit 1; }
      openssl verify -CAfile "$TMPDIR/fleet-ca/fleet-ca.pub" -purpose sslserver "$TMPDIR/host-tls/tls.pub"
      openssl verify -CAfile "$TMPDIR/fleet-ca/fleet-ca.pub" -purpose sslclient "$TMPDIR/host-tls/tls.pub"
      openssl x509 -in "$TMPDIR/host-tls/tls.pub" -noout -ext subjectAltName | tee "$TMPDIR/san"
      grep -q 'DNS:alpha, DNS:alpha.mesh, IP Address:10.0.0.1' "$TMPDIR/san"
      openssl x509 -in "$TMPDIR/fleet-ca/fleet-ca.pub" -noout -ext basicConstraints | grep -q 'CA:TRUE'
      [ "$(openssl pkey -in "$TMPDIR/host-tls/tls.key" -pubout)" = "$(openssl x509 -in "$TMPDIR/host-tls/tls.pub" -noout -pubkey)" ]

      # the certificate was signed by the CA and names the host key
        openssl verify -CAfile "$TMPDIR/ca/ca.pub" "$TMPDIR/cert/cert.pub"
        grep -q "^# $(cut -d' ' -f1,2 "$TMPDIR/host-keys/ssh.pub")$" "$TMPDIR/cert/cert.pub"
        touch "$out"
    ''
  )
