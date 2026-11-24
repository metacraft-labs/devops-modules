# shellcheck shell=bash
# The caller supplies launchctl so the protocol can be exercised without root.
# Production always passes /bin/launchctl. All other arguments are root-owned
# launchd configuration, never manifest content.
launchctl=$1
mode=$2
shift 2

case "$mode" in
  poll)
    worker=$1
    plist=$2
    # A fixed, unmanaged label bounds the number of jobs, and lets a restarted
    # poller reattach to a transaction that survived its old launchd job.
    if ! "$launchctl" print "system/$worker" >/dev/null 2>&1; then
      "$launchctl" bootstrap system "$plist"
    fi
    while status=$("$launchctl" print "system/$worker" 2>&1); do
      if [[ "$status" =~ last\ exit\ code\ =\ ([0-9]+) ]]; then
        result=${BASH_REMATCH[1]}
        "$launchctl" bootout "system/$worker"
        exit "$result"
      fi
      if [[ "$status" == *"last terminating signal ="* ]]; then
        echo "Deployment transaction terminated by a signal: $status" >&2
        "$launchctl" bootout "system/$worker"
        exit 1
      fi
      sleep 1
    done
    echo "Deployment transaction disappeared without an exit status: $status" >&2
    exit 1
    ;;
  recover)
    label=$1
    plist=$2
    [[ -f "$plist" ]] || exit 0
    disabled=$("$launchctl" print-disabled system)
    # Respect an operator's persistent disable. An unreadable domain is a
    # failure, not permission to enable a disabled service.
    if printf '%s\n' "$disabled" | grep -F "\"$label\" => true" >/dev/null; then
      exit 0
    fi
    "$launchctl" print "system/$label" >/dev/null 2>&1 && exit 0
    # Activation itself owns service reconciliation while the transaction is
    # live. Bootstrapping the old plist in its bootout/bootstrap gap would race
    # nix-darwin. A terminal transaction is safe to recover after.
    if status=$("$launchctl" print "system/$label-transaction" 2>/dev/null) \
      && [[ ! "$status" =~ last\ exit\ code\ =\ [0-9]+ ]]; then
      exit 0
    fi
    "$launchctl" bootstrap system "$plist"
    ;;
  *)
    echo "Unknown deployment supervisor mode: $mode" >&2
    exit 64
    ;;
esac
