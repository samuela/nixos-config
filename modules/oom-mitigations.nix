{ ... }:

{
  # Swap anonymous pages into compressed RAM before falling back to disk swap.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  boot.kernel.sysctl."vm.swappiness" = 100;

  # Let systemd-oomd reap misbehaving user scopes before the machine wedges.
  systemd.oomd.enableUserSlices = true;

  # Persist system and process samples for postmortem memory debugging instead
  # of maintaining a custom snapshot timer.
  programs.atop = {
    enable = true;
    atopacctService.enable = true;
    settings = {
      interval = 30;
      flags = "a";
    };
  };
}
