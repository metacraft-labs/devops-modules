_top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving gate: t_fleet_alert_routing.
  #
  # Proves the fleet Alertmanager routing (../modules/alertmanager-fleet-routing)
  # is VALID and honours the severity/component ROUTING CONTRACT that the RE1
  # alert rules stamp onto every alert — WITHOUT the infra repo. It renders the
  # default config (packages.fleet-alertmanager-config), then runs:
  #
  #   amtool check-config          — the config parses + is structurally valid.
  #   amtool config routes test    — a `severity=critical,component=garm-fleet`
  #                                  alert routes to the PAGER receiver, and a
  #                                  `severity=warning,component=garm-fleet` alert
  #                                  routes to the CI-ops receiver.
  #
  # This is the amtool analogue of the promtool contract the RE1 rule gate
  # (fleet-alerting.nix) uses: the file amtool replays is the exact file the host
  # deploys, because both come from the pure ../modules/alertmanager-fleet-routing/
  # config.nix.
  perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      amConfig = config.packages.fleet-alertmanager-config;
      amConfigDeadman = config.packages.fleet-alertmanager-config-deadman;
      amtool = "${pkgs.prometheus-alertmanager}/bin/amtool";
    in
    {
      checks.t_fleet_alert_routing =
        pkgs.runCommand "t_fleet_alert_routing"
          {
            nativeBuildInputs = [ pkgs.prometheus-alertmanager ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_fleet_alert_routing][FAIL] $1" >&2; exit 1; }

            cp ${amConfig} alertmanager.yml

            echo "[t_fleet_alert_routing] amtool check-config"
            ${amtool} check-config alertmanager.yml \
              || fail "amtool check-config rejected the rendered routing config"

            route_for() {
              # `amtool config routes test` prints the matched receiver name.
              ${amtool} config routes test --config.file alertmanager.yml "$@" | tr -d '[:space:]'
            }

            echo "[t_fleet_alert_routing] critical,garm-fleet -> pager"
            crit=$(route_for severity=critical component=garm-fleet)
            [ "$crit" = "pager" ] \
              || fail "severity=critical,component=garm-fleet routed to '$crit', expected 'pager'"

            echo "[t_fleet_alert_routing] warning,garm-fleet -> ci-ops"
            warn=$(route_for severity=warning component=garm-fleet)
            [ "$warn" = "ci-ops" ] \
              || fail "severity=warning,component=garm-fleet routed to '$warn', expected 'ci-ops'"

            # A plain critical (any component) must still page — the severity
            # catch-all below the fleet subtree.
            echo "[t_fleet_alert_routing] critical,other -> pager (severity catch-all)"
            other=$(route_for severity=critical component=other)
            [ "$other" = "pager" ] \
              || fail "severity=critical,component=other routed to '$other', expected 'pager'"

            # ── Dead-man's-switch render: the Watchdog must route to the
            # dedicated off-host heartbeat receiver, and enabling it must NOT
            # divert the ordinary severity buckets. ──
            cp ${amConfigDeadman} alertmanager-deadman.yml
            echo "[t_fleet_alert_routing] deadman render: amtool check-config"
            ${amtool} check-config alertmanager-deadman.yml \
              || fail "amtool check-config rejected the dead-man routing config"

            route_dm() {
              ${amtool} config routes test --config.file alertmanager-deadman.yml "$@" | tr -d '[:space:]'
            }

            echo "[t_fleet_alert_routing] Watchdog -> deadmanswitch"
            wd=$(route_dm alertname=Watchdog severity=none)
            [ "$wd" = "deadmanswitch" ] \
              || fail "Watchdog routed to '$wd', expected 'deadmanswitch'"

            echo "[t_fleet_alert_routing] deadman render: critical,garm-fleet still -> pager"
            dmcrit=$(route_dm severity=critical component=garm-fleet)
            [ "$dmcrit" = "pager" ] \
              || fail "with dead-man route, critical routed to '$dmcrit', expected 'pager'"

            echo "[t_fleet_alert_routing][PASS] config valid; critical->pager, warning->ci-ops, Watchdog->deadmanswitch as contracted"
            touch $out
          '';
    };
}
