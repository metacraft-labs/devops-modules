#!/usr/bin/env bash
# Google Workspace DKIM: every step of docs/Google-Workspace-DKIM.md that is not
# an Admin console click, as one tool. The two console clicks (Generate new
# record, Start authentication) stay manual because Google publishes no API for
# them; the tool tells you when to make each one.
#
#   google-workspace-dkim publish  --domain D --data FILE [--selector S] [--post-edit CMD]
#                                  [--base BRANCH] [--merge] [--no-pr] [--value V]
#                                  [--allow-1024] [--replace] [--dns-timeout SECS] [--no-open]
#   google-workspace-dkim check    --domain D [--selector S] [--expect-file FILE]
#   google-workspace-dkim validate [--value V] [--allow-1024]
#
# FILE is the consumer repository's DNS data for the shared Terranix helper
# terraform/cloudflare/mail-auth.nix (its header documents the shape):
#
#   { "version": 1,
#     "domains": { "<domain>": { "zone_id": "<32 hex>", "dkim": { "<selector>": "v=DKIM1; …" } } } }
#
# publish:
#   1. prints the console page and what to click there (and opens it unless
#      --no-open or no browser is available);
#   2. reads the TXT value you paste (or --value): quotes and the DNS
#      multi-string form ("v=DKIM1; k=rsa; " "p=…") are reassembled into one
#      string, then validated — v=DKIM1, k=rsa, p= a base64 DER RSA public key,
#      >= 2048 bits unless --allow-1024;
#   3. sets .domains[D].dkim[S] in FILE with jq — only for a domain FILE already
#      declares (a person adds the domain and its zone id once; the error says how);
#   4. runs --post-edit CMD in the repository root with DOMAIN, SELECTOR,
#      RECORD_NAME (<S>._domainkey.<D>), RECORD_KEY (RECORD_NAME|TXT) and
#      DATA_FILE exported — the consumer's hook for whatever else must change in
#      the same commit (a reviewed plan census, say);
#   5. unless --no-pr: in a temporary git worktree on branch dkim/<D>-<S> from
#      origin/<base> (default: the repository's default branch), commits FILE and
#      exactly the files the hook changed, pushes, opens a PR and watches its
#      checks and every workflow run of its head; with --merge, merges only
#      when all of them passed on the head it watched (--match-head-commit).
#      Your own checkout is never touched;
#   6. once the change is on <base> (merged now, or on an earlier run), waits —
#      bounded by --dns-timeout, default 1800 s, per phase — first until the
#      zone's own nameservers serve exactly the value (the apply has run), then
#      until every public resolver (1.1.1.1 and 8.8.8.8, or
#      $GOOGLE_WORKSPACE_DKIM_RESOLVERS) does. Asking public resolvers earlier
#      would make them cache "no such name" for the zone's SOA minimum;
#   7. tells you to click Start authentication, and how to verify.
#   Re-running is safe: a value already on <base> skips to step 6, an open PR
#   for the branch is resumed rather than duplicated (and refused if it carries
#   a different value, e.g. after the key was regenerated).
#
# check: looks the record up on every resolver, reassembles it, validates the
# key, compares it with FILE's value when --expect-file is given, and prints the
# domain's SPF and DMARC records for context. Non-zero on any mismatch.
#
# validate: step 2 alone, for a value in hand.
set -euo pipefail

prog=google-workspace-dkim
console_url="https://admin.google.com/ac/apps/gmail/authenticateemail"

die() {
  echo "$prog: $*" >&2
  exit 1
}
say() { echo "$prog: $*" >&2; }

usage="usage: $prog publish|check|validate ... (see the header of this script)"
cmd="${1:-}"
[ -n "$cmd" ] || die "$usage"
shift

