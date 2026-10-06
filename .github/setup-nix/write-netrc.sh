#!/usr/bin/env bash
# Write the github.com credential where GIT will look for it.
#
# WHY THIS EXISTS, because the obvious reading of the problem is wrong.
#
# `access-tokens` in nix.conf is consumed by Nix's own GitHub/GitLab API
# fetchers — that is, by `github:owner/repo` and `gitlab:` flake refs. A flake
# input written as
#
#   { type = "git"; url = "https://github.com/org/private-repo"; }
#
# is fetched by Nix SHELLING OUT TO git. git never sees `access-tokens`, has no
# credential helper in a CI checkout, and so prompts, cannot, and dies with
#
#   fatal: could not read Username for 'https://github.com'
#
# Observed on metacraft-labs/infra: its `ci` matrix went red on `live` as soon
# as a flake.lock bump pulled in `reprobuild`, which declares
# codetracer-native-recorder in exactly that form. It presents as a token-scope
# problem and is not one — widening the PAT changes nothing, because the token
# never reaches git.
#
# actions/checkout does not cover it either: it installs a gitdir-scoped
# `includeIf` credential config for THE WORKSPACE REPO only, so fetching any
# other private repo is unauthenticated.
#
# git honours ~/.netrc for https (it sets CURLOPT_NETRC to CURL_NETRC_OPTIONAL
# by default), so the credential goes there. Nix's own netrc lives at
# $HOME/.config/nix/netrc and git does NOT read that path, which is why both
# files are written rather than one.
#
# AND WHY IT ALSO FILES THE PRIVATE BINARY CACHE, which is a second, unrelated
# credential that was missing from the same file.
#
# `setup-nix`'s "Configure Nix" step writes nix.conf with
#
#   substituters = https://cache.nixos.org ${{inputs.substituters}}
#   netrc-file   = $HOME/.config/nix/netrc
#
# and every caller in this org puts its PRIVATE Attic cache in `substituters`.
# Nothing anywhere gave Nix a credential for it: `GET <cache>/nix-cache-info`
# answers 401, Nix disables that substituter for `narinfo-cache-negative-ttl`
# seconds and retries forever, and everything not on cache.nixos.org is built
# FROM SOURCE. The action already ACCEPTED an `attic-token`, and already used
# it — in the "Start Attic watch-store" step, which runs `attic login`. That
# configures the Attic CLI for PUSHING and writes nothing Nix reads. Nix reads
# netrc. So callers that pass `attic-token` today are reading the cache
# ANONYMOUSLY without knowing it, and this file is the missing line.
#
# On a bare-metal runner with a warm /nix/store the cost is invisible. On an
# ephemeral runner, whose store starts empty, it is the difference between a
# substituted closure and a full toolchain build — which is how it was found,
# as a cascade of unrelated-looking source builds failing on third-party crate
# fetches.
#
# THE ENTRY'S SHAPE IS ATTIC'S OWN, NOT AN INVENTION. `attic use <cache>` is
# the supported way to point Nix at an Attic cache, and what it writes into
# netrc is (attic client/src/nix_netrc.rs, client/src/command/use.rs):
#
#   machine <host of the substituter URL> password <token>
#
# — the URL's HOST only, with no port, no path, and no `login` line at all. An
# Attic substituter URL IS `<endpoint>/<cache>`, so the host taken here from
# `attic-endpoint` and the host `attic use` takes from the substituter are the
# same string by construction. `attic use` itself is NOT invoked, because it
# also rewrites `substituters` and `trusted-public-keys`, which are the
# caller's to state.
#
# WHICH FILE GETS IT: the Nix netrc only. `~/.netrc` exists here for GIT, which
# has no business presenting a binary-cache token; the cache credential is
# added only to the path nix.conf's `netrc-file` actually names.
#
# Usage: write-netrc.sh
#   SETUP_NIX_GITHUB_TOKEN    the GitHub token, for `machine github.com`.
#                             Optional: when empty the GitHub stanza is not
#                             written (and git+https fetches of private repos
#                             will fail), but an Attic credential is still
#                             filed.
#   SETUP_NIX_ATTIC_TOKEN     optional. When non-empty, `machine <host>
#                             password <token>` is appended to the NIX netrc.
#                             When empty NOTHING is appended and the files are
#                             byte-for-byte what this script wrote before.
#   SETUP_NIX_ATTIC_ENDPOINT  the Attic server URL. Required when
#                             SETUP_NIX_ATTIC_TOKEN is set.
#   SETUP_NIX_SUBSTITUTERS    optional, only to report the anonymous-read
#                             condition in the log.
#   SETUP_NIX_NETRC_HOME=DIR  test seam; defaults to $HOME.
#
# Exit codes:
#   0   written (or nothing to write)
#   1   a token was supplied and could NOT be filed. Never silent: a
#       credential that cannot be filed is the defect this script exists to
#       fix, one level up.
#   65  refusing to append after an unterminated macdef (pre-existing).
set -euo pipefail

