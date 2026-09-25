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

package provider

// configJSONSchema is the JSON schema for the provider config.toml (returned by
// the GetConfigJSONSchema command). It describes the vm-harness/libvirt backend
// selection, the golden-image map, the libvirt URI, and the network.
const configJSONSchema = `{
	"$schema": "http://json-schema.org/draft-07/schema#",
	"title": "garm-provider-vmharness config",
	"type": "object",
	"properties": {
		"backend": {
			"type": "string",
			"enum": ["libvirt", "incus", "tart-linux-arm", "tart-macos", "utm-windows-arm", "qemu-windows-arm", "remote"],
			"description": "VM management backend: 'libvirt' (Windows/Linux VMs), 'incus' (Linux system containers), an Apple-silicon vm-harness backend, or 'remote' (RB1: an RPC client to a remote vm-harness serve daemon instead of local exec)."
		},
		"remote": {
			"type": "object",
			"description": "RB1 remote-target mode (consulted only when backend == 'remote'): drive a remote 'vm-harness serve' daemon over the RA1 RPC instead of a local backend. Company-agnostic — no host or credential is baked in. Incus capability grants are trusted provider-admin configuration and map only to fixed vm-harness flags; workflow/bootstrap/user-data cannot choose arbitrary Incus keys or devices.",
			"properties": {
				"endpoint": {
					"type": "string",
					"description": "Remote 'vm-harness serve' address as host:port (typically a NetBird overlay IP)."
				},
				"target_backend": {
					"type": "string",
					"description": "vm-harness backend id the REMOTE host drives (forwarded as the remote --backend), eg 'incus', 'libvirt', 'hyperv', 'tart-macos', or 'noop'."
				},
				"auth_token": {
					"type": "string",
					"description": "Bearer token inline (DISCOURAGED — prefer auth_token_file/auth_token_env so the secret is not stored)."
				},
				"auth_token_file": {
					"type": "string",
					"description": "Path the bearer token is read from (systemd LoadCredential / agenix friendly)."
				},
				"auth_token_env": {
					"type": "string",
					"description": "Environment variable the bearer token is read from when the inline/file sources are empty (default VMH_SERVE_TOKEN)."
				},
				"guest_os": {
					"type": "string",
					"description": "Reported guest OS for created instances when the golden-image map carries none (default 'linux')."
				},
				"request_timeout_sec": {
					"type": "integer",
					"description": "Bounds a single non-streaming RPC (/v1/info). 0 uses a built-in default; the create/delete streams are bounded by the remote worker's own --timeout-sec."
				},
				"incus_security_nesting": {
					"type": "boolean",
					"default": false,
					"description": "Remote Incus only: append the fixed vm-harness --incus-security-nesting grant before guest start. The provider does not expose arbitrary Incus config keys. Default false preserves the existing remote create argv."
				},
				"incus_nested_kvm": {
					"type": "boolean",
					"default": false,
					"description": "Remote Incus only: append the fixed vm-harness --incus-nested-kvm grant, which maps only host /dev/kvm at guest /dev/kvm, verifies exact mode 0666, and opens it read-write. Device path and mode are not configurable. Default false preserves the existing remote create argv."
				},
				"incus_limits_cpu": {
					"type": "integer",
					"minimum": 0,
					"default": 0,
					"description": "Remote Incus only: per-job CPU cap, forwarded as vm-harness --cpus and applied as limits.cpu before the container starts. 0 sets no cap and preserves the existing remote create argv."
				},
				"incus_limits_memory_mb": {
					"type": "integer",
					"minimum": 0,
					"default": 0,
					"description": "Remote Incus only: per-job memory cap in MiB, forwarded as vm-harness --memory-mb and applied as limits.memory before the container starts. 0 sets no cap and preserves the existing remote create argv."
				}
			},
			"additionalProperties": false
		},
		"virsh_path": {
			"type": "string",
			"description": "Path to the virsh binary the provider shells to."
		},
		"incus_path": {
			"type": "string",
			"description": "incus invocation for the incus backend (whitespace-split, eg 'incus' or 'sudo -n incus')."
		},
		"incus_bridge": {
			"type": "string",
			"description": "Managed incus bridge the per-job containers attach to (default incusbr0)."
		},
		"incus_ipv4_cidr": {
			"type": "string",
			"description": "Subnet (a.b.c.d/nn) for the injected static IPv4 (incusbr0 DHCP does not lease on this host)."
		},
		"incus_ipv4_gateway": {
			"type": "string",
			"description": "Default gateway for the injected static IPv4 (the incusbr0 host address)."
		},
		"incus_ipv4_range_start": {
			"type": "string",
			"description": "First allocatable static host IPv4 (default .200 of the /24)."
		},
		"incus_ipv4_range_end": {
			"type": "string",
			"description": "Last allocatable static host IPv4 (default .250 of the /24)."
		},
		"incus_nameservers": {
			"type": "array",
			"items": { "type": "string" },
			"description": "DNS resolvers written into the container netplan (default 1.1.1.1, 8.8.8.8)."
		},
		"incus_gpu_passthrough": {
			"type": "boolean",
			"description": "Attach an NVIDIA GPU to each per-job container (incus config device add gpu + nvidia.runtime=true). Requires the host nvidia-container-toolkit. Backs the incus-gpu runner class."
		},
		"incus_share_host_nix_store": {
			"type": "boolean",
			"description": "Wire each per-job container into the host's shared /nix/store (build-farm model): /nix/store mounted read-only (instant cache hits) + the nix-daemon socket mounted so guest builds/writes go through the host daemon (NIX_REMOTE=daemon) and persist to the shared store for later guests. Safe: the guest maps to an untrusted host uid (daemon Trusted:0, cannot escalate); content-addressing prevents poisoning. Backs PM2."
		},
		"incus_reprobuild_store": {
			"type": "string",
			"description": "Host reprobuild content-addressed store path mounted read-write into each per-job container. The BLAKE3 CAS is self-verifying: guest-added entries persist to the shared store for later guests and cannot corrupt existing ones. Empty disables. Backs PM3."
		},
		"incus_reprobuild_store_guest_path": {
			"type": "string",
			"description": "In-guest mount point for the reprobuild store share. Empty mirrors the host path."
		},
		"incus_security_nesting": {
			"type": "boolean",
			"description": "Enable nested containerisation on each per-job container (security.nesting=true + the syscalls.intercept.mknod/.setxattr intercepts fuse-overlayfs needs) so an in-guest Docker/Podman daemon can run and build images unprivileged. Backs the runs-on:incus nested-Docker path (HR1). Default false leaves the container byte-unchanged."
		},
		"incus_nested_kvm": {
			"type": "boolean",
			"description": "Expose the host /dev/kvm into each per-job container with a guest-local mode that lets the unprivileged runner use it, and set security.nesting=true so qemu-system-* -enable-kvm gets hardware-accelerated virtualisation. Backs the runs-on:incus nested-VM path (HR2). Default false leaves the container byte-unchanged."
		},
		"vm_harness_path": {
			"type": "string",
			"description": "Path to the vm-harness binary used for per-job clone (M2) and config-drive injection (M3)."
		},
		"state_dir": {
			"type": "string",
			"description": "State directory for pid/metadata files used by vm-harness-run backends."
		},
		"guest_metadata_url": {
			"type": "string",
			"description": "Optional guest-facing metadata URL override used when a backend needs a different host alias than GARM's global metadata_url."
		},
		"guest_callback_url": {
			"type": "string",
			"description": "Optional guest-facing callback URL override used when a backend needs a different host alias than GARM's global callback_url."
		},
		"libvirt_uri": {
			"type": "string",
			"description": "libvirt connection URI, e.g. qemu:///system."
		},
		"network": {
			"type": "string",
			"description": "libvirt network the per-job domains attach to."
		},
		"images": {
			"type": "object",
			"description": "Map of pool image identifier to a golden source.",
			"additionalProperties": {
				"type": "object",
				"properties": {
					"source_image": {
						"type": "string",
						"description": "Golden qcow2/volume the per-job domain is cloned from."
					},
					"os_name": {
						"type": "string",
						"description": "Reported OS name (e.g. windows)."
					},
					"os_version": {
						"type": "string",
						"description": "Reported OS version (e.g. 2022)."
					}
				}
			}
		}
	},
	"additionalProperties": false
}`

