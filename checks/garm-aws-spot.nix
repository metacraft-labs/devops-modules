top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving RE4 gate: t_aws_spot_runners.
  #
  # Proves the AWS spot support (the Metacraft Labs Apache-2.0 spot patch to
  # garm-provider-aws) WITHOUT touching real AWS, across three hermetic layers:
  #
  #  (A) MODULE RENDER: a `burstPools.<name>` with a spot policy renders the
  #      pool's `extraSpecs` as a JSON STRING carrying market_type=spot, the
  #      spot request type, the interruption behaviour, on_demand_fallback, and
  #      (when set) spot_max_price — exactly the extra_specs GARM forwards to the
  #      provider. A spot-DISABLED pool renders "{}" (negative control), so the
  #      spot request is opt-in.
  #
  #  (B) EXTRA-SPECS SCHEMA: the provider's generated extra-specs JSON schema
  #      (the contract GARM validates a pool's extra_specs against) advertises
  #      market_type / spot_* / on_demand_fallback, so a spot pool passes
  #      validation and reaches RunInstances (go test in package spec against the
  #      PATCHED source).
  #
  #  (C) PROVIDER BEHAVIOUR (go test, driving the provider's own EC2-client mock,
  #      offline against the vendored AWS SDK):
  #        * a spot spec renders RunInstances with InstanceMarketOptions
  #          (MarketType=spot + SpotOptions);
  #        * on a spot capacity/price failure WITH on_demand_fallback, the SAME
  #          launch retries on-demand (InstanceMarketOptions cleared) and
  #          succeeds; WITHOUT fallback the error propagates;
  #        * graceful interruption: FindInstances excludes terminated /
  #          shutting-down (the states an interrupted spot instance passes
  #          through) so GARM's DB-as-truth reconcile drops the vanished runner
  #          and the job re-queues.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      mkUnit =
        garmCfg:
        (pkgs.nixos (
          { ... }:
          {
            imports = [ flake.modules.nixos.garm ];
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "/dev/vda";
              fsType = "ext4";
            };
            system.stateVersion = "24.11";
            services.garm = garmCfg;
          }
        )).config.systemd.units."garm-reconcile.service".unit;

      spotCfg = {
        enable = true;
        reconcile.enable = true;
        github.app-cloud = {
          appId = 100003;
          installationId = 200003;
          appKeyFile = "/run/agenix/garm/app-cloud-key";
        };
        providers.aws-burst = {
          backend = "aws";
          package = self'.packages.garm-provider-aws;
          aws = {
            region = "eu-central-1";
            subnetId = "subnet-0123456789abcdef0";
            credentialType = "role";
          };
        };
        # Spot-enabled pool.
        burstPools.linux-aws-spot = {
          provider = "aws-burst";
          org = "org-cloud";
          credentials = "app-cloud";
          image = "ami-0123456789abcdef0";
          flavor = "m6i.large";
          maxRunners = 8;
          minIdleRunners = 1;
          priority = 50;
          spot = {
            enable = true;
            maxPrice = "0.05";
            instanceType = "one-time";
            interruptionBehavior = "terminate";
            onDemandFallback = true;
          };
        };
        # On-demand pool (spot disabled) — negative control.
        burstPools.linux-aws-ondemand = {
          provider = "aws-burst";
          org = "org-cloud";
          credentials = "app-cloud";
          image = "ami-0123456789abcdef0";
          flavor = "m6i.large";
          maxRunners = 4;
          priority = 60;
        };
      };

      reconcileUnit = mkUnit spotCfg;
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_aws_spot_runners =
          pkgs.runCommand "t_aws_spot_runners"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.go
                pkgs.coreutils
              ];
              inherit reconcileUnit;
              awsSrc = self'.packages.garm-provider-aws.src;
            }
            ''
              set -euo pipefail
              fail() { echo "[t_aws_spot_runners][FAIL] $1" >&2; exit 1; }

              # ===== (A) MODULE RENDER: spot extra_specs ========================
              exec_start=$(grep '^ExecStart=' "$reconcileUnit/garm-reconcile.service" | head -1 | cut -d= -f2-)
              script=$(echo "$exec_start" | awk '{print $1}')
              [ -f "$script" ] || fail "reconcile ExecStart script not found at $script"
              manifest=$(grep -ohE '/nix/store/[a-z0-9]+-garm-reconcile-manifest\.json' "$script" | head -1)
              [ -f "$manifest" ] || fail "reconcile manifest not found (from $script)"

              # The spot pool's extraSpecs is a JSON STRING; parse it and assert
              # the InstanceMarketOptions request fields.
              es=$(jq -r '.burstPools[] | select(.name=="linux-aws-spot") | .extraSpecs' "$manifest")
              [ -n "$es" ] || fail "spot pool extraSpecs missing"
              echo "$es" | jq -e '.market_type == "spot"' >/dev/null || fail "extraSpecs market_type != spot"
              echo "$es" | jq -e '.spot_instance_type == "one-time"' >/dev/null || fail "extraSpecs spot_instance_type missing"
              echo "$es" | jq -e '.spot_instance_interruption_behavior == "terminate"' >/dev/null || fail "extraSpecs interruption behavior missing"
              echo "$es" | jq -e '.on_demand_fallback == true' >/dev/null || fail "extraSpecs on_demand_fallback missing"
              echo "$es" | jq -e '.spot_max_price == "0.05"' >/dev/null || fail "extraSpecs spot_max_price missing"

              # Negative control: the on-demand pool requests NO market options.
              esod=$(jq -r '.burstPools[] | select(.name=="linux-aws-ondemand") | .extraSpecs' "$manifest")
              [ "$esod" = "{}" ] || fail "on-demand pool must render empty extraSpecs (got: $esod)"

              echo "[t_aws_spot_runners] module render OK (spot extra_specs + on-demand negative control)"

              # ===== (B)+(C) go test against the PATCHED source (offline) =======
              export HOME="$PWD/home"; mkdir -p "$HOME"
              export GOCACHE="$PWD/gocache"; mkdir -p "$GOCACHE"
              export GOPATH="$PWD/gopath"; mkdir -p "$GOPATH"
              export GOFLAGS=-mod=vendor
              export GOTOOLCHAIN=local
              export CGO_ENABLED=0
              cp -r "$awsSrc" gpa && chmod -R u+w gpa
              cd gpa

              # (B) the extra-specs schema advertises the spot fields.
              go test ./internal/spec/ -run 'TestExtraSpecsSchemaAdvertisesSpot' -v 2>&1 | tee "$OLDPWD/schema.log" || fail "schema go test failed"
              grep -q 'PASS: TestExtraSpecsSchemaAdvertisesSpot' "$OLDPWD/schema.log" || fail "extra-specs schema does not advertise spot"

              # (C) RunInstances InstanceMarketOptions + fallback + interruption.
              go test ./internal/client/ \
                -run 'TestCreateRunningInstanceSpotMarketOptions|TestCreateRunningInstanceSpotOnDemandFallback|TestCreateRunningInstanceSpotNoFallbackPropagates|TestFindInstancesExcludesInterruptedSpot' \
                -v 2>&1 | tee "$OLDPWD/client.log" || fail "spot provider go test failed"
              for tc in \
                TestCreateRunningInstanceSpotMarketOptions \
                TestCreateRunningInstanceSpotOnDemandFallback \
                TestCreateRunningInstanceSpotNoFallbackPropagates \
                TestFindInstancesExcludesInterruptedSpot; do
                grep -q "PASS: $tc" "$OLDPWD/client.log" || fail "spot behaviour not proven: $tc"
              done
              cd "$OLDPWD"

              echo "[t_aws_spot_runners][PASS] spot InstanceMarketOptions render, schema, on-demand fallback, and interruption reconcile all verified"
              touch "$out"
            '';
      };
    };
}