token="${SETUP_NIX_GITHUB_TOKEN:-}"
attic_token="${SETUP_NIX_ATTIC_TOKEN:-}"
attic_endpoint="${SETUP_NIX_ATTIC_ENDPOINT:-}"
extra_substituters="${SETUP_NIX_SUBSTITUTERS:-}"

if [[ -z "$token" && -z "$attic_token" ]]; then
  echo "netrc: no github token supplied; git+https fetches of private repos will fail"
  if [[ -n "$extra_substituters" ]]; then
    echo "netrc: NOTE: extra substituter(s) were declared ($extra_substituters) but no attic token was supplied, so Nix will read them ANONYMOUSLY. A private cache answers 401 to that, and Nix then disables it and builds from source."
  fi
  exit 0
fi

if [[ -z "$token" ]]; then
  echo "netrc: no github token supplied; git+https fetches of private repos will fail"
fi

if [[ "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
  echo "netrc: refusing a github token containing a line break" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# attic_host_of <url> -> attic_host
#
# The host of an absolute URL: no scheme, no userinfo, no port, no path. That
# is what `attic use` files its entry under (`Url::host()`), and it is what
# curl — the client Nix hands this file to via CURLOPT_NETRC_FILE — matches
# `machine` against. curl compares the HOSTNAME it parsed out of the request
# URL, so an entry carrying a port or a path matches nothing at all and fails
# exactly like having no entry.
#
# Every rejection below is a REFUSAL rather than a guess. A credential filed
# under the wrong machine name is indistinguishable, from inside a job, from
# the missing-credential defect this script exists to fix.
# ---------------------------------------------------------------------------
attic_host=""
attic_host_of() {
  local url="$1" authority=""

  case "$url" in
    *://*) ;;
    *)
      echo "netrc: attic endpoint must be an absolute URL with a scheme (e.g. https://cache.example.com/); got '$url'. Without one, whether the text is a host or a path is a guess." >&2
      exit 1
      ;;
  esac

  authority="${url#*://}"
  authority="${authority%%/*}"  # path
  authority="${authority%%\?*}" # query, if an endpoint ever carries one
  authority="${authority%%#*}"  # fragment, likewise
  authority="${authority##*@}"  # userinfo

  case "$authority" in
    "["*)
      echo "netrc: attic endpoint '$url' names an IPv6 literal. curl and netrc disagree about whether the brackets belong in a 'machine' name, and filing this credential under the wrong spelling would be silently indistinguishable from not filing it at all. Give the cache a DNS name." >&2
      exit 1
      ;;
  esac

  authority="${authority%%:*}" # port

  if [[ -z "$authority" ]]; then
    echo "netrc: attic endpoint '$url' has no host component." >&2
    exit 1
  fi
  case "$authority" in
    *[!0-9A-Za-z._-]*)
      echo "netrc: the host of attic endpoint '$url' contains a character that is not [0-9A-Za-z._-]. netrc is whitespace-separated and has no quoting, so such a name cannot be written as a 'machine' token." >&2
      exit 1
      ;;
  esac

  attic_host="$authority"
}

