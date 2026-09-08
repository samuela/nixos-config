{ pkgs, openclaw-pkgs, ... }:

let
  openclawBrowserExecutable = "${pkgs.brave}/bin/brave";
in
{
  # Keep the per-user systemd instance running without an active login session
  # so the OpenClaw user service can start at boot and survive SSH/logout.
  users.users.skainswo.linger = true;

  environment.systemPackages = [ openclaw-pkgs.openclaw ];

  home-manager.users.skainswo =
    { lib, ... }:
    {
      home.activation.configureOpenClawBrowser = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run --silence ${openclaw-pkgs.openclaw}/bin/openclaw config set browser.executablePath ${pkgs.lib.escapeShellArg openclawBrowserExecutable}
      '';
    };
}
