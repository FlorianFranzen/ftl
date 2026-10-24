# Host metadata (not a module), see the ftl README.
{
  system = "x86_64-linux";
  layers = [ "games" ];

  # Smartcard readers this host may use; registering one turns on pcscd bound
  # to exactly these (mkFlake's `smartcard` registers readers for every host).
  # `headless`: nobody is here to touch the key; it is used through nix-piv's
  # agent (add nix-piv.nixosModules.agent to nixos.sharedModules).
  # smartcard = {
  #   presence = "attended";
  #   readers.yubikey = { vendor = "1050"; product = "0407"; };
  # };
}
