{ lib, ... }:
{
  perSystem =
    {
      inputs',
      self',
      pkgs,
      ...
    }:
    let
      inherit (lib) optionalAttrs versionAtLeast;
      inherit (pkgs.stdenv.hostPlatform) system isLinux;
    in
    let
      nix = pkgs.nix-eval-jobs.passthru.nix;
      overrideNix = pkg: pkg.override { inherit nix; };
    in
    rec {
      legacyPackages = {
        inputs = {
          nixpkgs = rec {
            inherit (pkgs) nix-eval-jobs;
            # NOTE: Do not override `nix` here — hercules-ci-cnix-store (a
            # transitive dep) is compiled against nixpkgs' default Nix and the
            # C++ ABI breaks when a different version is spliced in.
            cachix = pkgs.haskell.lib.justStaticExecutables pkgs.haskellPackages.cachix;
            inherit nix;
            nixos-rebuild-ng = overrideNix pkgs.nixos-rebuild-ng;
            nix-fast-build = pkgs.nix-fast-build.override { inherit nix-eval-jobs; };
          };
          agenix = inputs'.agenix.packages;
          devenv = inputs'.devenv.packages;
          disko = inputs'.disko.packages // {
            default = overrideNix inputs'.disko.packages.default;
          };
          dlang-nix = inputs'.dlang-nix.packages;
          ethereum-nix = inputs'.ethereum-nix.packages;
          fenix = inputs'.fenix.packages;
          git-hooks-nix = inputs'.git-hooks-nix.packages;
          microvm = inputs'.microvm.packages;
          nix-fast-build = inputs'.nix-fast-build.packages;
          nixos-anywhere = inputs'.nixos-anywhere.packages // {
            default = overrideNix inputs'.nixos-anywhere.packages.default;
          };
          terranix = inputs'.terranix.packages;
          treefmt-nix = inputs'.treefmt-nix.packages;
        };

        rustToolchain =
          with inputs'.fenix.packages;
          with latest;
          combine [
            cargo
            clippy
            rust-analyzer
            rust-src
            rustc
            rustfmt
            targets.wasm32-wasi.latest.rust-std
          ];
      };

      packages = {
        attic-migrate-flake = pkgs.writeShellApplication {
          name = "attic-migrate-flake";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${../scripts/attic-migrate-flake} "$@"
          '';
        };
        cachix-deploy-metrics = pkgs.callPackage ./cachix-deploy-metrics { };
        # Cross-repo sealer for the fleet-alerting receiver secrets (ntfy topic +
        # token, Healthchecks ping URL). Shared by every Metacraft infra repo per
        # policies/alerting-methodology.md. Operates on the consumer repo's flake.
        seal-alerting-secrets = pkgs.writeShellApplication {
          name = "seal-alerting-secrets";
          runtimeInputs = [
            pkgs.age
            pkgs.jq
            pkgs.nix
          ];
          text = ''
            exec bash ${../scripts/seal-alerting-secrets.sh} "$@"
          '';
        };
        # Google Workspace Admin API access through a service account with
        # domain-wide delegation: project, APIs, service account, sealed key and
        # verification in one tool (docs/Google-Workspace-Admin-API-Access.md).
        google-workspace-dwd = pkgs.writeShellApplication {
          name = "google-workspace-dwd";
          runtimeInputs = [
            pkgs.age
            pkgs.coreutils
            pkgs.gawk
            pkgs.gnugrep
            pkgs.google-cloud-sdk
            pkgs.jq
            (pkgs.python3.withPackages (p: [
              p.google-auth
              p.requests
            ]))
          ];
          text = ''
            exec bash ${../scripts/google-workspace-dwd.sh} "$@"
          '';
        };
        # Google Workspace DKIM: validate the key the Admin console generates,
        # publish it through the consumer's Terraform data + PR, wait for DNS
        # (docs/Google-Workspace-DKIM.md). The data side is
        # terraform/cloudflare/mail-auth.nix.
        google-workspace-dkim = pkgs.writeShellApplication {
          name = "google-workspace-dkim";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.dnsutils
            pkgs.gawk
            pkgs.gh
            pkgs.git
            pkgs.gnugrep
            pkgs.gnused
            pkgs.jq
            pkgs.openssl
          ]
          ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.xdg-utils;
          text = ''
            exec ${pkgs.runtimeShell} ${../scripts/google-workspace-dkim.sh} "$@"
          '';
        };
        # The Workspace administration tools as one bundle, for consumer dev
        # shells: `packages = [ inputs'.nixos-modules.packages.workspace-admin-tools ]`
        # puts gcloud and both helpers on PATH, so a consumer's recipes call them
        # directly instead of `nix run`.
        workspace-admin-tools = pkgs.symlinkJoin {
          name = "workspace-admin-tools";
          paths = [
            self'.packages.google-workspace-dwd
            self'.packages.google-workspace-dkim
            pkgs.google-cloud-sdk
          ];
        };
        consumer-flake-cachix-inventory-tool = pkgs.writeShellApplication {
          name = "consumer-flake-cachix-inventory";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${../scripts/consumer-flake-cachix-inventory} "$@"
          '';
        };
        consumer-flake-no-cachix-residual-tool = pkgs.writeShellApplication {
          name = "consumer-flake-no-cachix-residual";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${../scripts/consumer-flake-no-cachix-residual} "$@"
          '';
        };
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation { };
        pyroscope = pkgs.callPackage ./pyroscope { };
        random-alerts = pkgs.callPackage ./random-alerts { };
        mcl-devops = pkgs.callPackage ./mcl-devops {
          dCompiler = inputs'.dlang-nix.packages."ldc-binary-1_38_0";
          inherit (legacyPackages.inputs.nixpkgs) cachix nix nix-eval-jobs;
        };

        # metacraft-cli.md §2.5, supporting rule 1 — "the old package attribute
        # throws rather than resolves."
        #
        # The failing `bin/mcl` stub shipped by `mcl-devops` only catches
        # invocations that go through PATH. Roughly a quarter of the call sites
        # measured for this rename reach the tool by Nix attribute instead
        # (`pkgs.mcl`, `config.packages.mcl`, `#mcl`) and never touch a shell.
        # This attribute is what catches those: it fails at evaluation, with a
        # message, instead of silently resolving to a different program once the
        # name `mcl` is rebound to the end-user client.
        #
        # It is deliberately NOT a `lib.warn` alias and NOT a pointer to
        # `mcl-devops`: an alias that resolves is the forwarding shim §2.5
        # rejects, one level up.
        #
        # REMOVE THIS ATTRIBUTE together with the `bin/mcl` stub, before the new
        # `mcl` client is published.
        mcl = throw (
          "The package attribute `mcl` no longer exists: the Metacraft devops tool "
          + "was renamed to `mcl-devops`. Use `mcl-devops` (binary `bin/mcl-devops`). "
          + "The name `mcl` is being reused by the forthcoming end-user Metacraft CLI, "
          + "so this attribute fails rather than forwarding — see "
          + "metacraft-specs/infrastructure/metacraft-cli.md section 2.5."
        );
      }
      // optionalAttrs (system == "x86_64-linux" || system == "aarch64-darwin") {
        aztec = pkgs.callPackage ./aztec { };
      }
      // optionalAttrs (isLinux || system == "aarch64-darwin") {
        # Ephemeral-Windows-Runners-GARM M0 — the GARM control-plane package
        # (garm daemon + garm-cli), consumed by `services.garm` and its VM gate.
        garm = pkgs.callPackage ./garm { };
        # Ephemeral-Windows-Runners-GARM M1 — the stateless external provider
        # `garm-provider-vmharness` (env+stdin/stdout JSON protocol; shells to
        # virsh/vm-harness). Wired into `services.garm` as an optional provider.
        garm-provider-vmharness = pkgs.callPackage ./garm-provider-vmharness { };
        # Sovereign-CI-Fleet AH3 — `garm-provider-agentharbor`: ephemeral runners
        # as agent-harbor sandbox jobs over ah's REST direct-sandbox-launch API.
        # Same Go module as garm-provider-vmharness (shared JIT templates).
        garm-provider-agentharbor = pkgs.callPackage ./garm-provider-agentharbor { };
        # Runner-Fleet-Capability-Pools-And-Remote-Driving RE3/RE4 — the AWS
        # burst provider `garm-provider-aws` (cloudbase's EC2 external provider)
        # + a Metacraft Labs Apache-2.0 spot/InstanceMarketOptions patch. Wired
        # into `services.garm` as an optional `backend = "aws"` provider; drives
        # the queue-driven burst tier with an always-warm floor.
        garm-provider-aws = pkgs.callPackage ./garm-provider-aws { };
        # Runner-Fleet-Capability-Pools-And-Remote-Driving RA2 — the vm-harness
        # CLI/daemon binary. Its single binary includes `vm-harness serve` (the
        # RA1 remoting daemon), which `services.vm-harness-serve` packages into a
        # hardened systemd unit. Vendored (like garm-provider-vmharness) to keep
        # this repo's flake.lock free of vm-harness's own input tree.
        vm-harness = pkgs.callPackage ./vm-harness { };
      }
      // optionalAttrs isLinux {
        deployment-event-metrics = pkgs.callPackage ./deployment-event-metrics { };
        folder-size-metrics = pkgs.callPackage ./folder-size-metrics { };
        ci-image = pkgs.callPackage ./ci-image {
          inherit (inputs'.nix2container.packages) nix2container;
        };
        yaml-automation-runner = pkgs.callPackage ./vm-automation { };
      };
    };
}
