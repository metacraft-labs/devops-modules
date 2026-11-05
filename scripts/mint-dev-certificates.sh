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
# ### Host rows: the one declared exception (policy §2.1)
#
# A row may carry `"kind"`. Absent (or `"dev"`) it is a Scheme A row and every
# rule above applies unchanged: `.localhost` / `.test` names only, no IP
# addresses, and a `home.arpa` name is refused.
#
# `"kind": "host"` declares a HOME-NETWORK HOST leaf (policy §2.1, and the
# "home-network host leaf" paragraph of §4): a real machine on the operator's
# home network, e.g. the fleet hub `macbook-2012.home.arpa`, that other machines
# reach over HTTPS. Such a row is held to a narrower shape, not a wider one:
#
#   - exactly ONE name, a single DNS label followed by `.home.arpa` (RFC 8375),
#     with no wildcard -- one leaf names one host;
#   - optional `"addresses"`: IPv4 dotted quads, each inside RFC 1918
#     (10/8, 172.16/12, 192.168/16) or RFC 6598 shared space (100.64/10, where
#     the NetBird overlay lives). They become `IP:` subjectAltNames, because a
#     machine away from home reaches the host by its overlay ADDRESS: its
#     NetBird DNS name is public and no private root may sign it.
#
# The tool cannot see infra's inventory, so it cannot check that an address is
# THE host's own; it enforces the ranges and leaves the rest to the infra row,
# which lists only inventory addresses. Public, loopback, IPv6 and malformed
# addresses are refused, and `addresses` on a Scheme A row is refused -- a
# loopback-only leaf that also names a routable address is no longer
# loopback-only. Who may hold a host leaf's KEY (the superadmins and the one
# serving host) is the caller's sealing decision, not this tool's.
#
# ## Subcommands
#
#   init-root --spec S --key-out K --cert-out C
#       Generate the root key + self-signed root certificate. REFUSES to
#       overwrite either output: a re-minted root silently invalidates every
#       leaf and every machine's trust store at once.
#
#   mint --spec S --root-key K --root-cert C --key-out-dir KD --cert-out-dir CD
#       Issue one leaf per spec row (a host row's addresses become IP SANs).
#       Keys land at KD/<id>.key.pem (to be
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
#
# This is the Scheme A guard. A host row's name goes through
# assert_home_host_name instead, and never through here.
assert_reserved_tld() {
  # Two statements, not `local name="$1" bare="$name"`: bash expands every word
  # of `local` BEFORE performing any of its assignments, so the second would
  # read the enclosing scope's `name` -- empty -- and every name would fall
  # through the case below to the refusal. That is how this guard first failed.
  local name="$1"
  local bare="${name#\*.}"
  # A plain DNS name first, and only then the TLD. Without this a name carrying
  # a newline (or a tab) passes the check on its first line and then splits
  # into an extra, UNCHECKED row in the tab-separated stream `mint` reads --
  # e.g. "y.test\nfoo\tevil.com" minted a leaf for evil.com. The character set
  # is spelled out rather than written as a range so no locale can widen it.
  case "$bare" in
  '' | .* | *. | *..* | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-]*)
    die "refusing to issue for '$name': not a DNS name. Only letters, digits, '-' and '.' are allowed, with an optional single leading '*.' wildcard label."
    ;;
  esac
  case "$bare" in
  *.localhost | localhost) return 0 ;;
  *.test | test) return 0 ;;
  esac
  # A home-network name in a Scheme A row is refused like any other non-reserved
  # name, but with a message that names the way to say what was meant: the
  # host exception is DECLARED per row, never inferred from the name, so that
  # a hand edit cannot widen an existing dev row into a routable host leaf.
  case "$bare" in
  *.home.arpa | home.arpa)
    die "refusing to issue for '$name' in a Scheme A (dev) row: a home.arpa name names a real host on the network, not loopback. Declare it as a home-network host row (\"kind\": \"host\", exactly one <host>.home.arpa name) -- see environment-domains-and-dev-certificates.md section 2.1."
    ;;
  esac
  die "refusing to issue for '$name': only names under the reserved TLDs .localhost and .test may take a private development leaf. A publicly resolvable name (scheme B, e.g. localhost-ide.codetracer.com) takes a PUBLIC certificate -- see environment-domains-and-dev-certificates.md section 3."
}

