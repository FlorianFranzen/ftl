{
  system = "aarch64-linux";
  importance = "optional";
  layers = [ "tools" ];

  # a build host nobody sits at: its key works without touch
  smartcard = {
    presence = "headless";
    readers.builder = {
      vendor = "1050";
      product = "0407";
      port = "1-4";
    };
  };
}
