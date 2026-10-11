# shellcheck shell=bash
# $prog is the caller's:
# shellcheck disable=SC2154
# Guided-mode output for the Google Workspace tools: what an operator does in
# which console, printed on STDOUT for a narrow terminal pane (tmux), and the
# waits between a console step and its automatic verification.
#
# Sourced, not executed. The caller sets $prog. Answers are read from stdin,
# one line each, so a scripted stdin drives a guided flow in tests:
#
#   <Enter>     done, verify it now
#   s           skip this step (the caller says what that leaves undone)
#   q           quit; re-running resumes where things stand
#
# $GUIDE_WIDTH (default 78) is the wrap column.

guide_width="${GUIDE_WIDTH:-78}"

# guide_wrap WIDTH: word-wraps stdin at WIDTH, keeping each line's leading
# indentation on its continuation lines. A word is never broken: one longer
# than the line (a URL) goes alone on its own line, whole, so that it can be
# copied or clicked.
guide_wrap() {
  awk -v w="$1" '{
    match($0, /^ */); ind = substr($0, 1, RLENGTH)
    n = split(substr($0, RLENGTH + 1), word, " "); line = ""
    for (i = 1; i <= n; i++) {
      if (word[i] == "") continue
      if (line == "") line = ind word[i]
      else if (length(line) + 1 + length(word[i]) <= w) line = line " " word[i]
      else { print line; line = ind word[i] }
    }
    print line
  }'
}

# Wrapped prose on stdout. Long values to paste (scope lines) are printed with
# guide_value instead.
guide_text() { printf '%s\n' "$*" | guide_wrap "$guide_width"; }

guide_h1() {
  local line
  line="$(printf '%*s' "$guide_width" '' | tr ' ' '=')"
  printf '\n%s\n' "$line"
  printf '%s\n' "$*" | guide_wrap "$guide_width"
  printf '%s\n' "$line"
}

guide_h2() { printf -- '-- %s\n' "$*" | guide_wrap "$guide_width" | sed '1s/^/\n/'; }

# guide_step N TEXT: "  N. TEXT", continuation lines indented under the text.
guide_step() {
  local n="$1" pad
  shift
  pad="$(printf '%*s' $((${#n} + 4)) '')"
  printf '%s\n' "$*" | guide_wrap $((guide_width - ${#pad})) |
    awk -v n="$n" -v pad="$pad" 'NR == 1 { print "  " n ". " $0; next } { print pad $0 }'
}

# guide_value VALUE: a value to copy, alone on its line(s), never wrapped.
guide_value() { printf '\n      %s\n\n' "$*"; }

guide_ok() { guide_text "  OK: $*"; }
guide_bad() { guide_text "  NOT YET: $*"; }

# guide_wait PROMPT: 0 on Enter (verify now), 10 on "s" (skip); exits 3 on
# "q", and 4 when stdin is closed (a guided flow cannot go on unattended).
guide_wait() {
  local ans
  printf '\n>> %s\n   [Enter] verify now   [s] skip   [q] quit: ' "$*"
  if ! IFS= read -r ans; then
    printf '\n'
    echo "$prog: no more input; stopping here. Re-run to resume." >&2
    exit 4
  fi
  printf '\n'
  case "${ans,,}" in
    q | quit)
      echo "$prog: stopped by the operator. Re-run to resume; finished steps are skipped." >&2
      exit 3
      ;;
    s | skip) return 10 ;;
    *) return 0 ;;
  esac
}

# guide_ask PROMPT CHOICES…: prints the answer (lowercased) that matches one
# of CHOICES; asks again otherwise. "q" quits as in guide_wait.
guide_ask() {
  local prompt="$1" ans c
  shift
  while :; do
    printf '\n>> %s [%s]: ' "$prompt" "$(
      IFS=/
      echo "$*"
    )" >&2
    if ! IFS= read -r ans; then
      printf '\n' >&2
      echo "$prog: no more input; stopping here. Re-run to resume." >&2
      exit 4
    fi
    ans="${ans,,}"
    [ "$ans" = q ] && {
      echo "$prog: stopped by the operator. Re-run to resume." >&2
      exit 3
    }
    for c in "$@"; do
      [ "$ans" = "$c" ] && {
        printf '%s' "$ans"
        return 0
      }
    done
    echo "   (answer one of: $*)" >&2
  done
}