domain="" data="" selector="google" post_edit="" base="" merge=0 no_pr=0
value="" value_given=0 allow_1024=0 replace=0 dns_timeout=1800 no_open=0 expect_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) domain="${2:?--domain needs a value}"; shift 2 ;;
    --data) data="${2:?--data needs a value}"; shift 2 ;;
    --selector) selector="${2:?--selector needs a value}"; shift 2 ;;
    --post-edit) post_edit="${2:?--post-edit needs a value}"; shift 2 ;;
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --merge) merge=1; shift ;;
    --no-pr) no_pr=1; shift ;;
    --value) value="${2?--value needs a value}"; value_given=1; shift 2 ;;
    --allow-1024) allow_1024=1; shift ;;
    --replace) replace=1; shift ;;
    --dns-timeout) dns_timeout="${2:?--dns-timeout needs a value}"; shift 2 ;;
    --no-open) no_open=1; shift ;;
    --expect-file) expect_file="${2:?--expect-file needs a value}"; shift 2 ;;
    -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 ($usage)" ;;
  esac
done

read -r -a resolvers <<<"${GOOGLE_WORKSPACE_DKIM_RESOLVERS:-1.1.1.1 8.8.8.8}"
dns_interval="${GOOGLE_WORKSPACE_DKIM_DNS_INTERVAL:-30}"

[[ $dns_timeout =~ ^[0-9]+$ ]] || die "--dns-timeout must be a number of seconds"
[[ $selector =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] || die "selector \"$selector\" is not a lowercase DNS label"
if [ -n "$domain" ]; then
  domain="${domain,,}"
  [[ $domain =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "\"$domain\" is not a domain name"
fi
record_name="${selector}._domainkey.${domain}"

# ── value parsing ────────────────────────────────────────────────────────────

# Concatenate the "…" character-strings of one line, the way a resolver hands
# a TXT record back (dig +short) and the way consoles sometimes show a long
# value. Backslash escapes (\" \\ \DDD) are decoded. Fails if anything but
# whitespace sits outside the quotes, or a quote is left open.
concat_strings() {
  awk '{
    out = ""; n = length($0); inq = 0; bad = 0; i = 1
    while (i <= n) {
      c = substr($0, i, 1)
      if (inq) {
        if (c == "\\") {
          d = substr($0, i + 1, 3)
          if (d ~ /^[0-9][0-9][0-9]$/) { out = out sprintf("%c", d + 0); i += 4; continue }
          out = out substr($0, i + 1, 1); i += 2; continue
        }
        if (c == "\"") { inq = 0; i++; continue }
        out = out c; i++; continue
      }
      if (c == "\"") { inq = 1; i++; continue }
      if (c != " " && c != "\t") bad = 1
      i++
    }
    if (inq || bad) exit 3
    print out
  }'
}

# One value from what an operator pasted: CRs dropped, lines joined, outer
# whitespace trimmed; a quoted form is reassembled with concat_strings.
normalize_value() {
  local raw="$1" v
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ $raw == *'"'* ]]; then
    v="$(printf '%s\n' "$raw" | concat_strings)" ||
      die "could not reassemble the quoted value: text outside the quotes, or an unclosed quote"
  else
    v="$raw"
  fi
  printf '%s' "$v"
}

# Validate a DKIM value; sets key_bits. Messages name the first thing wrong.
key_bits=""
validate_value() {
  local v="$1" t k="" p="" seen_k=0 bits der
  [ -n "$v" ] || die "empty value"
  [[ $v == "v=DKIM1;"* ]] || die "the value must start with \"v=DKIM1;\" (got: ${v:0:30}…)"
  [[ $v =~ ^[A-Za-z0-9=\;+/\ ._-]*$ ]] ||
    die "the value holds a character outside the DKIM tag alphabet (letters, digits, =;+/ ._-)"
  local IFS=';'
  local -a tags
  read -r -a tags <<<"$v"
  unset IFS
  for t in "${tags[@]}"; do
    t="${t#"${t%%[! ]*}"}"
    t="${t%"${t##*[! ]}"}"
    case "$t" in
      k=*) k="${t#k=}"; seen_k=1 ;;
      p=*) p="${t#p=}" ;;
    esac
  done
  [ "$seen_k" = 1 ] && [ "$k" = rsa ] || die "the value must carry k=rsa (got k=${k:-<absent>})"
  p="${p// /}"
  [ -n "$p" ] || die "the value has an empty p= (a revoked key), nothing to publish"
  der="$(mktemp)"
  if ! printf '%s' "$p" | base64 -d >"$der" 2>/dev/null; then
    rm -f "$der"
    die "p= is not valid base64"
  fi
  bits="$(openssl rsa -pubin -inform DER -in "$der" -noout -text 2>/dev/null |
    sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' | head -n1)" || true
  rm -f "$der"
  [ -n "$bits" ] || die "p= does not decode to an RSA public key"
  if [ "$bits" -lt 1024 ]; then
    die "the key is $bits bits; refusing anything under 1024"
  elif [ "$bits" -lt 2048 ] && [ "$allow_1024" != 1 ]; then
    die "the key is $bits bits; generate a 2048-bit record (pass --allow-1024 only if the DNS host cannot hold a long TXT value)"
  fi
  key_bits="$bits"
}