# Host-row name guard (policy §2.1): exactly `<label>.home.arpa`, one label, no
# wildcard. RFC 8375 reserves `home.arpa.` for names that only resolve on a
# home network. One label, because the leaf names ONE host: a deeper name
# (`svc.macbook-2012.home.arpa`) is a namespace, and a wildcard would let the
# key holder impersonate every host on the network.
assert_home_host_name() {
  local name="$1"
  local label
  case "$name" in
  \**)
    die "refusing host row name '$name': a home-network host leaf names exactly one host, so it takes no wildcard (section 2.1)."
    ;;
  *.home.arpa) label="${name%.home.arpa}" ;;
  *)
    die "refusing host row name '$name': a home-network host row takes exactly one <host>.home.arpa name (RFC 8375). Not .local (mDNS, section 2), not a public name (those take a public certificate or none), not .localhost/.test (those are Scheme A rows) -- see environment-domains-and-dev-certificates.md section 2.1."
    ;;
  esac
  # The label: letters, digits and interior hyphens (RFC 1123 §2.1 host-name
  # syntax), spelled out so no locale can widen the set. A '.' here would mean
  # more than one label, which is refused for the reason above.
  case "$label" in
  '' | -* | *- | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-]*)
    die "refusing host row name '$name': the part before .home.arpa must be a single host label (letters, digits and interior '-'), e.g. macbook-2012.home.arpa."
    ;;
  esac
}

# Host-row address guard (policy §2.1 / §4). STRICT IPv4 dotted quad -- four
# decimal octets 0-255, no leading zeros (inet_aton reads "010" as OCTAL 8, so
# "010.0.0.1" would name a different host than it appears to), nothing else --
# and inside private (RFC 1918) or shared (RFC 6598) space. Public, loopback,
# link-local and IPv6 addresses are all refused: the tool cannot see infra's
# inventory, so the ranges are the part of "only the host's own addresses" it
# can enforce where the root key is.
assert_private_ipv4() {
  local addr="$1"
  local dots a b c d o
  case "$addr" in
  '' | *[!0123456789.]*)
    die "refusing address '$addr': not an IPv4 dotted quad. Only IPv4 is accepted (no IPv6, no host names, no other characters) -- see environment-domains-and-dev-certificates.md section 2.1."
    ;;
  esac
  dots="${addr//[0123456789]/}"
  [ "$dots" = "..." ] ||
    die "refusing address '$addr': not an IPv4 dotted quad (it needs exactly four octets)."
  IFS=. read -r a b c d <<<"$addr"
  for o in "$a" "$b" "$c" "$d"; do
    case "$o" in
    0 | [123456789] | [123456789][0123456789] | [123456789][0123456789][0123456789]) ;;
    *)
      die "refusing address '$addr': octet '$o' is not a decimal 0-255 without leading zeros."
      ;;
    esac
    [ "$o" -le 255 ] ||
      die "refusing address '$addr': octet '$o' is greater than 255."
  done
  [ "$a" -eq 10 ] && return 0
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
  die "refusing address '$addr': a home-network host leaf may carry only private (RFC 1918: 10/8, 172.16/12, 192.168/16) or shared (RFC 6598: 100.64/10, the NetBird overlay) IPv4 addresses. Public, loopback and link-local addresses are never signed by the development root -- see environment-domains-and-dev-certificates.md section 2.1."
}

