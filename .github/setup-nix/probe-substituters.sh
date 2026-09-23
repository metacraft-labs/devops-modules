#!/usr/bin/env bash
# probe-substituters.sh — prove every configured binary cache is READABLE
# before the job asks Nix to substitute from it.
#
# WHY THIS EXISTS
#
# Nix is quiet about a binary cache it cannot use. Two failure shapes were
# observed on ephemeral self-hosted runners:
#
#   * The private Attic answered `nix-cache-info` with 403 (the cache host's
#     nginx network ACL did not cover the runner subnet) and, in the same job,
#     no attic token had been passed at all. Nix prints ONE warning, drops the
#     substituter for the rest of the process, and every path that only lives
#     there is built from source.
#   * cache.nixos.org transfers timed out, Nix "disabled" it for 60 seconds,
#     and — with `fallback = true` — the whole closure (stdenv included) was
#     scheduled for a source build. One job hung for five hours in a
#     `nix develop` that was meant to fetch `age`.
#
# Neither is visible until long after the fact. This probe turns both into a
# named, early, cheap failure (or at least a loud annotation): it reads
# `<substituter>/nix-cache-info` with the SAME netrc file Nix is configured to
# use, so "the credential Nix will send" is what gets tested, not a copy of it.
#
# POLICY
#
#   cache.nixos.org   — must be readable; if it is not, nothing downstream
#                       can work, so the probe fails unless mode is `off`.
#   every other cache — mode `fail`: the job fails here.
#                       mode `warn` (default): a `::warning::` annotation that
#                       names the cause and the consequence (source builds).
#                       Default is `warn` because many consumers run on
#                       GitHub-hosted runners that cannot reach a NetBird-gated
#                       cache at all, and have always relied on skipping it.
#   mode `off`        — probe nothing.
#
# Transport failures (DNS, connect, TLS, 5xx) are retried; 401/403/404 are not,
# because a missing or refused credential will still be refused a second later.
#
# Inputs (environment):
#   SETUP_NIX_PROBE_SUBSTITUTERS   whitespace-separated substituter URLs
#   SETUP_NIX_PROBE_MODE           fail | warn | off          (default: warn)
#   SETUP_NIX_PROBE_NETRC          netrc file Nix uses        (optional)
#   SETUP_NIX_PROBE_TOKEN_SUPPLIED true | false — whether an attic token was
#                                  given, used only to word the diagnosis
#   SETUP_NIX_PROBE_ATTEMPTS       transport attempts per cache (default: 3)
#   SETUP_NIX_PROBE_CONNECT_TIMEOUT seconds, TCP+TLS          (default: 8)
#   SETUP_NIX_PROBE_MAX_TIME       seconds per attempt         (default: 20)
#   SETUP_NIX_PROBE_UPSTREAM       the cache that must always be usable
#                                  (default: https://cache.nixos.org; the
#                                  contract suite points it at a local origin)
#   GITHUB_STEP_SUMMARY            appended to when set
#
# Contract suite: tests/probe-substituters-test.sh.

set -uo pipefail

substituters="${SETUP_NIX_PROBE_SUBSTITUTERS:-}"
mode="${SETUP_NIX_PROBE_MODE:-warn}"
netrc="${SETUP_NIX_PROBE_NETRC:-}"
token_supplied="${SETUP_NIX_PROBE_TOKEN_SUPPLIED:-false}"
attempts="${SETUP_NIX_PROBE_ATTEMPTS:-3}"
connect_timeout="${SETUP_NIX_PROBE_CONNECT_TIMEOUT:-8}"
max_time="${SETUP_NIX_PROBE_MAX_TIME:-20}"
upstream="${SETUP_NIX_PROBE_UPSTREAM:-https://cache.nixos.org}"

case "$mode" in
  fail | warn) ;;
  off)
    echo "substituter preflight: disabled (mode=off)"
    exit 0
    ;;
  *)
    echo "::error::substituter-preflight must be one of fail, warn, off; got '$mode'."
    exit 1
    ;;
esac

if ! command -v curl >/dev/null 2>&1; then
  echo "::error::curl is not on this runner image, so the binary caches cannot be probed. Set substituter-preflight: off to skip the probe knowingly."
  exit 1
fi

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# `url` without a trailing slash, so `$url/nix-cache-info` is well formed.
normalise() {
  local url="$1"
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  printf '%s' "$url"
}