read_value() {
  if [ "$value_given" = 1 ]; then
    normalize_value "$value"
    return
  fi
  local line acc=""
  echo "Paste the TXT record value, then press Enter on an empty line:" >&2
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    [ -z "${line//[[:space:]]/}" ] && [ -n "$acc" ] && break
    acc+="$line"
  done
  normalize_value "$acc"
}

# ── DNS ──────────────────────────────────────────────────────────────────────

# Every TXT record at $1 on resolver $2, one reassembled value per line.
lookup_txt() {
  local name="$1" resolver="$2" out line
  out="$(dig +short +time=5 +tries=2 ${dig_extra:+"$dig_extra"} TXT "$name" "@$resolver" 2>/dev/null)" || return 2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ $line == '"'* ]] || continue # a CNAME target or a comment line
    printf '%s\n' "$line" | concat_strings || return 2
  done <<<"$out"
}

dig_extra=""

# 0 when every server in the remaining arguments answers exactly one TXT
# record at $1 equal to $2.
dns_matches() {
  local name="$1" want="$2" r got
  shift 2
  for r in "$@"; do
    got="$(lookup_txt "$name" "$r")" || return 1
    [ "$got" = "$want" ] || return 1
  done
}

# The nameservers of the zone holding $1: the NS set of the closest enclosing
# name that has one, looked up through the first resolver. Empty if none.
authoritative_servers() {
  local n="$1" ns
  while [[ $n == *.* ]]; do
    ns="$(dig +short +time=5 +tries=2 NS "$n" "@${resolvers[0]}" 2>/dev/null | sed -n 's/\.$//; /^[A-Za-z0-9.-]*$/p' | sort -u)" || ns=""
    if [ -n "$ns" ]; then
      printf '%s\n' "$ns"
      return 0
    fi
    n="${n#*.}"
  done
}

# Two phases. Public resolvers cache a negative answer for the zone's SOA
# minimum (1800 s on Cloudflare), so asking them before the record exists would
# make them keep answering "no such name" for that long after the apply lands.
# Phase 1 therefore asks the zone's own nameservers, non-recursively, until they
# serve the value — that is the CI apply having run. Only then are the public
# resolvers asked. Each phase is bounded by --dns-timeout.
wait_for_dns() {
  local name="$1" want="$2" ns=()
  mapfile -t ns < <(authoritative_servers "$domain")
  if [ "${#ns[@]}" -gt 0 ]; then
    dig_extra="+norecurse" poll_dns "$name" "$want" "the zone's nameservers (the apply has run)" "${ns[@]}"
  else
    say "could not find the nameservers of $domain; asking the public resolvers directly"
  fi
  poll_dns "$name" "$want" "the public resolvers" "${resolvers[@]}"
}

poll_dns() {
  local name="$1" want="$2" what="$3" start now r got
  shift 3
  start="$(date +%s)"
  say "waiting up to ${dns_timeout}s for $name to resolve to the value on $what: $*"
  while :; do
    if dns_matches "$name" "$want" "$@"; then
      say "$name resolves to the published value on every one of $what"
      return 0
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "$dns_timeout" ]; then
      for r in "$@"; do
        got="$(lookup_txt "$name" "$r" || true)"
        say "  @$r answers: ${got:-<nothing>}"
      done
      die "$name did not resolve to the value on $what within ${dns_timeout}s (if the nameservers lag, check the Terraform apply run on the base branch; if only public resolvers lag, a cached negative answer expires within the zone's SOA minimum). Re-run to keep waiting, or '$prog check --domain $domain --selector $selector' to see what is published"
    fi
    for r in "$@"; do
      got="$(lookup_txt "$name" "$r" || true)"
      if [ -z "$got" ]; then
        say "  [$((now - start))s] @$r: no TXT record yet"
      else
        say "  [$((now - start))s] @$r: a different value (${got:0:40}…)"
      fi
    done
    sleep "$dns_interval"
  done
}

