// Copyright 2026 Metacraft Labs
//
//    Licensed under the Apache License, Version 2.0 (the "License"); you may
//    not use this file except in compliance with the License. You may obtain
//    a copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
//    License for the specific language governing permissions and limitations
//    under the License.

package backend

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// mockVirshScript is a self-contained POSIX-sh emulation of the subset of virsh
// the provider drives. It persists domain XML under $MOCK_VIRSH_STATE so the
// stateless provider (which never persists anything itself) has a real backend
// to recompute from. It is exercised by the in-package tests here AND, via the
// same file written to disk, by the end-to-end protocol gate.
const mockVirshScript = `#!/bin/sh
set -eu
STATE="${MOCK_VIRSH_STATE:?MOCK_VIRSH_STATE unset}"
mkdir -p "$STATE/domains" "$STATE/state"

# Drop the leading "-c <uri>" that the provider always passes.
if [ "${1:-}" = "-c" ]; then shift 2; fi

cmd="${1:-}"; shift || true

resolve() {
  # $1 may be a name or a UUID; echo the matching name or empty.
  want="$1"
  if [ -f "$STATE/domains/$want.xml" ]; then echo "$want"; return 0; fi
  for f in "$STATE"/domains/*.xml; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .xml)
    u=$(sed -n 's/.*<uuid>\(.*\)<\/uuid>.*/\1/p' "$f" | head -n1)
    if [ "$u" = "$want" ]; then echo "$n"; return 0; fi
  done
  return 1
}

case "$cmd" in
  define)
    # define /dev/stdin — read XML from stdin, extract <name>, assign a UUID.
    xml=$(cat)
    name=$(printf '%s' "$xml" | sed -n 's/.*<name>\(.*\)<\/name>.*/\1/p' | head -n1)
    if [ -z "$name" ]; then echo "error: no name in domain xml" >&2; exit 1; fi
    count=$(ls "$STATE/domains" | wc -l)
    uuid="00000000-0000-4000-8000-$(printf '%012d' "$(( count + 1 ))")"
    # Inject a <uuid> right after <domain ...> so dominfo/dumpxml can report it.
    printf '%s' "$xml" | sed "s|<name>$name</name>|<name>$name</name>\n  <uuid>$uuid</uuid>|" > "$STATE/domains/$name.xml"
    echo "shutoff" > "$STATE/state/$name"
    echo "Domain '$name' defined"
    ;;
  start)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    echo "running" > "$STATE/state/$n"
    echo "Domain '$n' started"
    ;;
  shutdown)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    echo "shutoff" > "$STATE/state/$n"
    ;;
  destroy)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    echo "shutoff" > "$STATE/state/$n"
    echo "Domain '$n' destroyed"
    ;;
  undefine)
    # first positional non-flag arg is the domain
    dom=""
    for a in "$@"; do case "$a" in --*) ;; *) dom="$a"; break;; esac; done
    n=$(resolve "$dom") || { echo "error: failed to get domain '$dom'" >&2; exit 1; }
    rm -f "$STATE/domains/$n.xml" "$STATE/state/$n"
    echo "Domain '$n' has been undefined"
    ;;
  dominfo)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    uuid=$(sed -n 's/.*<uuid>\(.*\)<\/uuid>.*/\1/p' "$STATE/domains/$n.xml" | head -n1)
    st=$(cat "$STATE/state/$n" 2>/dev/null || echo shutoff)
    case "$st" in running) st="running";; *) st="shut off";; esac
    printf 'Name:           %s\n' "$n"
    printf 'UUID:           %s\n' "$uuid"
    printf 'State:          %s\n' "$st"
    ;;
  dumpxml)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    cat "$STATE/domains/$n.xml"
    ;;
  list)
    for f in "$STATE"/domains/*.xml; do
      [ -e "$f" ] || continue
      basename "$f" .xml
    done
    ;;
  *)
    echo "mock-virsh: unhandled command '$cmd'" >&2
    exit 1
    ;;
esac
`

// writeMockVirsh writes the mock virsh script into dir and returns its path.
func writeMockVirsh(t *testing.T, dir string) string {
	t.Helper()
	p := filepath.Join(dir, "virsh")
	if err := os.WriteFile(p, []byte(mockVirshScript), 0o755); err != nil {
		t.Fatalf("write mock virsh: %v", err)
	}
	return p
}

func newTestBackend(t *testing.T) *VirshBackend {
	t.Helper()
	dir := t.TempDir()
	stateDir := filepath.Join(dir, "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MOCK_VIRSH_STATE", stateDir)
	return &VirshBackend{
		VirshPath: writeMockVirsh(t, dir),
		URI:       "test:///default",
	}
}

func TestVirshBackendLifecycle(t *testing.T) {
	b := newTestBackend(t)
	ctx := context.Background()

	// Create.
	inst, err := b.Create(ctx, CreateArgs{
		Name:         "garm-abc123",
		ControllerID: "ctrl-1",
		PoolID:       "pool-1",
		SourceImage:  "/golden/windows.qcow2",
		OSName:       "windows",
		OSVersion:    "2022",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if inst.ProviderID == "" {
		t.Fatalf("Create: empty provider id")
	}
	if inst.Status != "running" {
		t.Fatalf("Create: status=%q want running", inst.Status)
	}

	// Get by name.
	got, err := b.Get(ctx, "garm-abc123")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.ControllerID != "ctrl-1" || got.PoolID != "pool-1" {
		t.Fatalf("Get: metadata not recovered: %+v", got)
	}
	if got.OSName != "windows" || got.OSVersion != "2022" {
		t.Fatalf("Get: os metadata not recovered: %+v", got)
	}

	// Get by provider_id (UUID).
	byID, err := b.Get(ctx, inst.ProviderID)
	if err != nil {
		t.Fatalf("Get by id: %v", err)
	}
	if byID.Name != "garm-abc123" {
		t.Fatalf("Get by id: name=%q", byID.Name)
	}

	// List by pool.
	list, err := b.List(ctx, "pool-1")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 || list[0].Name != "garm-abc123" {
		t.Fatalf("List: %+v", list)
	}

	// List by a different pool => empty.
	empty, err := b.List(ctx, "pool-nope")
	if err != nil {
		t.Fatalf("List(other): %v", err)
	}
	if len(empty) != 0 {
		t.Fatalf("List(other): want empty, got %+v", empty)
	}

	// Delete then confirm gone.
	if err := b.Delete(ctx, "garm-abc123"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := b.Get(ctx, "garm-abc123"); !errors.Is(err, garmErrors.ErrNotFound) {
		t.Fatalf("Get after delete: want ErrNotFound, got %v", err)
	}

	// Delete again => idempotent (nil).
	if err := b.Delete(ctx, "garm-abc123"); err != nil {
		t.Fatalf("Delete idempotent: %v", err)
	}
}