is_upstream() {
  [[ "$(normalise "$1")" == "$(normalise "$upstream")" ]]
}

body_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$body_file" "$err_file"' EXIT

failures=0
warnings=0
probed=0

summary "### Nix binary-cache preflight"
summary ""
summary "| substituter | result |"
summary "|---|---|"

for raw in $substituters; do
  url="$(normalise "$raw")"
  case "$url" in
    http://* | https://*) ;;
    *)
      echo "substituter preflight: skipping non-HTTP substituter $url"
      summary "| \`$url\` | skipped (not HTTP) |"
      continue
      ;;
  esac
  probed=$((probed + 1))

  netrc_args=()
  if [[ -n "$netrc" && -r "$netrc" ]]; then
    # Nix hands this exact file to libcurl (CURLOPT_NETRC_FILE), optional mode.
    netrc_args=(--netrc-optional --netrc-file "$netrc")
  fi

  status="000"
  attempt=0
  while [[ "$attempt" -lt "$attempts" ]]; do
    attempt=$((attempt + 1))
    : >"$body_file"
    : >"$err_file"
    status="$(curl -sS -o "$body_file" -w '%{http_code}' \
      --connect-timeout "$connect_timeout" --max-time "$max_time" \
      ${netrc_args[@]+"${netrc_args[@]}"} \
      "$url/nix-cache-info" 2>"$err_file")" || true
    [[ -n "$status" ]] || status="000"
    case "$status" in
      200 | 401 | 403 | 404) break ;;
    esac
    if [[ "$attempt" -lt "$attempts" ]]; then
      echo "substituter preflight: $url attempt $attempt/$attempts: HTTP $status $(head -c 200 "$err_file" | tr '\n' ' ')— retrying"
      sleep "$attempt"
    fi
  done

  reason=""
  if [[ "$status" == "200" ]]; then
    if grep -q '^StoreDir:' "$body_file"; then
      echo "substituter preflight: OK  $url"
      summary "| \`$url\` | OK |"
      continue
    fi
    reason="HTTP 200 but the body is not a nix-cache-info document (a captive portal or a proxy error page?)"
  elif [[ "$status" == "401" ]]; then
    if [[ "$token_supplied" == "true" ]]; then
      reason="HTTP 401: the cache rejected the credential it was sent. The attic token is expired, revoked, or lacks pull permission on this cache."
    else
      reason="HTTP 401: no credential was sent. This is a private cache and no attic-token was passed to setup-nix, so Nix reads it anonymously."
    fi
  elif [[ "$status" == "403" ]]; then
    reason="HTTP 403: refused before (or regardless of) authentication. For an Attic cache behind an nginx network ACL this means the runner's SOURCE ADDRESS is not in the allow-list — e.g. a runner on a bridge subnet that reaches the cache host without NAT. A token cannot fix this; the cache host's ACL (or the runner's egress path) must."
  elif [[ "$status" == "404" ]]; then
    reason="HTTP 404: no nix-cache-info at this URL. The substituter URL is wrong (cache name typo, or the cache was deleted)."
  elif [[ "$status" == "000" ]]; then
    reason="unreachable after $attempts attempt(s): $(head -c 300 "$err_file" | tr '\n' ' ')"
  else
    reason="HTTP $status after $attempts attempt(s)"
  fi

  echo "substituter preflight: FAIL $url — $reason"
  if [[ -s "$body_file" && "$status" != "200" ]]; then
    echo "  response body (first 300 bytes): $(head -c 300 "$body_file" | tr '\n' ' ')"
  fi

  consequence="Nix will skip this cache, and every path only it holds will be BUILT FROM SOURCE."
  if is_upstream "$url" || [[ "$mode" == "fail" ]]; then
    echo "::error title=Binary cache unusable::$url — $reason $consequence"
    summary "| \`$url\` | **FAIL** — $reason |"
    failures=$((failures + 1))
  else
    echo "::warning title=Binary cache unusable::$url — $reason $consequence Set substituter-preflight: fail to make this fatal."
    summary "| \`$url\` | WARN — $reason |"
    warnings=$((warnings + 1))
  fi
done

summary ""

if [[ "$probed" -eq 0 ]]; then
  echo "substituter preflight: no HTTP substituters configured"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "substituter preflight: $failures unusable binary cache(s); failing now rather than letting Nix build the closure from source."
  exit 1
fi

echo "substituter preflight: $probed probed, $warnings warning(s)"
exit 0