if [[ -n "$attic_token" ]]; then
  case "$attic_token" in
    *[[:space:]]*)
      # Deliberately never echoes the value. The overwhelmingly likely cause is
      # a trailing newline in the stored secret, and silently trimming a
      # credential is worse than refusing it: it would write a DIFFERENT token
      # than the one the owner set and report success.
      echo "netrc: refusing an attic token containing whitespace. netrc has no quoting, so the password token ends at the first space and the entry would carry a truncated credential. Re-add the secret without a trailing newline." >&2
      exit 1
      ;;
  esac

  if [[ -z "$attic_endpoint" ]]; then
    echo "netrc: an attic token was supplied but the attic endpoint is empty, so there is no host to file the credential under. Nix would go on reading the private cache anonymously, which is the exact defect this entry exists to fix." >&2
    exit 1
  fi

  attic_host_of "$attic_endpoint"

  if [[ "$attic_host" == "github.com" ]]; then
    # Two `machine github.com` stanzas in one file: curl takes the first, so
    # which credential each host receives would depend on emission order. That
    # is precisely the silent mis-filing this script refuses everywhere else.
    echo "netrc: the attic endpoint resolves to github.com, which already has its own stanza in this file. Refusing to file two credentials under one machine name." >&2
    exit 1
  fi
fi

netrc_home="${SETUP_NIX_NETRC_HOME:-${HOME:?HOME is not set}}"

umask 077
temporary_file=""

cleanup_temporary_files() {
  cleanup_status=$?
  trap - EXIT
  if [[ -n "$temporary_file" ]]; then
    if [[ -e "$temporary_file" || -L "$temporary_file" ]]; then
      rm -f -- "$temporary_file" || cleanup_status=1
    fi
  fi
  exit "$cleanup_status"
}

trap cleanup_temporary_files EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$netrc_home/.config/nix"

# case_insensitive_glob <ascii-host> -> a glob matching it in any ASCII case.
#
# The drop list below is data now that it carries the Attic host as well as
# github.com, so the case folding the original hand-wrote as
# `[Gg][Ii][Tt][Hh][Uu][Bb].[Cc][Oo][Mm]` has to be produced rather than typed.
# Built in pure Bash, once per host rather than once per line: `${value,,}`
# arrived after the Bash 3.2 macOS still ships, and shelling out to `tr` would
# reintroduce exactly the kind of pre-Nix PATH dependency this file's own
# negative control forbids. Non-letters pass through verbatim; every host that
# reaches here is [0-9A-Za-z._-] (github.com literally, the Attic host by the
# validation above), so no glob metacharacter can be produced.
case_insensitive_glob() {
  local source="$1" out="" index=0 character=""
  while [[ "$index" -lt "${#source}" ]]; do
    character="${source:index:1}"
    case "$character" in
      [Aa]) out="${out}[Aa]" ;; [Bb]) out="${out}[Bb]" ;; [Cc]) out="${out}[Cc]" ;;
      [Dd]) out="${out}[Dd]" ;; [Ee]) out="${out}[Ee]" ;; [Ff]) out="${out}[Ff]" ;;
      [Gg]) out="${out}[Gg]" ;; [Hh]) out="${out}[Hh]" ;; [Ii]) out="${out}[Ii]" ;;
      [Jj]) out="${out}[Jj]" ;; [Kk]) out="${out}[Kk]" ;; [Ll]) out="${out}[Ll]" ;;
      [Mm]) out="${out}[Mm]" ;; [Nn]) out="${out}[Nn]" ;; [Oo]) out="${out}[Oo]" ;;
      [Pp]) out="${out}[Pp]" ;; [Qq]) out="${out}[Qq]" ;; [Rr]) out="${out}[Rr]" ;;
      [Ss]) out="${out}[Ss]" ;; [Tt]) out="${out}[Tt]" ;; [Uu]) out="${out}[Uu]" ;;
      [Vv]) out="${out}[Vv]" ;; [Ww]) out="${out}[Ww]" ;; [Xx]) out="${out}[Xx]" ;;
      [Yy]) out="${out}[Yy]" ;; [Zz]) out="${out}[Zz]" ;;
      *) out="${out}${character}" ;;
    esac
    index=$((index + 1))
  done
  printf '%s' "$out"
}