# ── data file ────────────────────────────────────────────────────────────────

# Exits with instructions unless FILE ($1) declares $domain.
require_declared() {
  local f="$1"
  jq -e '.version == 1' "$f" >/dev/null 2>&1 || die "$f is not a version-1 mail-auth data file (expected \"version\": 1)"
  if ! jq -e --arg d "$domain" '.domains[$d].zone_id | type == "string"' "$f" >/dev/null; then
    cat >&2 <<EOF
$prog: $domain is not declared in $f.
  Declare the domain and the Cloudflare zone that holds it first, in its own
  reviewed change (the zone id is on the zone's Overview page in the dashboard):

    jq --arg d $domain --arg z <ZONE_ID> \\
      '.domains[\$d] = {zone_id: \$z, dkim: {}}' $f > $f.new && mv $f.new $f

  then re-run this command.
EOF
    exit 1
  fi
}

# Prints "same", "absent" or "different" for FILE ($1) against $2.
compare_data() {
  jq -r --arg d "$domain" --arg s "$selector" --arg v "$2" '
    (.domains[$d].dkim // {})[$s] as $cur
    | if $cur == null then "absent" elif $cur == $v then "same" else "different" end' "$1"
}

set_value() {
  local f="$1" v="$2" tmp
  tmp="$(mktemp "$f.XXXXXX")"
  jq --indent 2 --arg d "$domain" --arg s "$selector" --arg v "$v" \
    '.domains[$d].dkim = ((.domains[$d].dkim // {}) + {($s): $v})' "$f" >"$tmp"
  chmod --reference="$f" "$tmp" 2>/dev/null || true
  mv "$tmp" "$f"
}

# Writes the value into FILE ($1) and runs the hook in repo root $2.
# Returns 0 when it changed something, 3 when the value was already there.
apply_edit() {
  local f="$1" root="$2" v="$3" state
  require_declared "$f"
  state="$(compare_data "$f" "$v")"
  case "$state" in
    same)
      say "$record_name already holds this value in $f; nothing to edit"
      return 3
      ;;
    different)
      [ "$replace" = 1 ] || die "$f already holds a DIFFERENT value for $record_name. To rotate, use a new selector (--selector google$(date +%Y)) and publish it alongside; pass --replace only to overwrite this one deliberately"
      ;;
  esac
  set_value "$f" "$v"
  say "set .domains[\"$domain\"].dkim[\"$selector\"] in $f"
  if [ -n "$post_edit" ]; then
    say "running the post-edit hook: $post_edit"
    (cd "$root" && DOMAIN="$domain" SELECTOR="$selector" RECORD_NAME="$record_name" \
      RECORD_KEY="$record_name|TXT" DATA_FILE="$f" bash -c "$post_edit") ||
      die "the post-edit hook failed"
  fi
}

# ── console prompts ──────────────────────────────────────────────────────────

open_url() {
  [ "$no_open" = 1 ] && return 0
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 || true
  elif [ "$(uname -s)" = Darwin ] && command -v open >/dev/null 2>&1; then
    open "$1" >/dev/null 2>&1 || true
  fi
}

finish_message() {
  cat >&2 <<EOF

$prog: the record is live. Last console step:
  $console_url
  Select $domain, click "Start authentication". The status should read
  "Authenticating email with DKIM".
Then verify:
  $prog check --domain $domain --selector $selector${data:+ --expect-file $data}
  and send a message from $domain to an external mailbox: its headers must show
  DKIM-Signature d=$domain s=$selector and Authentication-Results dkim=pass header.d=$domain.
EOF
}

# ── subcommands ──────────────────────────────────────────────────────────────

