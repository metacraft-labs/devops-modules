#!/usr/bin/env bash
# Mint, inspect and report on an org's DEVELOPMENT certificate set.
#
# This is the "minting tooling" row of
# metacraft-dev-guidelines/policies/environment-domains-and-dev-certificates.md
# §4, and it lives here rather than in a consumer `infra` repo for the reason
# that section gives: the scheme is shared by metacraft-labs, agent-harbor and
# blocksense, and *each org runs its own root CA under the same scheme*. So the
# tool is parametric over root, domains and validity, and names no org.
#
# Everything it needs comes from ONE spec file -- the JSON projection of the
# consumer repo's `lib/dev-certificates.nix`:
#
#   nix eval --json --file lib/dev-certificates.nix > spec.json
#
# ## The guard that matters
#
# `init-root` and `mint` REFUSE a name that is not under a reserved TLD
# (RFC 6761 `.localhost` / `.test`). A private root that can issue for
# `codetracer.com` is a private root that can impersonate production to anyone
# who trusts it -- and every workstation in the org trusts this one. The spec
# file is edited by hand, so the refusal is here, where the key is, rather than
# left to review.
#
# ## Subcommands
#
#   init-root --spec S --key-out K --cert-out C
#       Generate the root key + self-signed root certificate. REFUSES to
#       overwrite either output: a re-minted root silently invalidates every
#       leaf and every machine's trust store at once.
#
#   mint --spec S --root-key K --root-cert C --key-out-dir KD --cert-out-dir CD
#       Issue one leaf per spec row. Keys land at KD/<id>.key.pem (to be
#       agenix-sealed by the caller), certificates at CD/<id>/fullchain.pem
#       (committed in the clear). Idempotent in the sense that it always
#       re-issues; it does not try to preserve an existing leaf, because a
#       re-mint is the renewal path.
#
#   report --spec S --cert-dir CD [--fail-below DAYS]
#       §4.1: print remaining validity for every leaf and EXIT NON-ZERO below
#       the threshold. Defaults to the spec's `leafExpiryFailBelowDays`.
#       A missing leaf is a failure, not a skip.
#
# ## What it deliberately does not do
#
# It does not seal anything and does not call agenix. Sealing needs the
# consumer repo's recipient set, which is a nix evaluation of THAT repo; mixing
# the two would make this tool need a flake it cannot see. The caller seals.
set -euo pipefail

PROG="${0##*/}"

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'
  exit "${1:-0}"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH"
}

need openssl
need jq

# ---------------------------------------------------------------------------
# Spec reading
# ---------------------------------------------------------------------------

spec_get() {
  # spec_get <file> <jq-filter>
  jq -er "$2" <"$1" 2>/dev/null || die "spec $1 has no $2"
}

# Reserved-TLD guard. RFC 6761 reserves `localhost` (§6.3) and `test` (§6.2);
# `.local` is RFC 6762 mDNS and is NOT accepted -- the policy's §2 rules it out
# by name, so accepting it here would let a spec edit route around that.
assert_reserved_tld() {
  # Two statements, not `local name="$1" bare="$name"`: bash expands every word
  # of `local` BEFORE performing any of its assignments, so the second would
  # read the enclosing scope's `name` -- empty -- and every name would fall
  # through the case below to the refusal. That is how this guard first failed.
  local name="$1"
  local bare="${name#\*.}"
  case "$bare" in
  *.localhost | localhost) return 0 ;;
  *.test | test) return 0 ;;
  esac
  die "refusing to issue for '$name': only names under the reserved TLDs .localhost and .test may take a private development leaf. A publicly resolvable name (scheme B, e.g. localhost-ide.codetracer.com) takes a PUBLIC certificate -- see environment-domains-and-dev-certificates.md section 3."
}

# Emit "<id>\t<name>,<name>,..." per row, having checked every invariant.
rows_of() {
  local spec="$1" n i id first derived names
  n="$(spec_get "$spec" '.domains | length')"
  [ "$n" -gt 0 ] || die "spec $spec declares no domains"
  local -a seen=()
  for ((i = 0; i < n; i++)); do
    id="$(spec_get "$spec" ".domains[$i].id")"
    names="$(jq -er ".domains[$i].names | join(\",\")" <"$spec")" ||
      die "spec row $i has no names"
    [ -n "$names" ] || die "spec row $i ($id) has an empty name list"
    first="${names%%,*}"
    derived="${first#\*.}"
    [ "$id" = "$derived" ] ||
      die "spec row $i declares id '$id' but names[0] is '$first', which derives '$derived'. The id IS names[0] without a leading '*.' -- fix whichever is wrong."
    # Duplicate ids would have two rows writing one directory, last one wins.
    local s
    for s in ${seen[@]+"${seen[@]}"}; do
      [ "$s" != "$id" ] || die "spec declares id '$id' twice; each row installs into its own directory, so two rows cannot share one"
    done
    seen+=("$id")
    local nm one
    IFS=, read -r -a nm <<<"$names"
    for one in "${nm[@]}"; do assert_reserved_tld "$one"; done
    printf '%s\t%s\n' "$id" "$names"
  done
}

