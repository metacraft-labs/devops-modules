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
// The provider_id is GARM's own unique instance name, and instance existence,
// state and ownership are recovered from the DAEMON HOST on every query
// (`ephemeral-list`, joined there with the ownership labels `ephemeral-label`
// recorded at create) — never from a local store. A fresh provider process
// (GARM spawns one per command) reconstructs everything it needs from the
// config + the remote endpoint.
//
// FAIL CLOSED. GARM treats an instance absent from ListInstances as "already
// gone" and forgets it without calling DeleteInstance, and treats a successful
// DeleteInstance as "gone". So: a host that cannot be enumerated is an ERROR
// (ErrEnumerationUnavailable), never an empty list or ErrNotFound; and a
// teardown that exits non-zero is an ERROR, never idempotent success (the
// daemon side already exits 0 for an absent instance).
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
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
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
	if err := b.label(ctx, args); err != nil {
		return Instance{}, err
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
// idempotent: a transport/auth failure is surfaced, but a non-zero worker exit
// (the guest is already gone) is treated as success so a repeated Delete of an
// absent instance still reports success — matching the local backends' contract.
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
		// NOT idempotent success. `ephemeral-destroy` already exits 0 for an
		// instance that is absent (that is where idempotence lives, next to the
		// state it can see). A non-zero exit therefore means the teardown did
		// NOT complete — incus `dataset is busy`, a libvirt domain that
		// survived `undefine`, an unreachable hypervisor — and the guest may
		// still exist. Reporting success here is what let GARM forget ~100
		// STOPPED containers on gpu-server-001/002 until their pool filled.
		// Surfacing it keeps the instance in pending_delete, so GARM retries.
		return fmt.Errorf("remote Delete %s: teardown worker exit %d; the instance may still exist", idOrName, code)
	}
	return nil
}

// Attribution labels recorded on the daemon host for every instance this
// provider creates (see `ephemeral-label` in vm-harness). List filters on them
// so a pool is shown only its own instances.
const (
	labelPool       = "garm-pool"
	labelController = "garm-controller"
	// inventoryMarker is the key of the single result line `ephemeral-list`
	// prints into the (merged stdout+stderr) worker log stream.
	inventoryMarker = "vmhEphemeralList"
	// listTimeout bounds one enumeration round-trip. Enumeration is a couple of
	// `virsh`/`incus` calls on the daemon host; a minute is generous.
	listTimeout = 60 * time.Second
	// usageExitCode is what vm-harness exits with for an unknown verb or flag,
	// i.e. what a daemon older than `ephemeral-label` answers.
	usageExitCode = 2
)

// ErrEnumerationUnavailable marks a failure to enumerate the remote host. It
// is deliberately NOT garmErrors.ErrNotFound: GARM treats "not found" / "not
// in the list" as "already gone" and forgets the instance without deleting it.
var ErrEnumerationUnavailable = errors.New("remote instance enumeration unavailable")

// label records pool/controller attribution for a freshly created instance.
//
// Why a failure here fails the CREATE: an instance nobody can attribute is
// invisible to its pool's ListInstances, and GARM's scale-set reconciler
// removes a runner the provider does not list. Better that GARM sees a failed
// create (and deletes + retries it, as it does for any create error) than a
// live runner that the next reconcile pass tears down.
//
// The one tolerated failure is a daemon too old to know the verb (usage exit
// 2): refusing every create during a rolling upgrade would be an outage, and
// such a daemon also cannot answer `ephemeral-list`, so List fails closed for
// that host anyway and nothing is removed on the strength of an absent label.
func (b *RemoteBackend) label(ctx context.Context, args CreateArgs) error {
	if args.PoolID == "" && args.ControllerID == "" {
		return nil
	}
	argv := []string{"ephemeral-label", "--backend", b.TargetBackend, "--baseline", args.Name}
	if args.PoolID != "" {
		argv = append(argv, "--label", labelPool+"="+args.PoolID)
	}
	if args.ControllerID != "" {
		argv = append(argv, "--label", labelController+"="+args.ControllerID)
	}
	argv = append(argv, "--log-format", "json")
	code, err := b.Client.ExecStream(ctx, argv, logToStderr("label "+args.Name))
	if err != nil {
		return fmt.Errorf("remote Create %s: recording ownership labels: %w", args.Name, err)
	}
	switch code {
	case 0:
		return nil
	case usageExitCode:
		fmt.Fprintf(os.Stderr, "remote Create %s: daemon does not support ephemeral-label (exit 2); instance is unattributed until the daemon is upgraded\n", args.Name)
		return nil
	default:
		return fmt.Errorf("remote Create %s: recording ownership labels: worker exit %d", args.Name, code)
	}
}

// inventoryLine is the JSON shape of `ephemeral-list`'s result line.
type inventoryLine struct {
	Marker    *int   `json:"vmhEphemeralList"`
	Backend   string `json:"backend"`
	Instances []struct {
		Name   string            `json:"name"`
		State  string            `json:"state"`
		Labels map[string]string `json:"labels"`
	} `json:"instances"`
}