cmd_validate() {
  local v
  v="$(read_value)"
  validate_value "$v"
  say "valid: v=DKIM1, k=rsa, $key_bits-bit RSA key, ${#v} characters"
  printf '%s\n' "$v"
}

cmd_check() {
  [ -n "$domain" ] || die "--domain is required"
  local r got first="" status=0 n want="" spf dmarc
  if [ -n "$expect_file" ]; then
    [ -r "$expect_file" ] || die "cannot read $expect_file"
    want="$(jq -r --arg d "$domain" --arg s "$selector" '(.domains[$d].dkim // {})[$s] // empty' "$expect_file")"
    [ -n "$want" ] || { say "FAIL: $expect_file holds no value for $record_name"; status=1; }
  fi
  for r in "${resolvers[@]}"; do
    if ! got="$(lookup_txt "$record_name" "$r")"; then
      say "FAIL: @$r: lookup of $record_name failed"
      status=1
      continue
    fi
    n="$(printf '%s' "$got" | grep -c . || true)"
    if [ "$n" = 0 ]; then
      say "FAIL: @$r: no TXT record at $record_name"
      status=1
      continue
    elif [ "$n" != 1 ]; then
      say "FAIL: @$r: $n TXT records at $record_name (a selector must hold exactly one)"
      status=1
      continue
    fi
    echo "$record_name @$r: $got"
    if [ -z "$first" ]; then
      first="$got"
    elif [ "$got" != "$first" ]; then
      say "FAIL: @$r answers differently from @${resolvers[0]} (propagation still under way?)"
      status=1
    fi
    if [ -n "$want" ] && [ "$got" != "$want" ]; then
      say "FAIL: @$r: the published value differs from $expect_file"
      status=1
    fi
  done
  if [ -n "$first" ]; then
    local bits
    if bits="$(allow_1024=1 && validate_value "$first" && echo "$key_bits")"; then
      say "key: $bits-bit RSA$([ "$bits" -lt 2048 ] && echo ' (under 2048: regenerate at 2048 and rotate)')"
    else
      status=1
    fi
  fi
  [ -n "$want" ] && [ "$status" = 0 ] && say "the published value matches $expect_file exactly"
  spf="$(lookup_txt "$domain" "${resolvers[0]}" | grep '^v=spf1' || true)"
  dmarc="$(lookup_txt "_dmarc.$domain" "${resolvers[0]}" | grep '^v=DMARC1' || true)"
  echo "SPF   $domain: ${spf:-<none>}"
  echo "DMARC _dmarc.$domain: ${dmarc:-<none>}"
  if [ "$status" = 0 ]; then say "OK: $record_name"; else say "check FAILED for $record_name"; fi
  return "$status"
}

cmd_publish() {
  [ -n "$domain" ] || die "--domain is required"
  [ -n "$data" ] || die "--data is required (the mail-auth JSON data file)"
  [ -f "$data" ] || die "no such data file: $data"
  local data_abs root rel v
  data_abs="$(cd "$(dirname "$data")" && pwd)/$(basename "$data")"
  if root="$(git -C "$(dirname "$data_abs")" rev-parse --show-toplevel 2>/dev/null)"; then
    :
  elif [ "$no_pr" = 1 ]; then
    root="$(dirname "$data_abs")"
  else
    die "$data is not inside a git repository (use --no-pr to only edit the file)"
  fi
  rel="${data_abs#"$root"/}"

  # Fail before the console step on what can be checked now.
  require_declared "$data_abs"

  cat >&2 <<EOF
$prog: publishing Google Workspace DKIM for $domain, selector "$selector".
  1. You generate the key in the Admin console (below).
  2. This tool validates it and sets it in $rel$( [ -n "$post_edit" ] && printf ', then runs %s' "$post_edit").
$( if [ "$no_pr" = 1 ]; then echo "  3. (--no-pr) It stops there: commit and open the PR yourself."; else
  echo "  3. It commits that on branch dkim/$domain-$selector, opens a PR and watches its checks$( [ "$merge" = 1 ] && echo ', merges it when they pass')."
  echo "  4. It waits until $record_name resolves publicly, then tells you to Start authentication."; fi )

Admin console: $console_url
  - Selected domain: $domain
  - Generate new record: DKIM key bit length 2048, prefix selector "$selector"
  - Copy the TXT record value (a public key: pasting it here is fine).
  - Do NOT click "Start authentication" yet.
EOF
  [ "$value_given" = 1 ] || open_url "$console_url"
  v="$(read_value)"
  validate_value "$v"
  say "valid: $key_bits-bit RSA key, ${#v} characters"

  if [ "$no_pr" = 1 ]; then
    local rc=0
    apply_edit "$data_abs" "$root" "$v" || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 3 ] || exit "$rc"
    say "(--no-pr) edited in place; review with 'git -C $root diff', commit and open a PR, and after it is applied run:"
    say "  $prog check --domain $domain --selector $selector --expect-file $data"
    return 0
  fi

  publish_pr "$root" "$rel" "$v"
  wait_for_dns "$record_name" "$v"
  finish_message
}