# Emit one line per row, having checked every invariant:
#
#   <id> TAB <kind> TAB <name>,<name>,... TAB <addr>,<addr>,...|-
#
# Every field is built only from values that have passed a guard whose
# character set excludes TAB, NEWLINE and ',' inside an item, so nothing a spec
# says can add a field or a row. The addresses field is LAST and is "-" when
# empty: TAB is IFS whitespace, so `read` collapses consecutive TABs and an
# empty middle field would silently shift the ones after it.
rows_of() {
  local spec="$1" n i id first derived names kind addrs
  n="$(spec_get "$spec" '.domains | length')"
  [ "$n" -gt 0 ] || die "spec $spec declares no domains"
  local -a seen=()
  for ((i = 0; i < n; i++)); do
    id="$(spec_get "$spec" ".domains[$i].id")"
    # Every name must be a plain DNS name AS JQ SEES IT, checked here before it
    # is joined and split -- after that, a newline inside one name has already
    # become a line break in the stream below (see assert_reserved_tld).
    jq -e ".domains[$i].names | all(.[]; type == \"string\" and test(\"\\\\A(\\\\*\\\\.)?[A-Za-z0-9-]+(\\\\.[A-Za-z0-9-]+)*\\\\z\"))" \
      <"$spec" >/dev/null 2>&1 ||
      die "spec row $i ($id) has a name that is not a DNS name. Allowed: letters, digits, '-' and '.', with an optional single leading '*.' wildcard label. Refusing rather than guessing what a name with other characters in it was meant to be."
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

    # The row kind. Absent means a Scheme A ("dev") row, so every spec written
    # before host rows existed means exactly what it meant then. Present, it
    # must be one of the two spelled-out values: an unknown kind is a spec this
    # tool does not understand, and guessing could only widen what it signs.
    kind="$(jq -er ".domains[$i] | if has(\"kind\") then .kind else \"dev\" end | if type == \"string\" then . else error(\"kind\") end" \
      <"$spec" 2>/dev/null)" ||
      die "spec row $i ($id) has a kind that is not a string. Allowed kinds: \"dev\" (the default, Scheme A) and \"host\" (a home-network host, section 2.1)."
    case "$kind" in
    dev | host) ;;
    *) die "spec row $i ($id) has unknown kind '$kind'. Allowed kinds: \"dev\" (the default, Scheme A) and \"host\" (a home-network host, section 2.1)." ;;
    esac

    local nm one
    IFS=, read -r -a nm <<<"$names"
    addrs=""
    if [ "$kind" = dev ]; then
      # A Scheme A leaf names loopback only; an IP SAN would make it name a
      # routable address too. Refused even as an empty list, so the key's
      # presence alone never means anything for a dev row.
      ! jq -e ".domains[$i] | has(\"addresses\")" <"$spec" >/dev/null 2>&1 ||
        die "spec row $i ($id) is a Scheme A (dev) row and carries \"addresses\". Only a home-network host row (\"kind\": \"host\", section 2.1) may carry IP addresses."
      for one in "${nm[@]}"; do assert_reserved_tld "$one"; done
    else
      [ "${#nm[@]}" -eq 1 ] ||
        die "spec row $i ($id) is a home-network host row with ${#nm[@]} names; it takes exactly one <host>.home.arpa name (section 2.1)."
      assert_home_host_name "${nm[0]}"
      if jq -e ".domains[$i] | has(\"addresses\")" <"$spec" >/dev/null 2>&1; then
        # The same rule as for names: every address must be a string of digits
        # and dots AS JQ SEES IT before it is joined, or a newline inside one
        # would already have split it in two by the time bash looks at it.
        jq -e ".domains[$i].addresses | type == \"array\" and all(.[]; type == \"string\" and test(\"\\\\A[0123456789.]+\\\\z\"))" \
          <"$spec" >/dev/null 2>&1 ||
          die "spec row $i ($id) has \"addresses\" that is not a list of IPv4 dotted-quad strings. Only IPv4 is accepted (no IPv6, no host names, no other characters) -- see environment-domains-and-dev-certificates.md section 2.1."
        addrs="$(jq -er ".domains[$i].addresses | join(\",\")" <"$spec")" ||
          die "spec row $i ($id) has unreadable addresses"
        if [ -n "$addrs" ]; then
          local -a ips
          IFS=, read -r -a ips <<<"$addrs"
          for one in "${ips[@]}"; do assert_private_ipv4 "$one"; done
        fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$id" "$kind" "$names" "${addrs:--}"
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

  local id kind names addrs count=0
  while IFS=$'\t' read -r id kind names addrs; do
    [ -n "$id" ] || continue
    local -a nm ips=()
    IFS=, read -r -a nm <<<"$names"
    # "-" is rows_of's placeholder for "no addresses"; only a host row can
    # carry any (rows_of refuses them on a dev row and range-checks each one).
    [ "$addrs" = "-" ] || IFS=, read -r -a ips <<<"$addrs"

    local san="" one
    for one in "${nm[@]}"; do
      san="${san:+$san,}DNS:$one"
    done
    # IP SANs for a home-network host row (policy section 2.1): the address a
    # client dials when it reaches the host by number -- over NetBird, whose
    # DNS name is public and so cannot be on this leaf.
    for one in ${ips[@]+"${ips[@]}"}; do
      san="$san,IP:$one"
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
    # And it must actually carry every name and address the row asked for --
    # an openssl extfile typo yields a valid certificate for the wrong set of
    # names. Compared as WHOLE entries, one per line, not as substrings: as a
    # substring "IP Address:10.0.0.1" is found inside "IP Address:10.0.0.12".
    # openssl prints a header line, then the entries joined by ", ".
    local have one2
    have="$(openssl x509 -in "$tmp/leaf.crt" -noout -ext subjectAltName |
      awk 'NR > 1 { sub(/^[ \t]+/, ""); n = split($0, e, ", "); for (k = 1; k <= n; k++) print e[k] }')"
    for one2 in "${nm[@]}"; do
      grep -Fxq -- "DNS:$one2" <<<"$have" ||
        die "the leaf just issued for $id is missing subjectAltName DNS:$one2"
    done
    for one2 in ${ips[@]+"${ips[@]}"}; do
      grep -Fxq -- "IP Address:$one2" <<<"$have" ||
        die "the leaf just issued for $id is missing subjectAltName IP Address:$one2"
    done

    cat "$tmp/leaf.crt" "$root_cert" >"$certdir/fullchain.pem"
    (
      umask 077
      cp "$tmp/leaf.key" "$key"
    )
    chmod 600 "$key"

    printf '%-34s %s\n' "$id" "$(printf '%s' "$names" | tr ',' ' ')${ips[0]+ $(printf '%s' "$addrs" | tr ',' ' ')}"
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

  local rows bad=0 id kind names addrs
  rows="$(rows_of "$spec")"

  printf '%-34s %10s  %s\n' DOMAIN 'DAYS LEFT' STATUS
  # Only the id is used here; kind, names and addresses are read so that the
  # line splits into the same fields rows_of wrote.
  while IFS=$'\t' read -r id kind names addrs; do
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