# ---------------------------------------------------------------------------
# init-root
# ---------------------------------------------------------------------------

cmd_init_root() {
  local spec="" key_out="" cert_out=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --spec)
      spec="$2"
      shift 2
      ;;
    --key-out)
      key_out="$2"
      shift 2
      ;;
    --cert-out)
      cert_out="$2"
      shift 2
      ;;
    -h | --help) usage 0 ;;
    *) die "init-root: unknown argument '$1'" ;;
    esac
  done
  [ -n "$spec" ] && [ -n "$key_out" ] && [ -n "$cert_out" ] ||
    die "init-root needs --spec, --key-out and --cert-out"
  [ -r "$spec" ] || die "cannot read spec $spec"

  # Validate the whole spec before touching a key, so a bad row cannot leave a
  # root behind that the next run then refuses to replace.
  rows_of "$spec" >/dev/null

  for f in "$key_out" "$cert_out"; do
    [ ! -e "$f" ] || die "$f already exists. Re-minting the root invalidates every issued leaf and every machine's trust store at the same moment, so this is never an overwrite -- move the old root aside deliberately if that is what you mean."
  done

  local bits days cn
  bits="$(spec_get "$spec" '.rootKeyBits')"
  days="$(spec_get "$spec" '.rootValidityDays')"
  cn="$(spec_get "$spec" '.rootCommonName')"

  mkdir -p "$(dirname "$key_out")" "$(dirname "$cert_out")"

  # umask before generation, not chmod after: a 4096-bit RSA keygen takes long
  # enough that a world-readable window is a real one.
  (
    umask 077
    openssl genrsa -out "$key_out" "$bits" 2>/dev/null
  )

  # basicConstraints CA:true with pathlen:0 -- this root signs leaves directly
  # and must not be able to mint an intermediate.
  openssl req -x509 -new -key "$key_out" -sha256 -days "$days" \
    -subj "/CN=$cn" \
    -addext "basicConstraints=critical,CA:true,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$cert_out"

  printf 'root key  %s (RSA-%s, mode %s)\n' "$key_out" "$bits" \
    "$(stat -c '%a' "$key_out" 2>/dev/null || stat -f '%Lp' "$key_out")"
  printf 'root cert %s (%s days, CN=%s)\n' "$cert_out" "$days" "$cn"
}

# ---------------------------------------------------------------------------
# mint
# ---------------------------------------------------------------------------

cmd_mint() {
  local spec="" root_key="" root_cert="" key_dir="" cert_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --spec)
      spec="$2"
      shift 2
      ;;
    --root-key)
      root_key="$2"
      shift 2
      ;;
    --root-cert)
      root_cert="$2"
      shift 2
      ;;
    --key-out-dir)
      key_dir="$2"
      shift 2
      ;;
    --cert-out-dir)
      cert_dir="$2"
      shift 2
      ;;
    -h | --help) usage 0 ;;
    *) die "mint: unknown argument '$1'" ;;
    esac
  done
  [ -n "$spec" ] && [ -n "$root_key" ] && [ -n "$root_cert" ] &&
    [ -n "$key_dir" ] && [ -n "$cert_dir" ] ||
    die "mint needs --spec, --root-key, --root-cert, --key-out-dir and --cert-out-dir"
  [ -r "$spec" ] || die "cannot read spec $spec"
  [ -r "$root_key" ] || die "cannot read root key $root_key (is it still agenix-sealed?)"
  [ -r "$root_cert" ] || die "cannot read root cert $root_cert"

  local days
  days="$(spec_get "$spec" '.leafValidityDays')"

  local rows
  rows="$(rows_of "$spec")"

  mkdir -p "$key_dir" "$cert_dir"

  # NOT `local`: the EXIT trap fires after this function has returned, so a
  # function-scoped variable is already out of scope by then and `set -u` turns
  # the cleanup into `tmp: unbound variable` -- which is how this first failed,
  # after a successful mint.
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  local tmp="$WORKDIR"

  local id names count=0
  while IFS=$'\t' read -r id names; do
    [ -n "$id" ] || continue
    local -a nm
    IFS=, read -r -a nm <<<"$names"

    local san="" one
    for one in "${nm[@]}"; do
      san="${san:+$san,}DNS:$one"
    done

    local key="$key_dir/$id.key.pem"
    local certdir="$cert_dir/$id"
    mkdir -p "$certdir"

    (
      umask 077
      openssl genrsa -out "$tmp/leaf.key" 2048 2>/dev/null
    )

    # The CN is names[0] (wildcard included if that is what the row leads with).
    # Modern clients ignore CN entirely and read subjectAltName; it is set for
    # the benefit of whatever old tool still prints it.
    openssl req -new -key "$tmp/leaf.key" -subj "/CN=${nm[0]}" -out "$tmp/leaf.csr"

    cat >"$tmp/ext" <<EOF
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san
EOF

    openssl x509 -req -in "$tmp/leaf.csr" \
      -CA "$root_cert" -CAkey "$root_key" -CAcreateserial \
      -CAserial "$tmp/serial" \
      -days "$days" -sha256 -extfile "$tmp/ext" \
      -out "$tmp/leaf.crt" 2>/dev/null

    # fullchain = leaf then root, the order every server implementation wants.
    # Verify before publishing. A leaf that does not chain to the root it was
    # just signed by is a mint that produced a file instead of a certificate,
    # and the next thing to notice would be a browser, on someone else's
    # machine, a week later.
    openssl verify -CAfile "$root_cert" "$tmp/leaf.crt" >/dev/null ||
      die "the leaf just issued for $id does not verify against $root_cert"
    # And it must actually carry every name the row asked for -- an openssl
    # extfile typo yields a valid certificate for the wrong set of names.
    local have one2
    have="$(openssl x509 -in "$tmp/leaf.crt" -noout -ext subjectAltName)"
    for one2 in "${nm[@]}"; do
      case "$have" in
      *"DNS:$one2"*) ;;
      *) die "the leaf just issued for $id is missing subjectAltName DNS:$one2" ;;
      esac
    done

    cat "$tmp/leaf.crt" "$root_cert" >"$certdir/fullchain.pem"
    (
      umask 077
      cp "$tmp/leaf.key" "$key"
    )
    chmod 600 "$key"

    printf '%-34s %s\n' "$id" "$(printf '%s' "$names" | tr ',' ' ')"
    count=$((count + 1))
  done <<<"$rows"

  printf '\nminted %d leaf certificate(s), %s days each\n' "$count" "$days"
  printf 'keys in   %s   (SEAL THESE -- they are secrets)\n' "$key_dir"
  printf 'certs in  %s   (commit in the clear)\n' "$cert_dir"
}