# Branch, commit, push, PR, checks, merge. Returns once the value is on <base>,
# or exits when it is not going to be (no --merge, or a check failed).
publish_pr() {
  local root="$1" rel="$2" v="$3" branch pr wt before after paths=() p head state
  command -v gh >/dev/null || die "gh is required for the PR flow (or pass --no-pr)"
  branch="dkim/$domain-$selector"
  if [ -z "$base" ]; then
    base="$(cd "$root" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name)" ||
      die "could not determine the default branch; pass --base"
  fi
  say "fetching origin/$base"
  git -C "$root" fetch --quiet origin "$base"

  if git -C "$root" show "origin/$base:$rel" >/dev/null 2>&1 &&
    [ "$(git -C "$root" show "origin/$base:$rel" | compare_data /dev/stdin "$v")" = same ]; then
    say "origin/$base already publishes this value for $record_name; skipping to the DNS wait"
    return 0
  fi

  pr="$(cd "$root" && gh pr list --head "$branch" --base "$base" --state open --json number -q '.[0].number // empty')"
  if [ -n "$pr" ]; then
    # Regenerating in the console replaces the pending key, so an open PR may
    # carry an older value than the one just pasted. Merging that would publish
    # a key Google no longer signs with.
    git -C "$root" fetch --quiet origin "$branch" ||
      die "PR #$pr is open but origin/$branch could not be fetched"
    [ "$(git -C "$root" show "FETCH_HEAD:$rel" | compare_data /dev/stdin "$v")" = same ] ||
      die "PR #$pr ($branch) carries a different value for $record_name than the one you pasted (was the key regenerated?). Close it and delete the branch, then re-run"
    say "PR #$pr for $branch is already open with this value; resuming it"
  else
    wt="$(mktemp -d "${TMPDIR:-/tmp}/$prog.XXXXXX")"
    trap 'git -C "'"$root"'" worktree remove --force "'"$wt"'" >/dev/null 2>&1 || true; rm -rf "'"$wt"'"' EXIT
    git -C "$root" worktree add --quiet -B "$branch" "$wt" "origin/$base"
    before="$(git -C "$wt" status --porcelain=v1 --untracked-files=all)"
    local rc=0
    apply_edit "$wt/$rel" "$wt" "$v" || rc=$?
    [ "$rc" = 0 ] || die "nothing to commit on $branch (the value is already there)"
    after="$(git -C "$wt" status --porcelain=v1 --untracked-files=all)"
    # Stage the data file and exactly the paths the hook changed.
    paths=("$rel")
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      p="${p:3}"
      p="${p##* -> }"
      [ "$p" = "$rel" ] || paths+=("$p")
    done < <(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort))
    say "staging: ${paths[*]}"
    git -C "$wt" add -- "${paths[@]}"
    local msg="dkim: publish $record_name

