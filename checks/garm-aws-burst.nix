top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving RE3 gate: t_aws_burst_runners.
  #
  # Proves the AWS BURST tier — an `aws`-backed `services.garm` provider + a
  # burst POOL — is expressed with a queue-driven spill, an always-warm floor,
  # one-job ephemeral auto-terminate, and scale-back, WITHOUT touching real AWS.
  # Two hermetic layers:
  #
  #  (A) MODULE RENDER (eval/build, no VM): build the module-produced
  #      `garm.service` + `garm-reconcile.service` units for a burst shape and
  #      assert on the rendered artifacts:
  #        * the `garm-provider-aws` provider config.toml carries region +
  #          subnet_id + credential_type and NO secret (role chain);
  #        * the reconcile manifest's burst pool carries the ceiling
  #          (maxRunners), the spill priority, the anti-overprovision backoff
  #          (jobAgeBackoff), one-job `ephemeral`, and — the floor-vs-pure-lazy
  #          knob — an effective warm floor of N under floorPolicy=floor and 0
  #          under floorPolicy=lazy.
  #
  #  (B) PROVIDER BEHAVIOUR (go test against the PATCHED source, offline against
  #      the vendored AWS SDK, driving the provider's own EC2-client mock — the
  #      seam upstream tests use): a Create launches EXACTLY ONE instance
  #      (MaxCount==MinCount==1, the ephemeral one-job invariant that keeps a
  #      burst from over-provisioning per queued job), and FindInstances EXCLUDES
  #      terminated/shutting-down instances so GARM's DB-as-truth reconcile scales
  #      the pool back to the floor as runners finish/vanish.
  #
  # Spot (InstanceMarketOptions) is RE4's gate (t_aws_spot_runners); this gate
  # ships the on-demand burst.
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
        name: garmCfg:
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
        )).config.systemd.units."${name}".unit;

      # A burst shape: one aws provider + a warm-floor pool + a pure-lazy pool.
      burstCfg = {
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
          # A cloud guest cannot reach a controller URL on a private network.
          guestMetadataURL = "https://garm.example.com/api/v1/metadata";
          guestCallbackURL = "https://garm.example.com/api/v1/callbacks";
        };
        burstPools.linux-aws = {
          provider = "aws-burst";
          org = "org-cloud";
          credentials = "app-cloud";
          image = "ami-0123456789abcdef0";
          flavor = "m6i.large";
          osType = "linux";
          labels = [
            "self-hosted"
            "linux"
            "x64"
            "aws"
            "x86-64-v3"
          ];
          maxRunners = 8;
          minIdleRunners = 2;
          floorPolicy = "floor";
          priority = 50;
          jobAgeBackoff = 45;
          # The in-guest TTL backstop + infra-supplied provider extra-specs.
          ttlMinutes = 360;
          extraSpecs = {
            security_group_ids = [ "sg-0123456789abcdef0" ];
            iam_instance_profile = "arn:aws:iam::123456789012:instance-profile/runners";
            volume_size = 50;
          };
        };
        # Same pool tuning but pure-lazy: the effective floor must collapse to 0.
        burstPools.linux-aws-lazy = {
          provider = "aws-burst";
          org = "org-cloud";
          credentials = "app-cloud";
          image = "ami-0123456789abcdef0";
          flavor = "m6i.large";
          osType = "linux";
          minIdleRunners = 2;
          floorPolicy = "lazy";
          maxRunners = 8;
          priority = 50;
        };
      };

      garmUnit = mkUnit "garm.service" burstCfg;
      reconcileUnit = mkUnit "garm-reconcile.service" burstCfg;
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_aws_burst_runners =
          pkgs.runCommand "t_aws_burst_runners"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.go
                pkgs.coreutils
              ];
              inherit garmUnit reconcileUnit;
              awsSrc = self'.packages.garm-provider-aws.src;
              awsBin = lib.getExe self'.packages.garm-provider-aws;
            }
            ''
              set -euo pipefail
              fail() { echo "[t_aws_burst_runners][FAIL] $1" >&2; exit 1; }

              # ===== (A) MODULE RENDER ==========================================
              garm="$garmUnit/garm.service"

              # -- the AWS provider config.toml: region + subnet + role creds ----
              pre=$(grep '^ExecStartPre=' "$garm" | head -1 | cut -d= -f2-)
              [ -f "$pre" ] || fail "render script not found at $pre"
              tmpl=$(grep -ohE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' "$pre" | head -1)
              [ -f "$tmpl" ] || fail "config template not found (from $pre)"
              grep -q 'name = "aws-burst"' "$tmpl" || fail "[[provider]] 'aws-burst' missing"
              grep -q 'provider_executable = .*garm-provider-aws' "$tmpl" || fail "aws provider_executable not the garm-provider-aws binary"
              awscfg=$(grep -ohE '/nix/store/[a-z0-9]+-garm-provider-aws_burst\.toml' "$tmpl" | head -1)
              [ -f "$awscfg" ] || fail "aws provider config not found"
              grep -qx 'region = "eu-central-1"' "$awscfg" || fail "aws region not rendered"
              grep -qx 'subnet_id = "subnet-0123456789abcdef0"' "$awscfg" || fail "aws subnet_id not rendered"
              grep -qx 'credential_type = "role"' "$awscfg" || fail "aws credential_type not rendered"
              # No secret ever in the store config.
              ! grep -qi 'access_key\|secret' "$awscfg" || fail "aws provider config leaked a credential into the store"
              grep -qx 'guest_metadata_url = "https://garm.example.com/api/v1/metadata"' "$awscfg" || fail "aws guest_metadata_url not rendered"
              grep -qx 'guest_callback_url = "https://garm.example.com/api/v1/callbacks"' "$awscfg" || fail "aws guest_callback_url not rendered"

              # -- the provider ABI: garm-provider-aws implements ONLY v0.1.0 ----
              # Rendering v0.1.1 for it (the module's hard-coded value until
              # 2026-10-05) made every create AND delete fail at the provider's
              # dispatch on the live central GARM. Assert the rendered value.
              awsblock=$(awk '/^\[\[provider\]\]/{inb=0} /^name = "aws-burst"/{inb=1} inb' "$tmpl")
              ifver=$(echo "$awsblock" | sed -n 's/^ *interface_version = "\(.*\)"$/\1/p' | head -1)
              [ "$ifver" = "v0.1.0" ] || fail "aws provider must render interface_version v0.1.0 (got '$ifver')"

              # -- the reconcile manifest: floor / max / priority / backoff ------
              rpre=$(grep -ohE '/nix/store/[^ ]*garm-reconcile[^ ]*' "$reconcileUnit/garm-reconcile.service" | head -1)
              exec_start=$(grep '^ExecStart=' "$reconcileUnit/garm-reconcile.service" | head -1 | cut -d= -f2-)
              script=$(echo "$exec_start" | awk '{print $1}')
              [ -f "$script" ] || fail "reconcile ExecStart script not found at $script"
              manifest=$(grep -ohE '/nix/store/[a-z0-9]+-garm-reconcile-manifest\.json' "$script" | head -1)
              [ -f "$manifest" ] || fail "reconcile manifest not found (from $script)"
              echo "manifest = $manifest"

              # floorPolicy=floor pool: warm floor honoured (min-idle = 2)
              jq -e '.burstPools[] | select(.name=="linux-aws")' "$manifest" >/dev/null || fail "burst pool 'linux-aws' missing from manifest"
              jq -e '.burstPools[] | select(.name=="linux-aws") | .minIdleRunners == 2' "$manifest" >/dev/null || fail "warm floor (min-idle=2) not honoured under floorPolicy=floor"
              jq -e '.burstPools[] | select(.name=="linux-aws") | .maxRunners == 8' "$manifest" >/dev/null || fail "ceiling (max-runners=8) missing"
              jq -e '.burstPools[] | select(.name=="linux-aws") | .priority == 50' "$manifest" >/dev/null || fail "spill priority missing"
              jq -e '.burstPools[] | select(.name=="linux-aws") | .jobAgeBackoff == 45' "$manifest" >/dev/null || fail "anti-overprovision backoff missing"
              jq -e '.burstPools[] | select(.name=="linux-aws") | .ephemeral == true' "$manifest" >/dev/null || fail "one-job ephemeral not set"
              jq -e '.burstPools[] | select(.name=="linux-aws") | .provider == "aws-burst"' "$manifest" >/dev/null || fail "pool not bound to the aws provider"

              # floorPolicy=lazy pool: the effective floor collapses to 0.
              jq -e '.burstPools[] | select(.name=="linux-aws-lazy") | .minIdleRunners == 0' "$manifest" >/dev/null || fail "floorPolicy=lazy must force effective min-idle to 0 (pure scale-to-zero)"
              jq -e '.burstPools[] | select(.name=="linux-aws-lazy") | .floorPolicy == "lazy"' "$manifest" >/dev/null || fail "floorPolicy=lazy not recorded"

              # The org referenced by the burst pools is created against its cred.
              jq -e '.orgs[] | select(.name=="org-cloud" and .credentials=="app-cloud")' "$manifest" >/dev/null || fail "burst-pool org not derived into desiredOrgs"

              # TTL backstop + extra-specs passthrough: the extraSpecs JSON string
              # carries the infra keys AND a base64 pre-install script that
              # decodes byte-for-byte to the TTL arm.
              specs=$(jq -r '.burstPools[] | select(.name=="linux-aws") | .extraSpecs' "$manifest")
              echo "$specs" | jq -e '.security_group_ids == ["sg-0123456789abcdef0"]' >/dev/null || fail "extraSpecs security_group_ids not passed through"
              echo "$specs" | jq -e '.iam_instance_profile == "arn:aws:iam::123456789012:instance-profile/runners"' >/dev/null || fail "extraSpecs iam_instance_profile not passed through"
              echo "$specs" | jq -e '.volume_size == 50' >/dev/null || fail "extraSpecs volume_size not passed through"
              echo "$specs" | jq -r '.pre_install_scripts["00-garm-burst-ttl"]' | base64 -d > ttl.sh || fail "TTL pre-install script is not valid base64"
              printf '%s\n' '#!/bin/sh' \
                '# garm burst-pool TTL backstop (devops-modules services.garm.burstPools.<n>.ttlMinutes)' \
                'shutdown -P +360 "garm burst TTL reached" || systemd-run --on-active=360m /bin/systemctl poweroff' \
                'exit 0' > ttl.expected
              cmp ttl.sh ttl.expected || fail "decoded TTL script differs from the expected script"
              # TTL off by default: the lazy pool carries no pre-install script.
              jq -r '.burstPools[] | select(.name=="linux-aws-lazy") | .extraSpecs' "$manifest" \
                | jq -e 'has("pre_install_scripts") | not' >/dev/null || fail "ttlMinutes=0 must render no TTL script"

              echo "[t_aws_burst_runners] module render OK (floor honoured, lazy collapses to 0, spill priority + backoff + ephemeral + role creds)"

              # ===== (B) PROVIDER BEHAVIOUR (go test, offline) ==================
              export HOME="$PWD/home"; mkdir -p "$HOME"
              export GOCACHE="$PWD/gocache"; mkdir -p "$GOCACHE"
              export GOPATH="$PWD/gopath"; mkdir -p "$GOPATH"
              export GOFLAGS=-mod=vendor
              export GOTOOLCHAIN=local
              export CGO_ENABLED=0
              cp -r "$awsSrc" gpa && chmod -R u+w gpa
              cd gpa
              # On-demand one-job create + scale-back state filter (interrupted /
              # finished instances excluded from the live set).
              go test ./internal/client/ \
                -run 'TestCreateRunningInstanceOnDemandNoMarketOptions|TestFindInstancesExcludesInterruptedSpot' \
                -v 2>&1 | tee "$OLDPWD/gotest.log" || fail "burst provider go test failed"
              grep -q '^ok' "$OLDPWD/gotest.log" || fail "burst provider go test did not report ok"
              grep -q 'PASS: TestCreateRunningInstanceOnDemandNoMarketOptions' "$OLDPWD/gotest.log" || fail "one-job on-demand create not proven"
              grep -q 'PASS: TestFindInstancesExcludesInterruptedSpot' "$OLDPWD/gotest.log" || fail "scale-back state filter not proven"
              # The guest URL override reaches the userdata the instance boots
              # with (no controller-private URL left in it).
              go test ./config/ ./internal/spec/ -run 'TestApplyGuestURLOverrides|TestGuestURLOverrideReachesUserdata' \
                -v 2>&1 | tee "$OLDPWD/gotest-guest.log" || fail "guest URL override go test failed"
              grep -q 'PASS: TestGuestURLOverrideReachesUserdata' "$OLDPWD/gotest-guest.log" || fail "guest URL override not proven in userdata"
              cd "$OLDPWD"

              # ===== (C) PROVIDER ABI, end to end against the BUILT binary ========
              # Run the packaged binary exactly as GARM does (GARM_* env, the
              # rendered config file, the rendered interface version) with the
              # EC2 endpoint pointed at a closed local port. Under the rendered
              # version the call must get past the ABI dispatch and fail only
              # at the network; the v0.1.1 negative control must fail at the
              # dispatch, which is what proves this probe can see the bug.
              probe() {
                env -i PATH="$PATH" HOME="$HOME" \
                  GARM_INTERFACE_VERSION="$1" GARM_COMMAND=ListInstances \
                  GARM_CONTROLLER_ID=ctl-0 GARM_POOL_ID=pool-0 \
                  GARM_PROVIDER_CONFIG_FILE="$awscfg" \
                  AWS_ENDPOINT_URL=http://127.0.0.1:9 AWS_MAX_ATTEMPTS=1 \
                  AWS_ACCESS_KEY_ID=AKIDEXAMPLE AWS_SECRET_ACCESS_KEY=example \
                  AWS_EC2_METADATA_DISABLED=true \
                  timeout 60 "$awsBin" > "abi-$1.out" 2> "abi-$1.err" && return 0 || return 1
              }
              ! probe "$ifver" || fail "ListInstances unexpectedly succeeded against a closed endpoint"
              ! grep -q 'does not implement' "abi-$ifver.err" || fail "provider rejects the rendered interface version: $(cat abi-$ifver.err)"
              grep -q '127.0.0.1:9' "abi-$ifver.err" || fail "rendered-version call did not reach the EC2 API: $(cat abi-$ifver.err)"
              ! probe v0.1.1 || fail "v0.1.1 control unexpectedly succeeded"
              grep -q 'does not implement v0.1.1 ExternalProvider' abi-v0.1.1.err || fail "v0.1.1 negative control did not reproduce the ABI mismatch: $(cat abi-v0.1.1.err)"
              echo "[t_aws_burst_runners] provider ABI OK (rendered $ifver reaches EC2; v0.1.1 control rejected)"

              echo "[t_aws_burst_runners][PASS] AWS burst spill+floor+ephemeral+scale-back render and provider behaviour verified"
              touch "$out"
            '';
      };
    };
}
