#!/usr/bin/env bash
# probe-substituters.sh — prove every configured binary cache is READABLE
# before the job asks Nix to substitute from it, and stop Nix from waiting on
# the ones that are not.
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
# This probe reads `<substituter>/nix-cache-info` with the SAME netrc file Nix
# is configured to use, so "the credential Nix will send" is what gets tested.
#
# POLICY
#
#   upstream (cache.nixos.org) — must be readable; if it is not, the probe
#                       fails unless mode is `off`.
#   every other cache — mode `fail`: the job fails here.
#                       mode `warn` (default): a `::warning::` annotation that
#                       names the cause, AND the cache is removed from the
#                       `substituters` line of SETUP_NIX_PROBE_NIX_CONF, so no
#                       nix process in the job ever waits on it (an unreachable
#                       cache otherwise costs connect-timeout x download-attempts
#                       per nix invocation). Default is `warn` because many
#                       consumers run on GitHub-hosted runners that cannot reach
#                       a NetBird-gated cache at all.
#   mode `off`        — probe nothing.
#
# Transport failures (DNS, connect, TLS, 5xx) are retried with exponential
# backoff (2, 4, 8, 16 s by default) so a short blip on cache.nixos.org does
# not fail every concurrent job; 401/403/404 are not retried, because a
# missing or refused credential will still be refused later.
#
# PORTABILITY: this runs on runner images whose PATH is minimal — the macOS
# self-hosted runners have curl and coreutils but NO grep/sed/awk. Everything
# except curl, mktemp, head, tr and sleep is bash builtins. The contract suite
# runs it with exactly that PATH.
#
# Inputs (environment):
#   SETUP_NIX_PROBE_SUBSTITUTERS   whitespace-separated substituter URLs
#   SETUP_NIX_PROBE_MODE           fail | warn | off          (default: warn)
#   SETUP_NIX_PROBE_NETRC          netrc file Nix uses        (optional)
#   SETUP_NIX_PROBE_NIX_CONF       nix.conf whose `substituters` line drops
#                                  unusable caches in warn mode (optional)
#   SETUP_NIX_PROBE_ATTEMPTS       transport attempts per cache (default: 5)
#   SETUP_NIX_PROBE_BACKOFF        first backoff in seconds, doubled per
#                                  retry                       (default: 2)
#   SETUP_NIX_PROBE_CONNECT_TIMEOUT seconds, TCP+TLS          (default: 8)
#   SETUP_NIX_PROBE_MAX_TIME       seconds per attempt         (default: 20)
#   SETUP_NIX_PROBE_UPSTREAM       the cache that must always be usable
#                                  (default: https://cache.nixos.org; the
#                                  contract suite points it at a local origin)
#   GITHUB_STEP_SUMMARY            appended to when set
#
# Contract suite: tests/probe-substituters-test.sh.

set -uo pipefail
# Word splitting is used to tokenise netrc and substituter lists; a token such
# as a password containing `*` must never be glob-expanded against the cwd.
set -f

substituters="${SETUP_NIX_PROBE_SUBSTITUTERS:-}"
mode="${SETUP_NIX_PROBE_MODE:-warn}"
netrc="${SETUP_NIX_PROBE_NETRC:-}"
nix_conf="${SETUP_NIX_PROBE_NIX_CONF:-}"
attempts="${SETUP_NIX_PROBE_ATTEMPTS:-5}"
backoff="${SETUP_NIX_PROBE_BACKOFF:-2}"
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

for tool in curl mktemp head tr sleep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::$tool is not on this runner's PATH, so the binary caches cannot be probed. Set substituter-preflight: off to skip the probe knowingly."
    exit 1
  fi
done

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

# Host part of an http(s) URL (no userinfo, no port).
host_of() {
  local authority="${1#*://}"
  authority="${authority%%/*}"
  authority="${authority##*@}"
  printf '%s' "${authority%%:*}"
}

# Whether the netrc file carries a `machine <host>` entry. netrc is a
# whitespace-separated token stream, so tokenise it with bash word splitting
# (no grep/awk: see PORTABILITY). A `default` entry would also match any host.
netrc_has_host() {
  local host="$1" token previous="" content
  [[ -n "$netrc" && -r "$netrc" ]] || return 1
  content="$(<"$netrc")"
  for token in $content; do
    if [[ "$previous" == "machine" && "$token" == "$host" ]]; then
      return 0
    fi
    if [[ "$token" == "default" && "$previous" != "machine" ]]; then
      return 0
    fi
    previous="$token"
  done
  return 1
}

