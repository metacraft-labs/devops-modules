// Copyright 2026 Metacraft Labs
//
//    Licensed under the Apache License, Version 2.0 (the "License"); you may
//    not use this file except in compliance with the License. You may obtain a
//    copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

// RemoteBackend is the RB1 remote-target backend: it implements the same
// backend.Backend seam the local backends do, but instead of exec-ing a LOCAL
// vm-harness/virsh/incus it drives a REMOTE `vm-harness serve` daemon over the
// RA1 RPC (bearer-auth HTTP/JSON, protocol v1). Because the daemon runs the
// SAME vm-harness CLI as its worker, each lifecycle op is a forwarded CLI argv
// that is byte-equivalent to the local path — a remote
// `run --ephemeral --backend <target> …` / `ephemeral-destroy …` executes the
// identical backend code on the remote host.
//
// STATELESSNESS. The provider keeps NO local lifecycle state in remote mode.
// The provider_id is GARM's own unique instance name (GARM's DB is the source
// of truth), and host/instance liveness is recovered from the remote daemon's
// authenticated `/v1/info` — never from a local store. This preserves the
// stateless-provider non-negotiable across the network boundary: a fresh
// provider process (GARM spawns one per command) reconstructs everything it
// needs from the config + the remote endpoint.
//
// Per-target LIFECYCLE RECIPES map a create/delete to the concrete vm-harness
// verbs a given remote backend understands. RB1 ships:
//   - "noop"  — the sanctioned test backend (provision / ephemeral-destroy);
//     this is what the hermetic `t_garm_provider_remote` gate exercises so the
//     WIRE CONTRACT (bearer auth, /v1/exec NDJSON streaming, exit codes) is
//     tested for real against a live `vm-harness serve --backend noop`.
//   - "incus" and a generic fallback — the production-shaped ephemeral path
//     (`run --ephemeral --keep` to launch + return, `ephemeral-destroy` to
//     reclaim). The rendered runner bootstrap is shipped to the remote guest as
//     cloud-init user-data over the /v1/exec `userData` field (RB2); the daemon
//     stages it to a temp file and points `--user-data` at it. Per-target
//     refinements (hyperv's --golden-image, tart's run-backgrounding) remain
//     follow-ups, called out rather than half-implemented.
package backend

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// RemoteBackend drives a remote `vm-harness serve` daemon. It is constructed
// from the parsed [remote] config by provider.NewWithConfig.
type RemoteBackend struct {
	// Client is the bearer-authenticated RPC client to the remote daemon.
	Client *ServeClient
	// TargetBackend is the vm-harness backend id the remote host drives
	// (forwarded as the remote `--backend`).
	TargetBackend string
	// GuestOS is the reported guest OS for created instances when the
	// golden-image map carries no os_name.
	GuestOS string
	// IncusSecurityNesting and IncusNestedKvm are trusted provider-admin
	// grants for the remote Incus recipe. They map only to vm-harness's two
	// fixed capability flags; no workflow, bootstrap, or guest field can
	// select arbitrary Incus configuration, device paths, or modes.
	IncusSecurityNesting bool
	IncusNestedKvm       bool
}

// remoteRecipe builds the create/delete argv for a specific target backend.
type remoteRecipe struct {
	create func(backend *RemoteBackend, args CreateArgs) []string
	del    func(target, name string) []string
}

// noopRecipe: the sanctioned test backend. `provision` and `ephemeral-destroy`
// both succeed against `--backend noop` (verified), so a real create+delete
// round-trip exercises the whole wire path without a hypervisor.
var noopRecipe = remoteRecipe{
	create: func(backend *RemoteBackend, args CreateArgs) []string {
		return []string{"provision", "--backend", backend.TargetBackend, "--baseline", args.Name, "--log-format", "json"}
	},
	del: func(target, name string) []string {
		return []string{"ephemeral-destroy", "--backend", target, "--baseline", name, "--log-format", "json"}
	},
}