// extraSpecsJSONSchema is the historical JSON schema for per-pool extra_specs.
// It remains permissive for compatibility and advertises two local-Incus names
// that CreateInstance does not currently consume. In particular, remote Incus
// grants never flow through this object: they come only from trusted [remote]
// provider configuration. Formalising the older pool-level surface belongs to
// a separate compatibility milestone.
const extraSpecsJSONSchema = `{
	"$schema": "http://json-schema.org/draft-07/schema#",
	"title": "garm-provider-vmharness extra_specs",
	"type": "object",
	"properties": {
		"source_image": {
			"type": "string",
			"description": "Override the golden source for this pool."
		},
		"incus_security_nesting": {
			"type": "boolean",
			"description": "Enable nested containerisation (security.nesting + fuse-overlayfs syscall intercepts) for this pool's per-job incus containers so an in-guest Docker/Podman daemon can run. Backs the runs-on:incus nested-Docker path (HR1)."
		},
		"incus_nested_kvm": {
			"type": "boolean",
			"description": "Expose the host /dev/kvm into this pool's per-job incus containers with a guest-local mode that lets the unprivileged runner use it, and set security.nesting=true so qemu-system-* -enable-kvm gets hardware-accelerated virtualisation. Backs the runs-on:incus nested-VM path (HR2)."
		}
	},
	"additionalProperties": true
}`