# A nix-cache-info document has a `StoreDir:` line.
is_cache_info() {
  local body
  body="$(<"$1")"
  [[ $'\n'"$body" == *$'\n'StoreDir:* ]]
}

first_bytes() {
  head -c "${2:-300}" "$1" 2>/dev/null | tr '\n\r' '  '
}

body_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$body_file" "$err_file"' EXIT

failures=0
warnings=0
probed=0
unusable=()

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
  delay="$backoff"
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
      echo "substituter preflight: $url attempt $attempt/$attempts: HTTP $status $(first_bytes "$err_file" 200)— retrying in ${delay}s"
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done

  reason=""
  if [[ "$status" == "200" ]]; then
    if is_cache_info "$body_file"; then
      echo "substituter preflight: OK  $url"
      summary "| \`$url\` | OK |"
      continue
    fi
    reason="HTTP 200 but the body is not a nix-cache-info document (a captive portal or a proxy error page?)"
  elif [[ "$status" == "401" ]]; then
    if netrc_has_host "$(host_of "$url")"; then
      reason="HTTP 401: the cache rejected the credential the netrc holds for $(host_of "$url"). The attic token is expired, revoked, or lacks pull permission on this cache."
    else
      reason="HTTP 401: no credential was sent — the netrc Nix uses has no entry for $(host_of "$url"). This is a private cache and no attic-token was passed to setup-nix, so Nix reads it anonymously."
    fi
  elif [[ "$status" == "403" ]]; then
    reason="HTTP 403: refused before (or regardless of) authentication. For an Attic cache behind an nginx network ACL this means the runner's SOURCE ADDRESS is not in the allow-list — e.g. a runner on a bridge subnet that reaches the cache host without NAT. A token cannot fix this; the cache host's ACL (or the runner's egress path) must."
  elif [[ "$status" == "404" ]]; then
    reason="HTTP 404: no nix-cache-info at this URL. The substituter URL is wrong (cache name typo, or the cache was deleted)."
  elif [[ "$status" == "000" ]]; then
    reason="unreachable after $attempts attempt(s): $(first_bytes "$err_file" 300)"
  else
    reason="HTTP $status after $attempts attempt(s)"
  fi

  echo "substituter preflight: FAIL $url — $reason"
  if [[ -s "$body_file" && "$status" != "200" ]]; then
    echo "  response body (first 300 bytes): $(first_bytes "$body_file" 300)"
  fi

  if is_upstream "$url" || [[ "$mode" == "fail" ]]; then
    echo "::error title=Binary cache unusable::$url — $reason Paths only this cache holds would otherwise be BUILT FROM SOURCE."
    summary "| \`$url\` | **FAIL** — $reason |"
    failures=$((failures + 1))
  else
    echo "::warning title=Binary cache unusable::$url — $reason Removed from this job's substituters; every path only it holds will be BUILT FROM SOURCE. Set substituter-preflight: fail to make this fatal."
    summary "| \`$url\` | WARN (removed from substituters) — $reason |"
    warnings=$((warnings + 1))
    unusable+=("$url")
  fi
done

summary ""

if [[ "$failures" -gt 0 ]]; then
  echo "substituter preflight: $failures unusable binary cache(s); failing now rather than letting Nix build the closure from source."
  exit 1
fi

# Warn mode: drop the unusable caches from nix.conf so no nix invocation in
# the job waits connect-timeout x download-attempts on them.
if [[ "${#unusable[@]}" -gt 0 && -n "$nix_conf" ]]; then
  if [[ ! -f "$nix_conf" ]]; then
    echo "::error::SETUP_NIX_PROBE_NIX_CONF=$nix_conf does not exist; cannot remove the unusable substituters."
    exit 1
  fi
  rewritten=""
  changed=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([[:space:]]*substituters[[:space:]]*=)(.*)$ ]]; then
      kept=""
      for sub in ${BASH_REMATCH[2]}; do
        drop=0
        for bad in "${unusable[@]}"; do
          [[ "$(normalise "$sub")" == "$bad" ]] && drop=1
        done
        [[ "$drop" -eq 1 ]] || kept="$kept $sub"
      done
      line="${BASH_REMATCH[1]}$kept"
      changed=1
    fi
    rewritten+="$line"$'\n'
  done <"$nix_conf"
  if [[ "$changed" -eq 1 ]]; then
    printf '%s' "$rewritten" >"$nix_conf"
    echo "substituter preflight: removed from $nix_conf: ${unusable[*]}"
  fi
fi

echo "substituter preflight: $probed probed, $warnings warning(s)"
exit 0