// ephemeralRecipe: the production-shaped per-job path used by incus/libvirt and
// as the generic fallback. `run --ephemeral --keep` launches the per-job guest
// and returns immediately (the guest keeps running the injected runner);
// `ephemeral-destroy` reclaims it. RB2: the rendered runner bootstrap
// (CreateArgs.Bootstrap) is shipped to the remote guest as cloud-init user-data
// — Create sends it in the /v1/exec `userData` field and the daemon materializes
// it to a temp file it points `--user-data` at (see serve/server.applyUserData),
// so the remote `run --ephemeral` injects it exactly as the local path would.
// The recipe stays argv-only; user-data travels alongside the argv, not in it.
var ephemeralRecipe = remoteRecipe{
	create: func(backend *RemoteBackend, args CreateArgs) []string {
		argv := []string{"run", "--ephemeral", "--backend", backend.TargetBackend, "--baseline", args.Name}
		if args.SourceImage != "" {
			// --base-image is the incus ephemeral path's image alias;
			// --source-image is what every other backend resolves its golden
			// from (cli.nim maps it to BaselineSpec.sourceImage, whereas
			// --baseline goes to BaselineSpec.name). Since this recipe is the
			// fallback for *any* non-noop target, sending only --base-image
			// left sourceImage empty for tart and qemu-windows-arm — and the
			// tart backends answer an empty image by substituting their
			// built-in cirruslabs golden, i.e. silently running an image
			// nobody configured. Send both; each backend reads the one it
			// understands and ignores the other.
			argv = append(argv, "--base-image", args.SourceImage,
				"--source-image", args.SourceImage)
		}
		// Only remote Incus consumes these provider-admin grants. The fixed
		// flag order is part of the contract: the image pair first (base then
		// source, above), then nesting, then nested KVM, then the pre-existing
		// lifecycle/logging suffix.
		//
		// The "with both grants off the argv is byte-for-byte identical to the
		// RB1/RB2 path" property still holds, MODULO the deliberate
		// `--source-image <image>` pair added above: with both grants off the
		// emitted argv is the pre-capability argv with exactly that pair
		// inserted immediately after `--base-image <image>`, and nothing else
		// moved or dropped. When no image is configured neither image flag is
		// emitted, so the grants-off argv is then literally identical to the
		// RB1/RB2 one. The capability flags are unreachable for any target
		// other than "incus", image or no image.
		if backend.TargetBackend == "incus" {
			if backend.IncusSecurityNesting {
				argv = append(argv, "--incus-security-nesting")
			}
			if backend.IncusNestedKvm {
				argv = append(argv, "--incus-nested-kvm")
			}
		}
		argv = append(argv, "--keep", "--log-format", "json")
		return argv
	},
	del: func(target, name string) []string {
		return []string{"ephemeral-destroy", "--backend", target, "--baseline", name, "--log-format", "json"}
	},
}

func (b *RemoteBackend) recipe() remoteRecipe {
	switch b.TargetBackend {
	case "noop":
		return noopRecipe
	default:
		// incus, libvirt, and any other target use the ephemeral recipe.
		return ephemeralRecipe
	}
}

// osName resolves the reported OS name for a created instance.
func (b *RemoteBackend) osName(args CreateArgs) string {
	if args.OSName != "" {
		return args.OSName
	}
	if b.GuestOS != "" {
		return b.GuestOS
	}
	return "linux"
}

// Create launches a per-job guest on the remote host over RPC. It is stateless:
// on a successful (exit 0) launch it returns a running Instance whose
// provider_id is GARM's own unique name. No local file is written.
func (b *RemoteBackend) Create(ctx context.Context, args CreateArgs) (Instance, error) {
	if args.Name == "" {
		return Instance{}, fmt.Errorf("remote Create: instance name is required")
	}
	argv := b.recipe().create(b, args)
	// Ship the rendered runner bootstrap (if any) as cloud-init user-data. It is
	// empty for the noop test recipe and whenever GARM supplied no tools, in
	// which case ExecStreamWithUserData sends nothing extra (omitempty) and the
	// daemon appends no --user-data flag.
	code, err := b.Client.ExecStreamWithUserData(ctx, argv, string(args.Bootstrap), logToStderr("create "+args.Name))
	if err != nil {
		return Instance{}, fmt.Errorf("remote Create %s: %w", args.Name, err)
	}
	if code != 0 {
		return Instance{}, fmt.Errorf("remote Create %s: worker exit %d", args.Name, code)
	}
	return Instance{
		ProviderID:   args.Name,
		Name:         args.Name,
		ControllerID: args.ControllerID,
		PoolID:       args.PoolID,
		OSName:       b.osName(args),
		OSVersion:    args.OSVersion,
		OSArch:       args.OSArch,
		Status:       "running",
	}, nil
}