// inventory runs `ephemeral-list` on the daemon host and returns the matching
// instances. It FAILS CLOSED: a transport or auth error, a non-zero exit (the
// daemon could not enumerate, or predates the verb), or a stream with no
// result line is an ERROR wrapping ErrEnumerationUnavailable — never an empty
// slice. An empty slice is returned only when the daemon positively
// enumerated the host and found nothing matching.
func (b *RemoteBackend) inventory(ctx context.Context, filter ...string) ([]Instance, error) {
	cctx, cancel := context.WithTimeout(ctx, listTimeout)
	defer cancel()
	argv := append([]string{"ephemeral-list", "--backend", b.TargetBackend}, filter...)
	argv = append(argv, "--log-format", "json")

	var result *inventoryLine
	var parseErr error
	var diag []string
	code, err := b.Client.ExecStream(cctx, argv, func(ev ExecEvent) {
		switch ev.Kind {
		case "log":
			line := strings.TrimSpace(ev.Line)
			if !strings.Contains(line, inventoryMarker) {
				if len(diag) < 5 {
					diag = append(diag, line)
				}
				return
			}
			var inv inventoryLine
			if e := json.Unmarshal([]byte(line), &inv); e != nil || inv.Marker == nil {
				parseErr = fmt.Errorf("undecodable ephemeral-list result %q: %v", line, e)
				return
			}
			result = &inv
		case "error":
			diag = append(diag, ev.Message)
		}
	})
	if err != nil {
		return nil, fmt.Errorf("%w: %s: %w", ErrEnumerationUnavailable, b.Client.Endpoint, err)
	}
	if code != 0 {
		return nil, fmt.Errorf("%w: %s: ephemeral-list --backend %s exited %d: %s",
			ErrEnumerationUnavailable, b.Client.Endpoint, b.TargetBackend, code, strings.Join(diag, " | "))
	}
	if parseErr != nil {
		return nil, fmt.Errorf("%w: %s: %w", ErrEnumerationUnavailable, b.Client.Endpoint, parseErr)
	}
	if result == nil {
		return nil, fmt.Errorf("%w: %s: ephemeral-list printed no result line", ErrEnumerationUnavailable, b.Client.Endpoint)
	}
	out := make([]Instance, 0, len(result.Instances))
	for _, it := range result.Instances {
		out = append(out, Instance{
			ProviderID:   it.Name,
			Name:         it.Name,
			ControllerID: it.Labels[labelController],
			PoolID:       it.Labels[labelPool],
			OSName:       b.GuestOS,
			Status:       it.State,
		})
	}
	return out, nil
}

// Get returns one instance's view from the daemon host's own enumeration.
// Absent => garmErrors.ErrNotFound; enumeration failure => an error that is
// NOT ErrNotFound, so a live runner is never reported gone over a blind spot.
func (b *RemoteBackend) Get(ctx context.Context, idOrName string) (Instance, error) {
	insts, err := b.inventory(ctx, "--name", idOrName)
	if err != nil {
		return Instance{}, err
	}
	for _, inst := range insts {
		if inst.Name == idOrName {
			return inst, nil
		}
	}
	return Instance{}, fmt.Errorf("remote instance %s: %w", idOrName, garmErrors.ErrNotFound)
}

// List returns the instances attributed to poolID on the daemon host.
//
// This used to return an EMPTY LIST unconditionally (the RB1 protocol had no
// enumeration). GARM's orphaned-runner sweep reads "not in ListInstances" as
// "the provider already lost it" and deletes the record WITHOUT calling
// DeleteInstance, so every runner still offline in GitHub five minutes after
// creation — every Windows guest, which takes longer than that to boot and
// register — was forgotten while its VM kept running: ~210 leaked domains
// (55 GiB) on high-mem-server in a day.
//
// Filtering by pool is load-bearing, not cosmetic: GARM's scale-set worker
// DELETES listed instances it has no record of, so a host-wide list would let
// one pool destroy another's runners.
func (b *RemoteBackend) List(ctx context.Context, poolID string) ([]Instance, error) {
	if poolID == "" {
		return nil, fmt.Errorf("%w: refusing to list without a pool ID (a host-wide list is unsafe)", ErrEnumerationUnavailable)
	}
	return b.inventory(ctx, "--label", labelPool+"="+poolID)
}

// ListByController returns the instances attributed to controllerID (used by
// RemoveAllInstances, which deletes everything returned — hence the same
// refusal to answer host-wide).
func (b *RemoteBackend) ListByController(ctx context.Context, controllerID string) ([]Instance, error) {
	if controllerID == "" {
		return nil, fmt.Errorf("%w: refusing to list without a controller ID (a host-wide list is unsafe)", ErrEnumerationUnavailable)
	}
	return b.inventory(ctx, "--label", labelController+"="+controllerID)
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

// Ensure RemoteBackend satisfies the Backend seam.
var _ Backend = (*RemoteBackend)(nil)
