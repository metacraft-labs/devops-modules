top@{ ... }:
{
  # gate: t_vmharness_serve_inventory_textfile
  #
  # Pure-EVAL proof that the vm-harness-serve inventory exporter publishes where
  # node-exporter actually reads, without loosening that directory.
  #
  #   * `inventoryExporter.textfileDir` defaults to the fleet's ONE textfile
  #     dir, `/var/lib/prometheus-node-exporter/textfile` — the path infra's
  #     services/monitoring/node-exporter-textfile.nix passes as
  #     `--collector.textfile.directory`. The default used to be
  #     `/var/lib/node-exporter/textfile`: written every cycle, never scraped,
  #     so every orphan alert fed by it was silent.
  #   * that dir is declared `root:root 0755` (identical to infra's rule), not
  #     the world-writable 0777 the exporter used to create;
  #   * the serve-user half renders into its own 0750 state dir and only the
  #     `+` (privileged) ExecStartPost writes into the shared dir, so the
  #     unprivileged unit needs no write access there at all.
  #
  # Mirrors the pinned constant rather than importing infra (a private repo
  # this flake does not depend on); a change on either side must update both.
  perSystem =
    { pkgs, lib, ... }:
    let
      flake = top.config.flake;
      infraTextfileDir = "/var/lib/prometheus-node-exporter/textfile";

      eval = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.nixos.vm-harness-serve
          (
            { ... }:
            {
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              system.stateVersion = "24.05";
              services.vm-harness-serve = {
                enable = true;
                listenAddress = "10.10.10.1";
                backend = "incus";
                overlayInterface = null;
                authTokenFile = "/run/vmh-secrets/token";
                inventoryExporter = {
                  enable = true;
                  backends = [ "incus" ];
                };
              };
            }
          )
        ];
      };
      cfg = eval.config;
      icfg = cfg.services.vm-harness-serve.inventoryExporter;
      sc = cfg.systemd.services.vm-harness-serve-inventory.serviceConfig;
      str = v: builtins.unsafeDiscardStringContext (toString v);
      postExec = str (sc.ExecStartPost or "");
      rwPaths = map str (lib.toList (sc.ReadWritePaths or [ ]));

      checks = [
        {
          ok = icfg.textfileDir == infraTextfileDir;
          msg = "inventoryExporter.textfileDir defaults to ${icfg.textfileDir}, not node-exporter's ${infraTextfileDir}";
        }
        {
          ok = lib.elem "d ${infraTextfileDir} 0755 root root -" cfg.systemd.tmpfiles.rules;
          msg = "the textfile dir is not declared root:root 0755";
        }
        {
          ok = !(lib.any (r: lib.hasInfix infraTextfileDir r && lib.hasInfix "0777" r) cfg.systemd.tmpfiles.rules);
          msg = "the textfile dir is created world-writable";
        }
        {
          ok = lib.hasPrefix "+" postExec && lib.hasInfix "vm-harness-serve-inventory-publish" postExec;
          msg = "the snapshot is not published by a privileged ExecStartPost (got '${postExec}')";
        }
        {
          ok = (sc.StateDirectoryMode or "") == "0750" && (sc.StateDirectory or "") == "vm-harness-serve-inventory";
          msg = "the serve-user staging dir is not a private 0750 StateDirectory";
        }
        {
          ok = !(lib.elem infraTextfileDir rwPaths);
          msg = "the unprivileged unit still gets write access to the shared textfile dir";
        }
      ];
      failures = map (c: c.msg) (lib.filter (c: !c.ok) checks);
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_vmharness_serve_inventory_textfile =
          assert lib.assertMsg (failures == [ ]) (
            "t_vmharness_serve_inventory_textfile:\n  " + lib.concatStringsSep "\n  " failures
          );
          pkgs.runCommand "t_vmharness_serve_inventory_textfile" { } ''
            echo "GATE PASS: inventory exporter publishes into ${infraTextfileDir} (root:root 0755)" >"$out"
          '';
      };
    };
}