// Delete reclaims the per-job guest on the remote host over RPC. It is
// idempotent in the way GARM needs: `ephemeral-destroy` already exits 0 for a
// guest that is absent (vm-run backends return early on a missing kept-instance
// record, incus deletes with --force, libvirt checks the domain is gone), so a
// repeated Delete of an absent instance still reports success. A NON-ZERO exit
// therefore means the teardown failed and the guest may still exist, and it is
// surfaced: GARM keeps the instance in pending_delete and retries. Swallowing
// it would make GARM drop the row while the clone keeps running, leaking it
// where neither GARM nor List can see it.
func (b *RemoteBackend) Delete(ctx context.Context, idOrName string) error {
	argv := b.recipe().del(b.TargetBackend, idOrName)
	code, err := b.Client.ExecStream(ctx, argv, logToStderr("delete "+idOrName))
	if err != nil {
		// A rejected credential or an unreachable endpoint is a real error.
		var authErr *ServeAuthError
		if errors.As(err, &authErr) {
			return err
		}
		return fmt.Errorf("remote Delete %s: %w", idOrName, err)
	}
	if code != 0 {
		return fmt.Errorf("remote Delete %s: teardown worker exit %d (guest may still exist; GARM will retry)", idOrName, code)
	}
	return nil
}

// Get recovers a best-effort view of one instance. The provider holds no local
// state and the RA1 protocol has no per-instance query yet (an enumeration
// endpoint is an RB2/RA6 follow-up), so Get confirms the remote host is
// reachable + the credential is valid via /v1/info and reports the GARM-known
// instance as running. A rejected credential is surfaced; a transport failure
// is surfaced (GARM treats it as transient) rather than mis-reported as absent,
// so a live runner is never spuriously reaped over a blind spot.
func (b *RemoteBackend) Get(ctx context.Context, idOrName string) (Instance, error) {
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if _, err := b.Client.Info(cctx); err != nil {
		return Instance{}, err
	}
	return Instance{
		ProviderID: idOrName,
		Name:       idOrName,
		OSName:     b.GuestOS,
		Status:     "running",
	}, nil
}

// List cannot enumerate remote instances in RB1 (the RA1 protocol exposes no
// list endpoint; a stateless provider process holds nothing to list). It probes
// the endpoint for auth/liveness and returns an empty set — the honest answer
// under GARM's DB-as-truth model. Fleet-wide remote enumeration is an RB2
// deliverable (a serve-side list verb).
func (b *RemoteBackend) List(ctx context.Context, poolID string) ([]Instance, error) {
	return b.listProbe(ctx)
}

// ListByController mirrors List (used by RemoveAllInstances).
func (b *RemoteBackend) ListByController(ctx context.Context, controllerID string) ([]Instance, error) {
	return b.listProbe(ctx)
}

func (b *RemoteBackend) listProbe(ctx context.Context) ([]Instance, error) {
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if _, err := b.Client.Info(cctx); err != nil {
		var authErr *ServeAuthError
		if errors.As(err, &authErr) {
			return nil, err
		}
		// Transport error: report empty rather than fail the whole reconcile.
		return nil, nil
	}
	return nil, nil
}

// Start is not meaningful for one-shot ephemeral remote instances; the guest is
// launched by Create and reclaimed by Delete. A guest that has exited cannot be
// restarted — a replacement runner is created instead.
func (b *RemoteBackend) Start(ctx context.Context, idOrName string) error {
	return fmt.Errorf("remote instance %s: ephemeral runners are one-shot; create a replacement", idOrName)
}

// Stop maps to Delete (reclaim the per-job guest).
func (b *RemoteBackend) Stop(ctx context.Context, idOrName string, force bool) error {
	return b.Delete(ctx, idOrName)
}

// logToStderr streams remote worker log lines to the provider's stderr so a
// remote create/delete looks like a local one in GARM's provider logs.
func logToStderr(tag string) func(ExecEvent) {
	return func(ev ExecEvent) {
		switch ev.Kind {
		case "log":
			fmt.Fprintf(os.Stderr, "[remote %s] %s\n", tag, ev.Line)
		case "error":
			fmt.Fprintf(os.Stderr, "[remote %s] error: %s\n", tag, ev.Message)
		}
	}
}

// Ensure RemoteBackend satisfies the Backend seam and ErrNotFound is imported
// for parity with the other backends' idempotency contract.
var _ Backend = (*RemoteBackend)(nil)
var _ = garmErrors.ErrNotFound