# ---------------------------------------------------------------------------
# report  (policy section 4.1)
# ---------------------------------------------------------------------------

# Remaining whole days until a certificate's notAfter. Prints a possibly
# negative integer.
days_left() {
  local cert="$1" end epoch now
  end="$(openssl x509 -in "$cert" -noout -enddate)" || return 1
  end="${end#notAfter=}"
  # GNU date and BSD date disagree on everything except -j/-f, so try both.
  epoch="$(date -u -d "$end" +%s 2>/dev/null)" ||
    epoch="$(date -u -j -f '%b %d %T %Y %Z' "$end" +%s 2>/dev/null)" ||
    return 1
  now="$(date -u +%s)"
  printf '%d\n' $(((epoch - now) / 86400))
}

cmd_report() {
  local spec="" cert_dir="" fail_below=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --spec)
      spec="$2"
      shift 2
      ;;
    --cert-dir)
      cert_dir="$2"
      shift 2
      ;;
    --fail-below)
      fail_below="$2"
      shift 2
      ;;
    -h | --help) usage 0 ;;
    *) die "report: unknown argument '$1'" ;;
    esac
  done
  [ -n "$spec" ] && [ -n "$cert_dir" ] ||
    die "report needs --spec and --cert-dir"
  [ -r "$spec" ] || die "cannot read spec $spec"

  [ -n "$fail_below" ] || fail_below="$(spec_get "$spec" '.leafExpiryFailBelowDays')"

  local rows bad=0 id names
  rows="$(rows_of "$spec")"

  printf '%-34s %10s  %s\n' DOMAIN 'DAYS LEFT' STATUS
  while IFS=$'\t' read -r id names; do
    [ -n "$id" ] || continue
    local cert="$cert_dir/$id/fullchain.pem"
    if [ ! -r "$cert" ]; then
      printf '%-34s %10s  %s\n' "$id" - 'MISSING (never minted, or not installed)'
      bad=$((bad + 1))
      continue
    fi
    local left
    if ! left="$(days_left "$cert")"; then
      printf '%-34s %10s  %s\n' "$id" '?' 'UNREADABLE (not a certificate?)'
      bad=$((bad + 1))
      continue
    fi
    if [ "$left" -lt 0 ]; then
      printf '%-34s %10s  %s\n' "$id" "$left" 'EXPIRED'
      bad=$((bad + 1))
    elif [ "$left" -lt "$fail_below" ]; then
      printf '%-34s %10s  %s\n' "$id" "$left" "BELOW THRESHOLD ($fail_below)"
      bad=$((bad + 1))
    else
      printf '%-34s %10s  %s\n' "$id" "$left" ok
    fi
  done <<<"$rows"

  if [ "$bad" -gt 0 ]; then
    printf '\n%d leaf certificate(s) need a re-mint. This FAILS rather than warns:\n' "$bad" >&2
    printf 'a wall of green the morning after expiry, with every service refusing TLS,\n' >&2
    printf 'is the outage environment-domains-and-dev-certificates.md section 4.1 exists to prevent.\n' >&2
    exit 1
  fi
  printf '\nall leaves have at least %s days left\n' "$fail_below"
}

# ---------------------------------------------------------------------------

case "${1:-}" in
init-root)
  shift
  cmd_init_root "$@"
  ;;
mint)
  shift
  cmd_mint "$@"
  ;;
report)
  shift
  cmd_report "$@"
  ;;
-h | --help | '') usage 0 ;;
*) die "unknown subcommand '$1' (expected init-root, mint or report)" ;;
esac