Google Workspace DKIM key for $domain ($key_bits-bit RSA, selector $selector),
generated in the Admin console and published by google-workspace-dkim."
    if ! git -C "$wt" commit --quiet -m "$msg"; then
      # A formatting hook may have rewritten the staged files; take its result once.
      say "the commit hooks changed files; re-staging and committing again"
      git -C "$wt" add -- "${paths[@]}"
      git -C "$wt" commit --quiet -m "$msg" || die "commit failed in $wt"
    fi
    git -C "$wt" push --quiet --force-with-lease -u origin "$branch"
    pr="$(cd "$wt" && gh pr create --base "$base" --head "$branch" \
      --title "dkim: publish $record_name" \
      --body "Publishes the Google Workspace DKIM public key for \`$domain\` (selector \`$selector\`, $key_bits-bit RSA) at \`$record_name\`.

Generated in the Admin console and validated by \`google-workspace-dkim publish\`. After this is applied and the record resolves, an admin clicks **Start authentication** for $domain.")"
    say "opened $pr"
    pr="${pr##*/}"
  fi

  # The head is fixed before watching, so the merge below can only land the
  # commit whose checks were watched.
  head="$(cd "$root" && gh pr view "$pr" --json headRefOid -q .headRefOid)"
  [ -n "$head" ] || die "could not read the head commit of PR #$pr"
  watch_checks "$root" "$pr" "$head"
  if [ "$merge" != 1 ]; then
    say "checks passed on PR #$pr. Merge it, then re-run this command: it will skip to the DNS wait."
    exit 0
  fi
  state="$(cd "$root" && gh pr checks "$pr" --json bucket -q '[.[].bucket] | map(select(. != "pass" and . != "skipping")) | length')"
  [ "$state" = 0 ] || die "PR #$pr has checks that did not pass; not merging"
  say "merging PR #$pr at ${head:0:12}"
  (cd "$root" && gh pr merge "$pr" --merge --match-head-commit "$head") ||
    die "gh pr merge refused (review required, or the head moved); merge PR #$pr by hand and re-run"
}

# Summarises the GitHub Actions workflow runs for commit $2: "ok" when every
# run completed as success/skipped/neutral (or there are none), "bad" when one
# concluded otherwise, "pending" while any is still running.
runs_state() {
  (cd "$1" && gh run list --commit "$2" --limit 200 --json status,conclusion -q '
    [.[] | if .status != "completed" then "pending"
           elif (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral") then "ok"
           else "bad" end]
    | if any(. == "bad") then "bad" elif any(. == "pending") then "pending" else "ok" end')
}

# Returns once every check of PR $2 passed and every workflow run for its head
# $3 completed successfully; exits otherwise. `gh pr checks --watch` alone is
# not enough: a job that `needs:` another, or a matrix computed by one, only
# registers its check once that job finishes, so the watch can see "all passed"
# while part of the pipeline does not exist yet. A workflow run stays
# in_progress until all of its jobs have finished, so it closes that window.
watch_checks() {
  local root="$1" pr="$2" head="$3" tries=0 rounds=0 out rc runs
  say "watching the checks of PR #$pr at ${head:0:12}"
  while :; do
    rc=0
    out="$(cd "$root" && gh pr checks "$pr" --watch --interval 20 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then
      runs="$(runs_state "$root" "$head")" || die "could not list the workflow runs of ${head:0:12}"
      case "$runs" in
        ok)
          say "all checks passed on PR #$pr, and every workflow run for ${head:0:12} completed"
          return 0
          ;;
        bad) die "PR #$pr: a workflow run for ${head:0:12} did not succeed; fix it and re-run (the open PR is resumed)" ;;
        *)
          rounds=$((rounds + 1))
          [ "$rounds" -le 180 ] || die "PR #$pr: workflow runs for ${head:0:12} still running after the checks passed; re-run to keep waiting"
          say "the reported checks passed but workflow runs for ${head:0:12} are still running; watching again"
          sleep "${GOOGLE_WORKSPACE_DKIM_CHECK_INTERVAL:-20}"
          continue
          ;;
      esac
    fi
    if [[ $out == *"no checks reported"* ]] && [ "$tries" -lt 30 ]; then
      tries=$((tries + 1))
      sleep 10
      continue
    fi
    printf '%s\n' "$out" >&2
    die "PR #$pr: checks did not pass; fix it and re-run (the open PR is resumed)"
  done
}

case "$cmd" in
  publish) cmd_publish ;;
  check) cmd_check ;;
  validate) cmd_validate ;;
  *) die "$usage" ;;
esac
