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

// Gate t_domainxml_currentmemory (campaign milestone W1).
//
// buildDomainXML is a pure function over CreateArgs, so this gate is fully
// hermetic: no libvirt, no virsh (not even the mock), no filesystem. It uses no
// mock objects at all — the unit under test IS the real string builder that
// feeds `virsh define`.
//
// The load-bearing assertion is TestBuildDomainXMLCurrentMemoryUnsetIsByteIdentical:
// it pins the ENTIRE pre-W1 rendering as a literal, so adding the
// <currentMemory>/<memballoon> lines cannot perturb the XML of any domain that
// does not ask for a balloon target. That is what lets W1 land before W0
// (the guest-side balloon driver) without reshaping running VMs.
package backend

import (
	"strings"
	"testing"
)

// baseArgs is the plainest domain the builder can render: no UEFI, no
// config-drive, no explicit disk overlay. Kept minimal so the byte-identical
// golden below stays readable.
func baseArgs() CreateArgs {
	return CreateArgs{
		Name:        "garm-win-0001",
		SourceImage: "/var/lib/libvirt/images/win11-golden.qcow2",
		Network:     "garmnet",
		MemoryMB:    8192,
		VCPUs:       4,
	}
}

// wantPreW1 is the EXACT XML buildDomainXML emitted before W1 for baseArgs()
// with metaInner "<meta/>" and no config-drive. Transcribed from the pre-W1
// template; any drift here is a real change in the shape of every domain the
// provider defines.
const wantPreW1 = `<domain type='kvm'>
  <name>garm-win-0001</name>
  <metadata>
<meta/>
  </metadata>
  <memory unit='MiB'>8192</memory>
  <vcpu>4</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/win11-golden.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='garmnet'/>
      <model type='virtio'/>
    </interface>
    <graphics type='vnc' port='-1'/>
    <video>
      <model type='qxl'/>
    </video>
    <console type='pty'/>
  </devices>
</domain>
`

// TestBuildDomainXMLCurrentMemoryUnsetIsByteIdentical is the regression lock:
// with CurrentMemoryMB left at its zero value the output must equal the pre-W1
// rendering byte for byte.
func TestBuildDomainXMLCurrentMemoryUnsetIsByteIdentical(t *testing.T) {
	got := buildDomainXML(baseArgs(), "<meta/>", "")
	if got != wantPreW1 {
		t.Errorf("domain XML changed shape with CurrentMemoryMB unset.\n--- got ---\n%s\n--- want ---\n%s",
			got, wantPreW1)
	}
}

// TestBuildDomainXMLCurrentMemorySet checks the whole-document rendering when a
// balloon target below the ceiling is requested: <currentMemory> immediately
// after <memory>, and an explicit <memballoon model='virtio'/> in <devices>.
// Asserted as a full-document comparison (not a substring probe) so a target
// emitted in the wrong place fails.
func TestBuildDomainXMLCurrentMemorySet(t *testing.T) {
	args := baseArgs()
	args.CurrentMemoryMB = 2048

	want := strings.Replace(wantPreW1,
		"  <memory unit='MiB'>8192</memory>\n",
		"  <memory unit='MiB'>8192</memory>\n  <currentMemory unit='MiB'>2048</currentMemory>\n",
		1)
	want = strings.Replace(want,
		"    <console type='pty'/>\n",
		"    <console type='pty'/>\n    <memballoon model='virtio'/>\n",
		1)

	got := buildDomainXML(args, "<meta/>", "")
	if got != want {
		t.Errorf("domain XML with CurrentMemoryMB=2048 mismatch.\n--- got ---\n%s\n--- want ---\n%s",
			got, want)
	}
}

