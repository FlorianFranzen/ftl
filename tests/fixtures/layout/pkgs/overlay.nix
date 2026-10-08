final: prev: {
  # override of an existing package
  hello = prev.hello.overrideAttrs (_: {
    ftlOverridden = true;
  });
  # free-form subdirectory, wired by hand
  grouped = final.callPackage ./group/grouped/package.nix { };
}
