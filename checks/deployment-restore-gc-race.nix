# Regression test: `deploy-apply` restores the desired closure safely against a
# concurrent garbage collection.
#
# The restore used to be a bare `nix copy --from <cache> <path>`. That copy
# skips the closure paths already present locally and does not root them, so a
# GC that runs before the copy registers their referrers deletes them, and the
# copy fails with "path '...' is not valid" (m3, 2026-10-30, on libxslt; m3 sits
# below `min-free`, so some process on it is collecting almost all the time).
# This check reproduces it with no timing involved: the test cache server runs a
# full `nix-store --gc` before it serves any NAR, which is after the copy has
# decided what to skip and before it registers what references the skipped
# paths.
#
# 1. Positive control: the old restore command fails with the production error,
#    which proves the setup reproduces the race.
# 2. The real `mcl-devops deploy-apply` restores the same closure through the
#    same server, and its switch command runs another full `nix-store --gc`
#    between the restore and activation, the second window the old code left
#    open. The closure must survive both.
#
# Everything happens in a chroot store under $TMPDIR, so the GC never touches
# the build sandbox's own store. Chroot stores are Linux-only, and so is this
# check; the commands under test are the same on nix-darwin.
{ ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      manifestPrivateKey = pkgs.writeText "mcl-gc-race-manifest-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7QAAAJifNGKYnzRi
        mAAAAAtzc2gtZWQyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7Q
        AAAEBvBnhoTQhoz/liGXDGeodsQFCPZfx7B/f10DxJy+VHP+G+pZMFoVf9csQhyja7Hjub
        zInPvGX69OyIHYsaTuHtAAAAEW1jbC1tYW5pZmVzdC10ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
      '';
      manifestPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOG+pZMFoVf9csQhyja7HjubzInPvGX69OyIHYsaTuHt mcl-manifest-test";

      # The dependency is already present on the target before the restore and
      # rooted by nothing, as libxslt was on m3. The system references it.
      dependency = pkgs.writeText "mcl-gc-race-dependency" "already present on the target\n";
      system = pkgs.runCommand "mcl-gc-race-system" { } ''
        mkdir -p "$out"
        printf '%s\n' ${dependency} > "$out/dependency"
      '';
      cache = pkgs.mkBinaryCache { rootPaths = [ system ]; };
      gcBeforeNarServer = pkgs.writeText "mcl-gc-race-cache-server.py" ''
        import functools
        import http.server
        import os
        import subprocess
        import sys

        cache, port_file, gc_log = sys.argv[1:4]


        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith("/nar/"):
                    subprocess.run(["nix-store", "--gc"], check=True)
                    with open(gc_log, "a") as log:
                        log.write(self.path + "\n")
                super().do_GET()


        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(Handler, directory=cache)
        )
        with open(port_file + ".tmp", "w") as port:
            port.write(str(server.server_port))
        os.rename(port_file + ".tmp", port_file)
        server.serve_forever()
      '';
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-restore-gc-race =
          pkgs.runCommand "deployment-restore-gc-race"
            {
              nativeBuildInputs = [
                self'.packages.mcl-devops
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.jq
                pkgs.nix
                pkgs.openssh
                pkgs.python3
              ];
            }
            ''
              set -euo pipefail
              root="$TMPDIR/gc-race"
              mkdir -p "$root/home" "$root/cache-home"
              export HOME="$root/home"
              export XDG_CACHE_HOME="$root/cache-home"
              export NIX_CONFIG='experimental-features = nix-command'

              # A signed binary cache, as the deployment cache is.
              cp -r ${cache} "$root/cache"
              chmod -R u+w "$root/cache"
              nix key generate-secret --key-name mcl-gc-race > "$root/cache.sk"
              cache_key=$(nix key convert-secret-to-public < "$root/cache.sk")
              nix store sign --store "file://$root/cache" --key-file "$root/cache.sk" \
                --recursive ${system}

              # From here on every nix command talks to the chroot store.
              export NIX_REMOTE="local?root=$root/store"

              # The deployment cache, served over HTTP. Before it answers any NAR
              # request it runs a full `nix-store --gc` against the target store:
              # the concurrent collection, at the one moment it does damage --
              # after the restore has decided which paths it can skip, before it
              # registers the path that references them.
              python3 ${gcBeforeNarServer} "$root/cache" "$root/port" "$root/gc-runs"               2> "$root/server.log" &
              server=$!
              trap 'kill "$server" 2>/dev/null || true' EXIT
              for _ in $(seq 100); do
                [ -s "$root/port" ] && break
                sleep 0.1
              done
              cache_url="http://127.0.0.1:$(cat "$root/port")"

              key="$root/manifest-key"
              cp ${manifestPrivateKey} "$key"
              chmod 0600 "$key"
              mcl-devops deploy-plan \
                --target gc-race \
                --system ${pkgs.stdenv.hostPlatform.system} \
                --desired-system-path ${system} \
                --git-revision 0123456789abcdef0123456789abcdef01234567 \
                --sequence 1 \
                --signing-key "$key" \
                --signing-key-id mcl-deployment \
                --substituter "$cache_url" \
                --trusted-public-key "$cache_key" \
                --output "$root/manifest.json"

              stage_unrooted_dependency() {
                nix copy --from "file://$root/cache" \
                  --option trusted-public-keys "$cache_key" ${dependency}
                nix-store --check-validity ${dependency}
                if nix-store --check-validity ${system} 2>/dev/null; then
                  echo "the system must not be present before the restore" >&2
                  exit 1
                fi
              }

              # 1. Positive control: the previous restore command loses the race.
              stage_unrooted_dependency
              if nix copy --from "$cache_url" ${system} \
                --option narinfo-cache-negative-ttl 0 \
                --option trusted-public-keys "$cache_key" 2> "$root/copy.err"; then
                echo "positive control: the bare nix copy survived a concurrent GC;" \
                  "this check no longer reproduces the race" >&2
                exit 1
              fi
              cat "$root/copy.err" >&2
              grep -F "${dependency}' is not valid" "$root/copy.err"
              test "$(wc -l < "$root/gc-runs")" = 1

              # 2. deploy-apply restores the same closure through the same race.
              # Its switch runs another full GC before it "activates", so the
              # closure must also stay rooted between the restore and activation.
              stage_unrooted_dependency
              state="$root/state"
              switch="$root/switch.sh"
              cat > "$switch" <<EOF
              set -eu
              nix-store --gc
              nix-store --check-validity ${system} ${dependency}
              test -e "$root/store${system}/dependency"
              test -e "$root/store${dependency}"
              printf '%s\n' ${system} > "$root/current-generation"
              EOF
              printf '%s\n' /nix/store/00000000000000000000000000000000-mcl-gc-race-previous \
                > "$root/current-generation"
              mcl-devops deploy-apply \
                --manifest "$root/manifest.json" \
                --target gc-race \
                --trusted-manifest-public-key ${lib.escapeShellArg manifestPublicKey} \
                --state-dir "$state" \
                --event-log "$root/events.jsonl" \
                --generation-command "cat '$root/current-generation'" \
                --switch-command "sh '$switch'" \
                --no-detach-switch || {
                jq -s . "$root/events.jsonl" >&2
                exit 1
              }

              test "$(cat "$root/current-generation")" = ${system}
              # The concurrent GC really ran during this restore too.
              test "$(wc -l < "$root/gc-runs")" = 2
              jq -e -s --arg root "$state/gcroots/gc-race" '
                ([.[] | select(.phase == "agent-restore")] | length == 1) and
                (.[] | select(.phase == "agent-restore") |
                  .command.status == "succeeded" and
                  .command.argv[0:4] == ["nix-store", "--realise", "${system}", "--add-root"] and
                  .metadata.gcRoot == $root) and
                (.[] | select(.phase == "complete") | .command.status == "succeeded")
              ' "$root/events.jsonl" >/dev/null || {
                jq -s . "$root/events.jsonl" >&2
                exit 1
              }
              # The root is only held for the transaction; the profile owns the
              # generation afterwards.
              test ! -L "$state/gcroots/gc-race"

              mkdir -p "$out"
              printf '%s\n' 'deployment-restore-gc-race: passed' > "$out/result"
            '';
      };
    };
}
