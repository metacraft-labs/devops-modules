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

// Package backend is the vm-harness / libvirt SEAM the stateless provider
// shells to. The provider itself holds NO lifecycle state; every query
// (GetInstance/ListInstances) is recomputed from the backend, and identity ->
// domain mapping is carried entirely in the libvirt domain's <metadata>
// (controller_id / pool_id / name), never in a provider-owned store.
//
// M1 implements the VirshBackend: it shells to `virsh` for the domain
// lifecycle. The per-job clone-from-golden (M2) and config-drive injection
// (M3) are kept behind explicit CreateArgs fields so those milestones can wire
// the real vm-harness path without changing the protocol surface. The M1
// hermetic gate drives this same code against a MOCK virsh (no KVM), so the
// real command construction + metadata round-trip are exercised.
package backend

import "context"

// Instance is the backend's view of a per-job VM (a libvirt domain), recomputed
// from the backend on every query. It is stateless from the provider's side.
type Instance struct {
	// ProviderID is the stable provider-side identifier. For libvirt we use the
	// domain UUID when available, falling back to the domain name.
	ProviderID string
	// Name is the domain name (== BootstrapInstance.Name, GARM's unique name).
	Name string
	// ControllerID / PoolID are recovered from the domain <metadata> tags.
	ControllerID string
	PoolID       string
	// Status is the mapped power state: "running", "stopped", or "error".
	Status string
	// OSName / OSVersion are recovered from metadata (set at create time from
	// the resolved golden image).
	OSName    string
	OSVersion string
	OSArch    string
	// Addresses are IP addresses reported for the domain, if any.
	Addresses []string
}

// CreateArgs carries everything CreateInstance needs to materialise a per-job
// domain. The SourceImage + Bootstrap fields are the M2/M3 seam: in M1 the
// backend records them into metadata and (against a mock) treats the actual
// clone + injection as a no-op.
type CreateArgs struct {
	Name         string
	ControllerID string
	PoolID       string
	// SourceImage is the resolved golden qcow2/volume to clone from (M2).
	SourceImage string
	OSName      string
	OSVersion   string
	OSArch      string
	Flavor      string
	Network     string
	// Bootstrap is the rendered runner bootstrap (PowerShell for Windows) that
	// M3 injects into the guest via config-drive. Carried through the seam now.
	Bootstrap []byte

	// DiskSource is the resolved per-job boot disk the domain XML points at
	// (the CoW overlay created from SourceImage). When empty, buildDomainXML
	// falls back to SourceImage — the M1 hermetic/mock path that never boots a
	// real guest.
	DiskSource string
	// UEFI firmware for the per-job domain (Windows 11 needs UEFI). When
	// UEFILoader is set the domain boots via OVMF pflash with a per-job
	// writable nvram copied from UEFINVRAMTemplate; otherwise SeaBIOS.
	UEFILoader        string
	UEFINVRAM         string
	UEFINVRAMTemplate string
	// MemoryMB / VCPUs size the domain. Zero => defaults (4096 MiB / 2 vCPU).
	MemoryMB int
	VCPUs    int
	// CurrentMemoryMB is the virtio-balloon BOOT TARGET (<currentMemory>): the
	// amount the guest is asked to hold at power-on, with MemoryMB - this
	// parked in the balloon. It is a request, not a cap — a guest without the
	// balloon driver ignores it and boots with the full MemoryMB. Zero (or any
	// value outside 0 < n < MemoryMB) means "no target": the domain XML is
	// emitted exactly as it was before this field existed.
	CurrentMemoryMB int
}

// Backend is the seam the provider shells to. Every method is a thin wrapper
// over an external tool invocation (virsh today; vm-harness for clone/inject in
// M2/M3). No method persists state in the provider.
type Backend interface {
	// Create materialises a per-job domain tagged with controller/pool/name
	// metadata and returns its provider-side view (with a provider_id).
	Create(ctx context.Context, args CreateArgs) (Instance, error)
	// Delete destroys + undefines the domain identified by idOrName. It MUST be
	// idempotent: absence is success (ErrNotFound is surfaced so the caller can
	// map it to GARM's exit code 30, but Delete's own contract treats absence as
	// a no-op).
	Delete(ctx context.Context, idOrName string) error
	// Get returns one domain's view by provider_id or name. Returns ErrNotFound
	// when absent.
	Get(ctx context.Context, idOrName string) (Instance, error)
	// List returns all domains tagged with poolID.
	List(ctx context.Context, poolID string) ([]Instance, error)
	// ListByController returns all domains tagged with controllerID (used by
	// RemoveAllInstances).
	ListByController(ctx context.Context, controllerID string) ([]Instance, error)
	// Start boots the domain identified by idOrName.
	Start(ctx context.Context, idOrName string) error
	// Stop shuts down the domain identified by idOrName (graceful shutdown;
	// force uses destroy).
	Stop(ctx context.Context, idOrName string, force bool) error
}
