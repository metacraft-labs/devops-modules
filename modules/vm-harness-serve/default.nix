{ withSystem, ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA2.
  #
  # `services.vm-harness-serve` — a hardened systemd unit running `vm-harness
  # serve` (the RA1 remoting daemon). This is the GENERAL, company-agnostic
  # machinery: it bakes in NO Metacraft host list, IPs, or credentials. The
  # concrete instantiation (which hosts, which overlay IPs, the agenix token
  # ciphertext) lives in the private `infra` repo, which CONSUMES these options.
  #
  # The daemon is the uniform network access point that lets ONE central GARM's
  # providers target every Linux host (campaign Phase B), replacing the per-host
  # GARM + the eph-linux-x64 capacity band-aid. The SAME daemon fronts whichever
  # backends the host runs — the per-request backend is the client's
  # `run --backend <id>` argv — so one instance can serve incus (Linux
  # containers) AND libvirt (e.g. the Windows-11 VMs on high-mem-server, RA3).
  # Backend access is opened parametrically: {option}`extraGroups` for the
  # backend's control group(s) as a unit-level runtime grant (enough for incus,
  # which checks the socket peer's runtime groups), {option}`staticGroups` for
  # backends whose authorization reads the user's STATIC group-database entry
  # instead (libvirt, via polkit — a runtime-only grant is invisible to it),
  # {option}`extraPackages` for its CLI(s), and {option}`readWritePaths` /
  # {option}`readOnlyPaths` for the sandbox holes a disk-image backend needs.
  # NO backend is hardcoded here.
  #
  # Posture (campaign non-negotiable pattern (a) + serve.md "Auth & network
  # posture"): the control channel is authenticated (bearer token over the
  # NetBird overlay) and is NEVER exposed on a public interface. This module
  # enforces that two ways at once — it binds the listener to a single overlay
  # address (never 0.0.0.0), and it opens the port ONLY on the overlay
  # interface's firewall zone (never the global firewall). The bearer token is
  # delivered out of the world-readable store via systemd `LoadCredential`
  # (agenix-provisioned ciphertext in infra).
  #
  # It is idle-cheap / scale-to-zero-friendly: one acceptor thread plus a small
  # bounded pool of request handlers, all parked in a blocking wait when idle —
  # no polling and no busy loop, so an idle daemon costs ~nothing.
  #
  # Runner-Fleet-M3-ARM-Wave MA12 — THE HEALTHCHECK WATCHDOG. The daemon has
  # twice gone silently deaf in production (high-mem-server, gpu-server-001),
  # each time staying `active` with its port `LISTEN`ing while answering
  # nothing, once for nineteen hours. `Restart=on-failure` cannot see that: the
  # process never failed. The vm-harness side now bounds the damage three ways
  # (a bounded handler pool, a dedicated acceptor that answers 503 rather than
  # letting connections rot in the backlog, and a per-exec deadline), but none
  # of those can bound the OUTAGE if the daemon is wedged for a reason nobody
  # anticipated. So this module also ships the platform's own health
  # supervision: a periodic timer that PROBES the listener and restarts the unit
  # after repeated failures, modelled directly on the `services.garm`
  # FU9 GARM-API-WATCHDOG in this repo, which exists for the same
  # process-alive-but-API-dead failure.
  flake.modules.nixos.vm-harness-serve =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.vm-harness-serve;
      inherit (lib)
        mkEnableOption
        mkIf
        mkOption
        types
        optional
        optionals
        optionalString
        ;

      # Default to this flake's vendored vm-harness package (its single binary
      # includes `vm-harness serve`), resolved for the host's system — mirrors
      # how `services.garm` defaults `package` to `config.packages.garm`.
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.vm-harness
      );

      credName = "token";
      # $CREDENTIALS_DIRECTORY is exposed to the unit as %d.
      tokenCredPath = "%d/${credName}";
      # RA6 enrollment secret (the per-host HMAC key the signed /v1/manifest keyId
      # derives from), staged the same LoadCredential way as the bearer token.
      enrollCredName = "enroll-secret";
      enrollCredPath = "%d/${enrollCredName}";
      runtimeDir = "vm-harness-serve";
      portFile = "/run/${runtimeDir}/port";

      # ----- EPHEMERAL-INSTANCE INVENTORY EXPORTER --------------------------
      icfg = cfg.inventoryExporter;
      labelDir = "/var/lib/${runtimeDir}/ephemeral-labels";
      # The snapshot is rendered by the serve user into its OWN state dir
      # (0750) and published into the shared textfile dir by a separate
      # privileged step: that dir is root:root 0755 fleet-wide (infra's
      # services/monitoring/node-exporter-textfile.nix), so an unprivileged
      # writer gets EACCES there even with ReadWritePaths, and loosening it
      # (the old 0777) would let any local user feed node-exporter.
      inventoryStateName = "vm-harness-serve-inventory";
      inventoryStage = "/var/lib/${inventoryStateName}/vmh-ephemeral.prom";
      inventoryPublishScript = pkgs.writeShellApplication {
        name = "vm-harness-serve-inventory-publish";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          dir=${lib.escapeShellArg icfg.textfileDir}
          install -m 0644 -o root -g root ${lib.escapeShellArg inventoryStage} "$dir/.vmh-ephemeral.prom.tmp"
          mv -f "$dir/.vmh-ephemeral.prom.tmp" "$dir/vmh-ephemeral.prom"
        '';
      };
      inventoryScript = pkgs.writeShellApplication {
        name = "vm-harness-serve-inventory";
        runtimeInputs = [
          cfg.package
          pkgs.jq
          pkgs.coreutils
          pkgs.gnugrep
        ]
        ++ cfg.extraPackages;
        text = ''
          dir="$(dirname ${lib.escapeShellArg inventoryStage})"
          tmp="$(mktemp "$dir/.vmh-ephemeral.XXXXXX")"
          trap 'rm -f "$tmp"' EXIT
          {
            echo "# HELP vmh_ephemeral_instances Kept per-job instances on this host, by state and whether a GARM pool owns them."
            echo "# TYPE vmh_ephemeral_instances gauge"
            echo "# HELP vmh_ephemeral_list_success 1 if vm-harness could enumerate the backend on the last cycle."
            echo "# TYPE vmh_ephemeral_list_success gauge"
            backends=(${lib.escapeShellArgs icfg.backends})
            for b in "''${backends[@]}"; do
              # The result is ONE marker-keyed JSON line; a failed enumeration
              # prints none and exits non-zero. Never report a failure as zero
              # instances — emit list_success 0 and no instance series.
              if line="$(vm-harness ephemeral-list --backend "$b" \
                    --ephemeral-prefix ${lib.escapeShellArg icfg.namePrefix} \
                    --log-format json 2>/dev/null | grep -F '"vmhEphemeralList"' | tail -n 1)" \
                  && [ -n "$line" ]; then
                echo "vmh_ephemeral_list_success{backend=\"$b\"} 1"
                printf '%s\n' "$line" | jq -r --arg b "$b" '
                  .instances as $i
                  | ["running", "stopped", "error", "unknown"][] as $s
                  | ["true", "false"][] as $a
                  | ($i | map(select(.state == $s
                        and ((((.labels // {})["garm-pool"] // "") != "") | tostring) == $a))
                        | length) as $n
                  | "vmh_ephemeral_instances{backend=\"\($b)\",state=\"\($s)\",attributed=\"\($a)\"} \($n)"'
              else
                echo "vmh_ephemeral_list_success{backend=\"$b\"} 0"
              fi
            done
          } >"$tmp"
          chmod 0644 "$tmp"
          mv -f "$tmp" ${lib.escapeShellArg inventoryStage}
          trap - EXIT
        '';
      };

      # ----- MA12 SERVE-LISTENER WATCHDOG ---------------------------------
      hcfg = cfg.healthcheck;

      # WHAT IS PROBED, and why it is emphatically NOT an authenticated call.
      #
      # An UNAUTHENTICATED GET /v1/info is answered 401 by a live daemon. That
      # 401 is a SUCCESS signal here: producing it requires the accept, the
      # dispatch to a handler, the request read and the response write — the
      # entire path that was dead in production — while costing the daemon
      # nothing, because the auth gate rejects before any dispatch work.
      #
      # The authenticated form would be actively harmful as a probe: it
      # synchronously probes every registered hypervisor backend. MEASURED
      # 2026-09-18 on an aarch64-darwin host: 16.7s authenticated versus 5ms
      # unauthenticated. Probing that on a timer would both mistake a slow
      # answer for a dead one and put a real periodic load on the host.
      #
      # It also keeps the watchdog credential-free — it never needs the bearer
      # token, so no secret is staged into a root-run timer unit.
      healthProbeURL = "http://${cfg.listenAddress}:${toString cfg.port}/v1/info";

      healthCheckScript = pkgs.writeShellApplication {
        name = "vm-harness-serve-healthcheck";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.systemd
          pkgs.gnused
        ];
        text = ''
          set -euo pipefail

          url="${healthProbeURL}"
          fail_file="/var/lib/vm-harness-serve-healthcheck/consecutive-failures"
          last_restart_file="/var/lib/vm-harness-serve-healthcheck/last-restart"
          threshold=${toString hcfg.failureThreshold}

          log() { echo "vm-harness-serve-healthcheck: $*"; }

          # Probe. `-o /dev/null -w %{http_code}` so the STATUS is inspected, not
          # merely curl's exit code: a 503 means the daemon is up but has no
          # free handler, which is a real degradation the watchdog must count as
          # a failure rather than wave through as "it answered".
          # `-w %{http_code}` ALREADY prints 000 when curl cannot reach the
          # listener, so the old `|| echo "000"` appended a SECOND 000 and the
          # variable became "000000" — which matched neither the `000)` wedge
          # branch nor `200|401`, so the daemon's most important failure mode
          # was logged as "unexpected HTTP". It still counted as a failure, so
          # recovery worked; the diagnosis it printed did not. Keep curl's own
          # output and only neutralise its exit status.
          code=$(curl -s -o /dev/null -w '%{http_code}' \
                   --max-time ${toString hcfg.probeTimeout} "$url" </dev/null \
                 || true)
          code=''${code:-000}

          case "$code" in
            401|200)
              # Healthy: the listener accepted, dispatched and replied.
              if [ -f "$fail_file" ] && [ "$(cat "$fail_file" 2>/dev/null || echo 0)" != "0" ]; then
                log "listener healthy again (HTTP $code from $url) — resetting failure counter"
              fi
              printf '0' > "$fail_file"
              exit 0
              ;;
            503)
              log "listener answered 503 — every request handler is busy (saturated)"
              ;;
            000)
              log "listener did not answer within ${toString hcfg.probeTimeout}s (timeout/refused) — the wedge signature"
              ;;
            *)
              log "listener answered unexpected HTTP $code"
              ;;
          esac

          # Only act if the unit is actually meant to be up. A stopped or failed
          # daemon is systemd's job (Restart=on-failure); probing a deliberately
          # stopped one must not manufacture a "recovery".
          if [ "$(systemctl is-active vm-harness-serve.service 2>/dev/null || true)" != "active" ]; then
            log "probe failed but vm-harness-serve.service is not active — leaving it to systemd (no watchdog action)"
            printf '0' > "$fail_file"
            exit 0
          fi

          fails=$(( $(cat "$fail_file" 2>/dev/null || echo 0) + 1 ))
          printf '%s' "$fails" > "$fail_file"
          log "probe failed ($url); consecutive failures = $fails/$threshold"

          if [ "$fails" -lt "$threshold" ]; then
            exit 0
          fi

          # Rate-limit, so a daemon that is wedged for a systemic reason is not
          # restart-stormed. `systemd-analyze timespan` normalises any span to a
          # "μs: <N>" line; fall back to 600s if parsing ever fails, so the
          # limit is never silently a no-op.
          now=$(date +%s)
          min_gap_us=$(systemd-analyze timespan "${hcfg.minRestartInterval}" 2>/dev/null \
            | sed -n 's/^[^0-9]*μs:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)
          if [ -n "''${min_gap_us:-}" ]; then
            min_gap_s=$(( min_gap_us / 1000000 ))
          else
            min_gap_s=600
          fi

          if [ -f "$last_restart_file" ]; then
            last=$(cat "$last_restart_file" 2>/dev/null || echo 0)
            if [ $(( now - last )) -lt "$min_gap_s" ]; then
              log "listener dead for $fails probes, but a watchdog restart happened $(( now - last ))s ago (< ''${min_gap_s}s) — RATE-LIMITED, not restarting"
              exit 0
            fi
          fi

          log "listener dead for $fails consecutive probes — restarting vm-harness-serve.service (watchdog recovery)"
          printf '%s' "$now" > "$last_restart_file"
          printf '0' > "$fail_file"
          systemctl restart vm-harness-serve.service
          log "vm-harness-serve.service restart issued"
        '';
      };
    in
    {
      options.services.vm-harness-serve = {
        enable = mkEnableOption ''
          the `vm-harness serve` remoting daemon — an authenticated network
          front-end exposing this host's VM/container lifecycle ops to a remote
          controller over the NetBird overlay
        '';

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = lib.literalMD "this flake's `vm-harness` package";
          description = ''
            The vm-harness package whose `serve` subcommand is run. Its single
            binary includes both the daemon and the backend code it fronts.
          '';
        };

        listenAddress = mkOption {
          type = types.str;
          default = "127.0.0.1";
          example = "100.83.180.254";
          description = ''
            The single address the daemon binds to. This MUST be a NetBird
            overlay IP (or another private/overlay interface address) — NEVER a
            public interface and NEVER `0.0.0.0`. Binding one overlay address is
            the first of the two mechanisms that keep the control channel off the
            public internet (the second is the overlay-only firewall opening).

            The default `127.0.0.1` is a safe non-routable placeholder; a real
            deployment overrides it with the host's overlay IP.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 8873;
          description = "TCP port the daemon listens on (vm-harness serve default).";
        };

        backend = mkOption {
          type = types.str;
          default = "auto";
          example = "incus";
          description = ''
            The `--backend` the daemon reports/advertises on `GET /v1/info`
            (`auto` probes which backends are usable on this host). Note the
            per-request backend is chosen by the client's `run --backend <id>`
            argv, so this mainly seeds the capability report.
          '';
        };

        authTokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/run/agenix/vm-harness-serve/token";
          description = ''
            Path to the file holding the bearer token (a decrypted agenix
            secret, e.g. `config.age.secrets."vm-harness-serve/token".path`). It
            is handed to the daemon via systemd `LoadCredential`, so the token is
            copied into the unit's private credentials store and never placed in
            the world-readable Nix store. Required when {option}`enable` is true.
          '';
        };

        # ── RA6 enrollment (signed /v1/manifest) ──────────────────────────────
        enrollSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/run/agenix/vm-harness-serve/enroll-secret";
          description = ''
            Path to the per-host RA6 enrollment secret (a decrypted agenix
            secret). When set, the daemon signs `GET /v1/manifest` with an
            identity whose `keyId` derives from this secret (HMAC-SHA256), and the
            central GARM's `garm-serve-manifest-verify` preflight enrolls that
            keyId. Handed to the daemon via `LoadCredential` (never the store,
            never argv). Null leaves the daemon RA1-only (no signed manifest).
          '';
        };
        identityTtlSec = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 3600;
          description = ''
            Signed-identity lifetime in seconds (`serve --identity-ttl-sec`). Only
            meaningful with {option}`enrollSecretFile`. Null uses the daemon
            default (3600).
          '';
        };
        hostId = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "high-mem-server";
          description = ''
            Stable host identifier embedded in the signed manifest
            (`serve --host-id`). Only meaningful with {option}`enrollSecretFile`.
            Null lets the daemon derive it.
          '';
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = optional config.virtualisation.incus.enable config.virtualisation.incus.package;
          defaultText = lib.literalMD "`[ config.virtualisation.incus.package ]` when incus is enabled, else `[ ]`";
          description = ''
            Extra packages placed on the daemon's `PATH`. The serve daemon shells
            out to the backend CLI it drives (e.g. `incus`, `virsh`), so that CLI
            must be here. Defaults to the incus package when incus is enabled on
            the host.
          '';
        };

        user = mkOption {
          type = types.str;
          default = "vm-harness-serve";
          description = "System user the daemon runs as.";
        };

        group = mkOption {
          type = types.str;
          default = "vm-harness-serve";
          description = "Primary group of the daemon user.";
        };

        extraGroups = mkOption {
          type = types.listOf types.str;
          default = optional config.virtualisation.incus.enable "incus-admin";
          defaultText = lib.literalMD "`[ \"incus-admin\" ]` when incus is enabled, else `[ ]`";
          description = ''
            Supplementary groups the daemon needs to reach its backend. The incus
            client reaches the daemon socket via the `incus-admin` group (added by
            default when incus is enabled); a libvirt host adds `libvirtd` (the
            group NixOS' libvirtd polkit rule grants `org.libvirt.unix.manage`)
            plus `kvm`. A host that serves BOTH backends lists all of them, e.g.
            `[ "incus-admin" "libvirtd" "kvm" ]`.
          '';
        };

        staticGroups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "libvirtd" ];
          description = ''
            Groups the daemon USER is made a STATIC member of in the group
            database (`users.users.<user>.extraGroups`), in addition to the
            per-unit runtime {option}`extraGroups`.

            This distinction is load-bearing and backend-specific:

            * incus authorizes by the connecting process's *runtime* groups
              (`SO_PEERCRED`), so a unit-level `SupplementaryGroups` grant
              (i.e. {option}`extraGroups`) is enough — nothing is needed here.

            * libvirt authorizes through **polkit**, and polkit resolves
              `subject.isInGroup("libvirtd")` from the user's *static* group
              database entry, NOT from the process's runtime supplementary
              groups. A runtime-only grant is therefore invisible to polkit and
              the `org.libvirt.unix.manage` action is refused. So a libvirt host
              MUST list `libvirtd` (the group NixOS' libvirtd polkit rule
              allows) here, e.g. `[ "libvirtd" "kvm" ]`.

            Static membership is a per-user grant, so keep {option}`user` a
            dedicated system user (the default) that runs nothing but this
            daemon.
          '';
        };

        readWritePaths = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "/storage/vm-harness-serve" ];
          description = ''
            Filesystem subtrees the daemon needs WRITE access to under the
            `ProtectSystem=strict` sandbox (which otherwise mounts the whole
            hierarchy read-only). Passed through to the unit's
            `ReadWritePaths=`.

            The incus path needs none of these (it drives everything through the
            incus socket). A libvirt host needs write access to the per-job image
            pool directory — where the backend writes each job's copy-on-write
            overlay (`<name>.overlay.qcow2`) and config-drive ISO before defining
            the transient domain. That directory must also be owned/writable by
            {option}`user` (create it with `systemd.tmpfiles`).
          '';
        };

        readOnlyPaths = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "/storage/iso" ];
          description = ''
            Filesystem subtrees to expose read-only to the daemon, passed through
            to the unit's `ReadOnlyPaths=`. Under `ProtectSystem=strict` the
            hierarchy is already read-only, so this is mostly documentation of
            intent — e.g. the directory holding a libvirt golden image the
            backend clones the per-job overlay from. Listing it makes the daemon's
            read surface explicit and survives a future relaxation of the sandbox.
          '';
        };

        serveThreads = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 8;
          description = ''
            `serve --serve-threads <n>`: how many request-handler threads the
            daemon runs behind its single acceptor. Null uses the daemon's own
            auto-size, `max(4, CPU count)` capped at 32.

            This bounds concurrency deliberately. Unbounded thread-per-connection
            would turn a burst of slow requests into a denial of service of its
            own; a bounded pool plus the acceptor's 503 turns the same burst into
            an explicit, retryable answer.
          '';
        };

        execDeadlineSec = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 46800;
          description = ''
            `serve --exec-deadline-sec <n>`: wall-clock budget for a single
            `/v1/exec`, after which the worker process is killed and the client
            told why. Null uses the daemon default (46800s = 13h).

            Keep this ABOVE the longest legitimate operation. The central GARM
            provider forwards `--timeout-sec 43200` (12h) on runner creates, so a
            deadline at or below that would kill live CI runners — a worse
            failure than the leak it bounds. It is a leak bound, not a latency
            bound: what bounds an OUTAGE is {option}`healthcheck`.
          '';
        };

        openFilesLimit = mkOption {
          type = types.int;
          default = 8192;
          example = 16384;
          description = ''
            File-descriptor bound for the daemon, applied to BOTH `LimitNOFILE`
            and `LimitNOFILESoft`.

            Setting only the hard limit is the trap: systemd's default SOFT
            limit is 1024 and that is what a process actually hits. Measured on
            high-mem-server: `LimitNOFILE=524288`, `LimitNOFILESoft=1024`, and
            the daemon pinned at 1022 open descriptors.

            Every in-flight request holds a client socket plus the spawned
            worker's stdio pipes, the handler pool is CPU-sized, and each
            `/v1/exec` carrying user-data opens a staging file — so a busy
            controller exhausts 1024 without anything being wrong. The failure
            appears on the CONTROLLER as `Too many open files` while staging
            user-data, which reads as a remote-driving fault rather than an
            rlimit.

            8192 is far above any plausible concurrency and costs nothing when
            unused: this is a CEILING, not a reservation.
          '';
        };

        # ── MA12 listener watchdog ────────────────────────────────────────────
        healthcheck = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Periodically probe the serve listener and restart the unit when it
              stops answering — recovering a daemon that is process-alive but
              request-dead.

              Default TRUE, unlike most `enable` options in this repo, because
              the failure it recovers has happened twice in production and was
              invisible to every other mechanism: the process lives, all threads
              are present, the port listens, and `systemctl is-active` says
              nothing is wrong. An operator must opt OUT of supervision here,
              not into it.
            '';
          };

          interval = mkOption {
            type = types.str;
            default = "1m";
            description = ''
              How often to probe (a `systemd.time` span). The probe is a single
              unauthenticated loopback request that a healthy daemon answers in
              milliseconds, so a short interval is essentially free.
            '';
          };

          probeTimeout = mkOption {
            type = types.int;
            default = 5;
            description = ''
              Seconds one probe may take before it counts as failed. A healthy
              daemon answers the unauthenticated probe in milliseconds; this is
              set well above that so ordinary host load can never be mistaken
              for a wedge.
            '';
          };

          failureThreshold = mkOption {
            type = types.int;
            default = 3;
            description = ''
              How many CONSECUTIVE failed probes before the unit is restarted. A
              single failure never acts — with the default {option}`interval`
              this means the listener has been unresponsive for ~3 minutes,
              which no healthy state produces and which is three orders of
              magnitude below the 19-hour outage it exists to prevent.
            '';
          };

          minRestartInterval = mkOption {
            type = types.str;
            default = "10m";
            description = ''
              Minimum wall-clock time between two watchdog-initiated restarts. A
              daemon wedging for a systemic reason must not be restart-stormed;
              after this the watchdog keeps logging and leaves the host in a
              state an operator can inspect.
            '';
          };
        };

        # ── Ephemeral-instance inventory exporter (orphan detection) ─────────
        inventoryExporter = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Periodically run `vm-harness ephemeral-list` for each of
              {option}`backends` and publish the result as node-exporter textfile
              metrics:

                vmh_ephemeral_instances{backend,state,attributed}  gauge
                vmh_ephemeral_list_success{backend}                gauge (1/0)

              This host is the only party that can SEE an orphan: an instance
              GARM has forgotten is, by definition, absent from GARM. The
              garm-fleet-alerts library alerts on sustained STOPPED instances
              (a teardown that failed or was never issued — gpu-server-001/002
              filled their pool this way) and on runner-named instances no GARM
              pool owns (the ~210 leaked Windows domains on high-mem-server).
            '';
          };
          backends = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "incus" ];
            description = "Backends to enumerate (`incus`, `libvirt`, …): the ones GARM drives on this host.";
          };
          namePrefix = mkOption {
            type = types.str;
            default = "garm-";
            description = "Only instances whose name starts with this are counted (GARM's runner prefix), so durable VMs on the same hypervisor are never reported as orphans.";
          };
          interval = mkOption {
            type = types.str;
            default = "2m";
            description = "systemd OnUnitActiveSec interval between inventory snapshots.";
          };
          textfileDir = mkOption {
            type = types.str;
            # MUST equal node-exporter's `--collector.textfile.directory`; this
            # is the fleet's one textfile dir (infra
            # services/monitoring/node-exporter-textfile.nix). A different
            # path is written happily and never scraped.
            default = "/var/lib/prometheus-node-exporter/textfile";
            description = ''
              node-exporter textfile-collector directory the `.prom` snapshot is
              published into. Must match node-exporter's
              `--collector.textfile.directory`. The directory is kept
              `root:root 0755`; the snapshot is rendered by the serve user in
              its own state directory and installed here by a privileged
              `ExecStartPost` step.
            '';
          };
        };

        overlayInterface = mkOption {
          type = types.nullOr types.str;
          default = "nb-default";
          example = "nb-default";
          description = ''
            The overlay (NetBird) network interface whose firewall zone the port
            is opened on — and ONLY that zone. This never touches the global
            firewall (`networking.firewall.allowedTCPPorts`), so the port stays
            unreachable from any non-overlay interface. Set to `null` to open no
            firewall hole at all (rely solely on the overlay-address bind, e.g.
            when the overlay interface is already fully trusted).
          '';
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.authTokenFile != null;
            message = ''
              services.vm-harness-serve.authTokenFile must be set — the daemon
              refuses to start without a bearer token, and it must arrive via a
              LoadCredential-mounted file (an agenix secret), never the store.
            '';
          }
          {
            assertion = cfg.listenAddress != "0.0.0.0" && cfg.listenAddress != "::";
            message = ''
              services.vm-harness-serve.listenAddress must be a single overlay
              address, never a wildcard (0.0.0.0 / ::) — the control channel must
              not be exposed on a public interface.
            '';
          }
        ];

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = "/var/lib/${runtimeDir}";
          # STATIC group membership — needed by backends whose access check
          # reads the user's group-database entry rather than the socket peer's
          # runtime groups (libvirt via polkit). See staticGroups' description.
          extraGroups = cfg.staticGroups;
        };
        users.groups.${cfg.group} = { };

        # Open the port ONLY on the overlay interface's firewall zone — never the
        # global firewall. Combined with the single-address bind, the port is
        # unreachable off the overlay.
        networking.firewall.interfaces = mkIf (cfg.overlayInterface != null) {
          ${cfg.overlayInterface}.allowedTCPPorts = [ cfg.port ];
        };

        systemd.services.vm-harness-serve = {
          description = "vm-harness serve — VM/container remoting daemon (NetBird-only)";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
          ]
          ++ optional config.virtualisation.incus.enable "incus.service"
          # Order after libvirtd when present so its system socket exists before
          # the daemon may be asked to drive a libvirt job (harmless on hosts
          # that never receive a `--backend libvirt` request).
          ++ optional config.virtualisation.libvirtd.enable "libvirtd.service"
          # Order after agenix ONLY when it runs as a systemd unit; on the infra
          # hosts agenix runs from an activation script (no unit), so this stays
          # inert there.
          ++ optional (config.systemd.services ? agenix-install-secrets) "agenix-install-secrets.service";
          wants = [ "network-online.target" ];
          requires = optional config.virtualisation.incus.enable "incus.service";

          # The backend CLI the daemon shells out to must be on PATH.
          path = [ cfg.package ] ++ cfg.extraPackages;

          serviceConfig = {
            # Type=exec (not simple): with LoadCredential, `exec` waits for the
            # credential setup + the execve, avoiding the credential-race the
            # garm module documents.
            Type = "exec";
            ExecStart = lib.concatStringsSep " " (
              [
                (lib.getExe cfg.package)
                "serve"
                "--listen ${cfg.listenAddress}:${toString cfg.port}"
                "--backend ${cfg.backend}"
                "--auth-token-file ${tokenCredPath}"
                "--port-file ${portFile}"
              ]
              # RA6: sign /v1/manifest when an enrollment secret is provided.
              ++ optional (cfg.enrollSecretFile != null) "--enroll-secret-file ${enrollCredPath}"
              ++ optional (cfg.identityTtlSec != null) "--identity-ttl-sec ${toString cfg.identityTtlSec}"
              ++ optional (cfg.hostId != null) "--host-id ${cfg.hostId}"
              # MA12: concurrency bound + per-exec deadline. Both null by
              # default, leaving the daemon's own documented defaults in force.
              ++ optional (cfg.serveThreads != null) "--serve-threads ${toString cfg.serveThreads}"
              ++ optional (cfg.execDeadlineSec != null) "--exec-deadline-sec ${toString cfg.execDeadlineSec}"
            );
            LoadCredential = [
              "${credName}:${toString cfg.authTokenFile}"
            ]
            ++ optional (cfg.enrollSecretFile != null) "${enrollCredName}:${toString cfg.enrollSecretFile}";
            # Fail fast + loud if the agenix secret is missing at start.
            # (unitConfig below.)

            User = cfg.user;
            Group = cfg.group;
            SupplementaryGroups = cfg.extraGroups;

            Restart = "on-failure";
            RestartSec = 2;

            # THE SOFT LIMIT IS THE ONE THAT BITES, AND systemd's DEFAULT IS
            # 1024 — measured, not precautionary. On high-mem-server this unit
            # showed `LimitNOFILE=524288` (generous) but `LimitNOFILESoft=1024`,
            # with the daemon pinned at 1022 open descriptors. A concurrent
            # serve gets there easily: every in-flight request holds a client
            # socket plus the spawned worker's stdio pipes, the handler pool is
            # CPU-sized, and each /v1/exec carrying user-data opens a staging
            # file.
            #
            # It surfaces on the CONTROLLER, not here, as a provider error that
            # names the symptom and not the cause:
            #
            #   failed to stage user-data: Too many open files
            #
            # so it reads as a remote-driving or permissions fault rather than
            # an rlimit. Setting BOTH bounds pins the soft limit up to the hard
            # one; leaving `LimitNOFILE` alone would keep the 1024 soft default
            # in force. The darwin sibling carries the same fix as
            # `SoftResourceLimits.NumberOfFiles`, for the same reason — macOS's
            # default there is 256.
            LimitNOFILE = cfg.openFilesLimit;
            LimitNOFILESoft = cfg.openFilesLimit;

            RuntimeDirectory = runtimeDir;
            RuntimeDirectoryMode = "0750";
            StateDirectory = runtimeDir;
            StateDirectoryMode = "0700";
            WorkingDirectory = "/var/lib/${runtimeDir}";
            # The incus CLI writes its config under $HOME; keep it in the state dir.
            # VMH_EPHEMERAL_LABEL_DIR: where `ephemeral-label` records which GARM
            # pool owns each kept instance, so the provider's ListInstances can
            # return exactly one pool's instances. It must be writable under
            # ProtectSystem=strict, i.e. inside the StateDirectory; named
            # explicitly rather than left to vm-harness's $STATE_DIRECTORY default.
            Environment = [
              "HOME=/var/lib/${runtimeDir}"
              "VMH_EPHEMERAL_LABEL_DIR=${labelDir}"
            ];

            # ---- systemd hardening (mirrors the garm incus-strict posture) ----
            NoNewPrivileges = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            PrivateTmp = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            RemoveIPC = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
              "~@resources"
            ];
            CapabilityBoundingSet = [ "" ];
            AmbientCapabilities = [ "" ];
            UMask = "0077";
          }
          # Punch the backend-specific holes in ProtectSystem=strict: a libvirt
          # host needs its per-job image pool writable and (optionally) the
          # golden's directory read-exposed. incus hosts leave both empty.
          // lib.optionalAttrs (cfg.readWritePaths != [ ]) {
            ReadWritePaths = cfg.readWritePaths;
          }
          // lib.optionalAttrs (cfg.readOnlyPaths != [ ]) {
            ReadOnlyPaths = cfg.readOnlyPaths;
          };

          unitConfig.AssertPathExists = [ (toString cfg.authTokenFile) ];
        };

        # ---- MA12 SERVE-LISTENER WATCHDOG: health-check service + timer ----
        # A periodic oneshot that probes the listener on the SAME address+port
        # the daemon binds. It restarts vm-harness-serve.service ONLY after
        # `failureThreshold` consecutive unanswered/saturated probes, and never
        # more often than `minRestartInterval`.
        #
        # It runs as ROOT (it must `systemctl restart` the unit) but does only a
        # loopback-ish curl, a counter file under its own state dir, and one
        # restart. The heavy sandbox the daemon itself carries is unnecessary
        # here and would block the systemctl D-Bus call, so this is
        # intentionally light — matching the garm-healthcheck precedent.
        #
        # NOTE the state dir is the watchdog's OWN, never the daemon's. Sharing
        # StateDirectory with the supervised unit is what made garm-healthcheck
        # re-chown /var/lib/garm to root on every run and break garm's DB
        # access; that lesson is inherited here rather than relearned.
        systemd.services.vm-harness-serve-healthcheck = mkIf hcfg.enable {
          description = "vm-harness serve listener health-check watchdog (auto-recover a process-alive-but-request-dead daemon)";
          after = [ "vm-harness-serve.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe healthCheckScript;
            StateDirectory = "vm-harness-serve-healthcheck";
            ProtectSystem = "strict";
            NoNewPrivileges = true;
            ProtectHome = true;
            PrivateTmp = true;
          };
        };

        # ---- EPHEMERAL-INSTANCE INVENTORY EXPORTER: service + timer ----
        # Runs as the serve user with the serve daemon's groups and label dir,
        # so it enumerates exactly what the daemon's `ephemeral-list` workers
        # see. Read-only apart from its own 0750 state dir; the privileged
        # ExecStartPost (`+`: full privileges, no sandbox) only installs the
        # rendered file into the root-owned textfile dir.
        systemd.tmpfiles.rules = mkIf icfg.enable [ "d ${icfg.textfileDir} 0755 root root -" ];
        systemd.services.vm-harness-serve-inventory = mkIf icfg.enable {
          description = "Publish vm-harness kept-instance inventory for orphan alerting";
          after = [ "vm-harness-serve.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe inventoryScript;
            ExecStartPost = "+${lib.getExe inventoryPublishScript}";
            StateDirectory = inventoryStateName;
            StateDirectoryMode = "0750";
            User = cfg.user;
            Group = cfg.group;
            SupplementaryGroups = cfg.extraGroups;
            Environment = [
              "HOME=/var/lib/${runtimeDir}"
              "VMH_EPHEMERAL_LABEL_DIR=${labelDir}"
            ];
            ProtectSystem = "strict";
            NoNewPrivileges = true;
            ProtectHome = true;
            PrivateTmp = true;
          };
        };
        systemd.timers.vm-harness-serve-inventory = mkIf icfg.enable {
          description = "Periodic vm-harness kept-instance inventory snapshot";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = icfg.interval;
            OnUnitActiveSec = icfg.interval;
            AccuracySec = "10s";
            Unit = "vm-harness-serve-inventory.service";
          };
        };

        systemd.timers.vm-harness-serve-healthcheck = mkIf hcfg.enable {
          description = "Periodic vm-harness serve listener health-check (MA12 watchdog)";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = hcfg.interval;
            OnUnitActiveSec = hcfg.interval;
            # If the machine was asleep, do not fire a burst of catch-up runs.
            AccuracySec = "10s";
            Unit = "vm-harness-serve-healthcheck.service";
          };
        };
      };
    };
}