# filter_existing_netrc <drop-host-glob>...
#
# Emits the file on stdin with every stanza for a named host removed. The hosts
# are arguments rather than a constant because a reused $HOME can hold a STALE
# entry for the Attic cache as easily as for github.com, and a stale entry is
# worse than none: curl takes the FIRST matching `machine`, so an old token
# left by a previous job would shadow the one this job was given and the cache
# would answer 401 with a perfectly well-formed netrc on disk.
filter_existing_netrc() {
  # This helper runs before setup-nix has established a Nix toolchain. Keep the
  # parser in Bash so a deliberately minimal runner PATH is sufficient. The
  # implementation is line-oriented because a macdef body is opaque until its
  # terminating blank line; interpreting tokens inside one could mistake macro
  # data for a credential record.
  local drop_globs=("$@")
  local drop_glob=""
  local line=""
  local line_has_newline=0
  local parsed_line=""
  local keyword=""
  local host=""
  local in_macdef=0
  local dropping=0
  local emitted_bytes=0
  local emitted_newline=1
  # Bash 3.2 treats literal capture parentheses on the right-hand side of
  # `=~` as shell syntax. Passing the expressions through variables keeps them
  # regular-expression data while still populating BASH_REMATCH.
  local keyword_pattern='^[[:space:]]*([^[:space:]]+)'
  local machine_host_pattern='^[[:space:]]*[^[:space:]]+[[:space:]]+([^[:space:]]+)'

  while :; do
    line=""
    if IFS= read -r line; then
      line_has_newline=1
    elif [[ -n "$line" ]]; then
      line_has_newline=0
    else
      break
    fi

    # read removes only LF. Retain a CR for byte-identical output, but exclude
    # it from token and blank-line recognition for CRLF-formatted files.
    parsed_line="${line%$'\r'}"

    if [[ "$in_macdef" -eq 1 ]]; then
      if [[ "$line_has_newline" -eq 1 ]]; then
        printf '%s\n' "$line"
        emitted_newline=1
      else
        printf '%s' "$line"
        emitted_newline=0
      fi
      emitted_bytes=1

      if [[ "$parsed_line" =~ ^[[:space:]]*$ ]]; then
        in_macdef=0
      fi
    else
      keyword=""
      host=""
      if [[ "$parsed_line" =~ $keyword_pattern ]]; then
        keyword="${BASH_REMATCH[1]}"
      fi

      # Spell out ASCII case folding instead of using ${value,,}, which was
      # added after the Bash 3.2 still shipped by macOS.
      case "$keyword" in
        [Mm][Aa][Cc][Hh][Ii][Nn][Ee])
          if [[ "$parsed_line" =~ $machine_host_pattern ]]; then
            host="${BASH_REMATCH[1]}"
          fi
          dropping=0
          for drop_glob in ${drop_globs[@]+"${drop_globs[@]}"}; do
            # shellcheck disable=SC2254 # the glob is data, and must stay unquoted
            case "$host" in
              $drop_glob) dropping=1 ;;
            esac
          done
          ;;
        [Mm][Aa][Cc][Dd][Ee][Ff])
          dropping=0
          in_macdef=1
          ;;
        [Dd][Ee][Ff][Aa][Uu][Ll][Tt])
          dropping=0
          ;;
      esac

      # Comments and visual separators are not credential fields. Preserve
      # them even while removing the surrounding managed credential records.
      if [[ "$dropping" -eq 0 || -z "$keyword" || "$keyword" == \#* ]]; then
        if [[ "$line_has_newline" -eq 1 ]]; then
          printf '%s\n' "$line"
          emitted_newline=1
        else
          printf '%s' "$line"
          emitted_newline=0
        fi
        emitted_bytes=1
      fi
    fi

    if [[ "$line_has_newline" -eq 0 ]]; then
      break
    fi
  done

  # A machine stanza appended after an unterminated macdef would still be part
  # of the macro body, so git would never see the credential. Refuse to
  # publish a replacement instead of reporting success with a malformed file.
  if [[ "$in_macdef" -eq 1 ]]; then
    echo "netrc: refusing to append after an unterminated macdef" >&2
    return 65
  fi

  # A final unrelated field without LF is preserved verbatim by the loop. Add
  # only the structural separator required to keep the new machine record from
  # becoming part of that field.
  if [[ "$emitted_bytes" -eq 1 && "$emitted_newline" -eq 0 ]]; then
    printf '\n'
  fi
}

validate_netrc_target() {
  local netrc="$1"

  # Replacing a symlink would sever an intentionally managed credential file,
  # while following it would make the atomic rename target a different path.
  # Persistent runners must surface that configuration instead of guessing.
  if [[ -L "$netrc" ]]; then
    echo "netrc: refusing to replace symlink: $netrc" >&2
    return 1
  fi
  if [[ -e "$netrc" && ! -f "$netrc" ]]; then
    echo "netrc: refusing to replace non-regular file: $netrc" >&2
    return 1
  fi
}

# write_netrc <path> <with-attic: 0|1>
write_netrc() {
  netrc="$1"
  want_attic="$2"
  netrc_directory="${netrc%/*}"

  # Validate again immediately before reading. The up-front validation below
  # prevents a known-invalid second destination from partially rotating the
  # first; this second check narrows the remaining check/use window.
  validate_netrc_target "$netrc"

  temporary_file="$(mktemp "$netrc_directory/.write-netrc.XXXXXX")"

  # mktemp already obeys the restrictive umask. Keep an explicit chmod both as
  # defence in depth and as a fail-closed check before credential bytes exist.
  chmod 0600 "$temporary_file"

  # The hosts whose prior stanzas this file OWNS and therefore replaces. Every
  # other record is emitted untouched: this script is not the only thing that
  # may have written here. A host is dropped only when a REPLACEMENT for it is
  # about to be written, so a run that files no GitHub credential cannot delete
  # one somebody else filed.
  drop_globs=()
  if [[ -n "$token" ]]; then
    drop_globs+=("$(case_insensitive_glob github.com)")
  fi
  if [[ "$want_attic" -eq 1 && -n "$attic_host" ]]; then
    drop_globs+=("$(case_insensitive_glob "$attic_host")")
  fi

  if [[ -e "$netrc" ]]; then
    # A netrc machine entry starts at `machine HOST` and continues until the
    # next machine/default/macdef entry. This removes every managed record,
    # whether its fields share the machine line or use conventional following
    # lines, while emitting unrelated records without reconstructing them.
    filter_existing_netrc ${drop_globs[@]+"${drop_globs[@]}"} < "$netrc" > "$temporary_file"
  fi

  if [[ -n "$token" ]]; then
    {
      # `login` is ignored by GitHub for PAT-over-https; x-access-token is the
      # documented placeholder.
      printf 'machine github.com\n'
      printf '  login x-access-token\n'
      printf '  password %s\n' "$token"
    } >> "$temporary_file"
  fi

  if [[ "$want_attic" -eq 1 && -n "$attic_token" ]]; then
    # No `login`: `attic use` writes none, and curl sends Basic auth with an
    # empty username, which is what the Attic server expects. One line rather
    # than three is the same document — netrc is whitespace-separated and a
    # newline is just whitespace — and keeps the token on the same line as the
    # host it belongs to.
    printf 'machine %s password %s\n' "$attic_host" "$attic_token" >> "$temporary_file"
  fi

  chmod 0600 "$temporary_file"
  mv -f -- "$temporary_file" "$netrc"
  # The published pathname no longer exists. Stop tracking it so EXIT cannot
  # remove an unrelated file that is later created at the old random name.
  temporary_file=""
}

# Each file has its own atomic publication boundary. A failure while publishing
# the second file returns nonzero; rerunning safely converges both files because
# write_netrc removes every prior managed stanza before installing the new one.
#
# Only the NIX netrc carries the cache credential: `~/.netrc` is read by git
# (and by every other curl-based client on the box), and a binary-cache token
# has no business there. nix.conf names `$HOME/.config/nix/netrc` and that is
# the file the 401 was coming from.
user_netrc="$netrc_home/.netrc"
nix_netrc="$netrc_home/.config/nix/netrc"
validate_netrc_target "$nix_netrc"
if [[ -n "$token" ]]; then
  # `~/.netrc` exists in this script for exactly one reason — the GitHub
  # credential git needs — so with no GitHub token there is nothing to publish
  # there and the file is not touched at all.
  validate_netrc_target "$user_netrc"
  write_netrc "$user_netrc" 0
fi
write_netrc "$nix_netrc" 1

if [[ -n "$token" ]]; then
  echo "netrc: github.com credential written for git+https flake inputs"
fi
if [[ -n "$attic_token" ]]; then
  echo "netrc: $attic_host credential written into the Nix netrc, so Nix can READ the private cache"
elif [[ -n "$extra_substituters" ]]; then
  # Named, not warned. This is true in the majority of jobs in this org today
  # and an annotation on every one of them would be noise; a line in the log of
  # the job that pays for it is what was missing when a fleet-wide source-build
  # cascade had to be diagnosed from crate fetch errors.
  echo "netrc: NOTE: extra substituter(s) were declared ($extra_substituters) but no attic token was supplied, so Nix will read them ANONYMOUSLY. A private cache answers 401 to that, and Nix then disables it and builds from source. Pass attic-token to make the cache readable."
fi