// TestBuildDomainXMLCurrentMemoryDegenerate covers every value that must NOT
// produce a balloon target: unset, negative, exactly the ceiling, and above the
// ceiling (a target >= <memory> would mean an empty balloon, so it is dropped
// rather than emitted as a no-op). All must render the pre-W1 XML.
func TestBuildDomainXMLCurrentMemoryDegenerate(t *testing.T) {
	cases := []struct {
		name    string
		current int
	}{
		{"unset", 0},
		{"negative", -1},
		{"equal to ceiling", 8192},
		{"above ceiling", 16384},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			args := baseArgs()
			args.CurrentMemoryMB = tc.current
			got := buildDomainXML(args, "<meta/>", "")
			if strings.Contains(got, "currentMemory") {
				t.Errorf("CurrentMemoryMB=%d emitted <currentMemory>, want it omitted:\n%s",
					tc.current, got)
			}
			if strings.Contains(got, "memballoon") {
				t.Errorf("CurrentMemoryMB=%d emitted <memballoon>, want it omitted:\n%s",
					tc.current, got)
			}
			if got != wantPreW1 {
				t.Errorf("CurrentMemoryMB=%d changed the XML.\n--- got ---\n%s\n--- want ---\n%s",
					tc.current, got, wantPreW1)
			}
		})
	}
}

// TestBuildDomainXMLCurrentMemoryAgainstDefaultCeiling pins the interaction
// with the builder's own MemoryMB default: when MemoryMB is unset the ceiling
// is 4096, so a target must be compared against the EFFECTIVE ceiling, not
// against the zero the caller passed. 2048 is below it (emitted); 4096 is not
// (dropped).
func TestBuildDomainXMLCurrentMemoryAgainstDefaultCeiling(t *testing.T) {
	args := baseArgs()
	args.MemoryMB = 0
	args.CurrentMemoryMB = 2048
	got := buildDomainXML(args, "<meta/>", "")
	if !strings.Contains(got, "  <memory unit='MiB'>4096</memory>\n  <currentMemory unit='MiB'>2048</currentMemory>\n") {
		t.Errorf("target below the DEFAULT ceiling was not emitted:\n%s", got)
	}

	args.CurrentMemoryMB = 4096
	got = buildDomainXML(args, "<meta/>", "")
	if strings.Contains(got, "currentMemory") {
		t.Errorf("target equal to the DEFAULT ceiling should be dropped:\n%s", got)
	}
}

// TestBuildDomainXMLCurrentMemoryUEFIPath checks the target survives the other
// major rendering path (OVMF pflash + hyperv + config-drive), where several
// optional blocks sit between <memory> and <devices>. This is the path the real
// Windows runners take.
func TestBuildDomainXMLCurrentMemoryUEFIPath(t *testing.T) {
	args := baseArgs()
	args.DiskSource = "/var/lib/libvirt/images/garm-win-0001.overlay.qcow2"
	args.UEFILoader = "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd"
	args.UEFINVRAM = "/var/lib/libvirt/images/garm-win-0001.nvram.fd"
	args.UEFINVRAMTemplate = "/run/libvirt/nix-ovmf/edk2-i386-vars.fd"
	args.CurrentMemoryMB = 8192
	args.MemoryMB = 65536

	got := buildDomainXML(args, "<meta/>", "/var/lib/libvirt/images/garm-win-0001.iso")

	if !strings.Contains(got, "  <memory unit='MiB'>65536</memory>\n  <currentMemory unit='MiB'>8192</currentMemory>\n  <vcpu>4</vcpu>\n") {
		t.Errorf("UEFI path: <currentMemory> not emitted between <memory> and <vcpu>:\n%s", got)
	}
	if !strings.Contains(got, "    <memballoon model='virtio'/>\n  </devices>\n") {
		t.Errorf("UEFI path: <memballoon> not emitted inside <devices>:\n%s", got)
	}
	// The balloon must not have displaced the UEFI/config-drive rendering.
	if !strings.Contains(got, "<loader readonly='yes' type='pflash' format='raw'>") ||
		!strings.Contains(got, "<smm state='on'/>") ||
		!strings.Contains(got, "device='cdrom'") {
		t.Errorf("UEFI path: expected blocks missing:\n%s", got)
	}
}
