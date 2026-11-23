# Proves that a Nim package is the organisation's 2.2.10 toolchain and that it
# carries the allocator fix the move to 2.2.10 is for.
#
# `nim` is the wrapped compiler under test. Pass a different one (for
# example the pinned nixpkgs' stock `nim`) to reproduce the failure: the
# stock 2.2.4 compiler fails the version and the allocator assertions.
#
# The assertions, in order:
#   1. The wrapper reports `Version 2.2.10`.
#   2. The standard library it compiles against carries
#      https://github.com/nim-lang/Nim/pull/25513: `rawDealloc` no longer
#      frees a small chunk that another thread may still be filling. The
#      race itself is probabilistic (on a macOS arm64 host the stock 2.2.4
#      runtime crashed 38 of 100 runs of a cross-thread Channel test), so
#      the deterministic gate is the presence of the fix in the source the
#      compiler links into every threaded program.
#   3. The wrapper builds and runs a threaded program that sends `seq`
#      payloads through a `system.Channel` from worker threads and frees
#      them on the main thread, under ORC with threads on: the shape that
#      crashed. This exercises the wrapper's C-compiler configuration and
#      the runtime end to end, not only the version string.
{
  lib,
  runCommandCC,
  nim,
}:
runCommandCC "nim-toolchain-check-${nim.version}"
  {
    nativeBuildInputs = [ nim ];
    meta.platforms = lib.platforms.unix;
  }
  ''
    set -euo pipefail
    export HOME=$TMPDIR

    version_line="$(nim --version | head -n 1)"
    echo "$version_line"
    case "$version_line" in
      *"Version 2.2.10 "*) ;;
      *)
        echo "expected Nim 2.2.10, got: $version_line" >&2
        exit 1
        ;;
    esac

    # The library directory the compiler resolves for `system`.
    libdir="$(nim dump --dump.format:json - 2>/dev/null </dev/null \
      | sed -n 's/.*"libpath": *"\([^"]*\)".*/\1/p')"
    if [ -z "$libdir" ] || [ ! -f "$libdir/system/alloc.nim" ]; then
      echo "could not locate the compiler's system/alloc.nim (libpath: '$libdir')" >&2
      exit 1
    fi
    if ! grep -qF "Don't free small chunks to avoid race condition with sharedFreeLists" \
      "$libdir/system/alloc.nim"; then
      echo "$libdir/system/alloc.nim lacks the nim-lang/Nim#25513 allocator fix" >&2
      exit 1
    fi

    cat > chanrace.nim <<'EOF'
    type Msg = tuple[idx: int, ids: seq[int]]
    var chan: Channel[Msg]
    chan.open()
    proc worker(i: int) {.thread.} =
      var ids: seq[int]
      for k in 0 ..< 100: ids.add k
      chan.send((idx: i, ids: ids))
    for round in 0 ..< 200:
      var ts: array[4, Thread[int]]
      for i in 0 ..< 4: createThread(ts[i], worker, i)
      joinThreads(ts)
      for _ in 0 ..< 4: discard chan.recv()
    chan.close()
    echo "ok"
    EOF
    nim c --hints:off --mm:orc --threads:on -d:release --nimcache:"$TMPDIR/nimcache" \
      -o:"$TMPDIR/chanrace" chanrace.nim
    test "$("$TMPDIR/chanrace")" = ok

    mkdir -p $out
    echo "$version_line" > $out/version
  ''
