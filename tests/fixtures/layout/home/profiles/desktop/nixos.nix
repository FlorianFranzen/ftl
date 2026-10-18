# The NixOS side of the desktop profile: imported into a host that gives a
# user a desktop configuration, never into the home itself.
{
  environment.etc."desktop-companion".text = "from home/profiles/desktop";
}
