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
	"fmt"
	"html"
)

// buildDomainXML renders the libvirt domain XML the provider hands to
// `virsh define`. The <metadata> block carries the stateless identity so
// GetInstance/ListInstances can recompute from `virsh dumpxml` alone.
//
// The device model is the M4 per-job Windows model: the boot disk points at
// the CoW overlay (args.DiskSource; falls back to SourceImage for the hermetic
// M1 mock path that never boots), and when args.UEFILoader is set the domain
// boots via OVMF pflash + a per-job writable nvram with the SMM + hyperv
// enlightenments Windows 11 needs. This mirrors, in Go, vm-harness's proven
// buildEphemeralDomainXml (which booted the same golden on real KVM in M2/M3).
// The mock virsh used by the hermetic M1 gate ignores the device model.
func buildDomainXML(args CreateArgs, metaInner, configDriveISO string) string {
	disk := args.DiskSource
	if disk == "" {
		disk = args.SourceImage
	}
	source := html.EscapeString(disk)
	name := html.EscapeString(args.Name)
	network := args.Network
	if network == "" {
		network = "default"
	}
	network = html.EscapeString(network)

	mem := args.MemoryMB
	if mem <= 0 {
		mem = 4096
	}
	vcpus := args.VCPUs
	if vcpus <= 0 {
		vcpus = 2
	}

	// W1: dynamic memory. <memory> is the CEILING the domain may ever reach;
	// <currentMemory> is the balloon's BOOT TARGET, i.e. how much the guest is
	// asked to hold on to at power-on, with the difference parked in the balloon
	// until the guest asks for it back. That makes a large ceiling affordable:
	// the host only pays the floor while the job is idle.
	//
	// Two things this is NOT:
	//   - it is not an enforcement. <currentMemory> is a REQUEST; a guest that
	//     is not running the virtio-balloon driver simply ignores it and boots
	//     with the full <memory>. Until the Windows golden ships balloon.sys +
	//     BLNSVR (campaign milestone W0) this field is inert on Windows guests.
	//   - it is not a way to overcommit past <memory>. A value at or above the
	//     EFFECTIVE ceiling (mem, i.e. after the 4096 MiB default is applied) is
	//     meaningless — the balloon would be empty — and <= 0 means "unset".
	//
	// Both of those degenerate cases are dropped, and when the field is unset
	// the emitted XML is byte-identical to the pre-W1 template — that is the
	// regression lock that lets W1 land before W0 without reshaping any running
	// domain. We also declare <memballoon model='virtio'/> explicitly whenever
	// we emit a target: libvirt adds one by default, but relying on a default
	// for the device that makes the target achievable is not something the XML
	// should leave implicit.
	currentMemLine := ""
	balloonLine := ""
	if args.CurrentMemoryMB > 0 && args.CurrentMemoryMB < mem {
		currentMemLine = fmt.Sprintf("  <currentMemory unit='MiB'>%d</currentMemory>\n",
			args.CurrentMemoryMB)
		balloonLine = "    <memballoon model='virtio'/>\n"
	}

	uefi := args.UEFILoader != ""

	// <os> block: OVMF pflash loader + per-job nvram (UEFI/Windows 11) or a
	// plain hd boot (SeaBIOS) for the mock/hermetic path.
	osBlock := "  <os>\n    <type arch='x86_64' machine='q35'>hvm</type>\n"
	if uefi {
		osBlock += fmt.Sprintf(
			"    <loader readonly='yes' type='pflash' format='raw'>%s</loader>\n",
			html.EscapeString(args.UEFILoader))
		if args.UEFINVRAM != "" {
			if args.UEFINVRAMTemplate != "" {
				osBlock += fmt.Sprintf(
					"    <nvram template='%s' templateFormat='raw' format='raw'>%s</nvram>\n",
					html.EscapeString(args.UEFINVRAMTemplate), html.EscapeString(args.UEFINVRAM))
			} else {
				osBlock += fmt.Sprintf("    <nvram format='raw'>%s</nvram>\n",
					html.EscapeString(args.UEFINVRAM))
			}
		}
	}
	osBlock += "    <boot dev='hd'/>\n  </os>\n"

	// Windows 11 on UEFI requires SMM + APIC; hyperv enlightenments improve
	// stability. The SeaBIOS path keeps a minimal <acpi/><apic/>.
	features := "  <features>\n    <acpi/>\n    <apic/>\n  </features>\n"
	cpuBlock := ""
	clockBlock := ""
	if uefi {
		features = "  <features>\n" +
			"    <acpi/>\n    <apic/>\n" +
			"    <hyperv mode='custom'>\n" +
			"      <relaxed state='on'/>\n" +
			"      <vapic state='on'/>\n" +
			"      <spinlocks state='on' retries='8191'/>\n" +
			"    </hyperv>\n" +
			"    <smm state='on'/>\n" +
			"  </features>\n"
		cpuBlock = "  <cpu mode='host-passthrough'/>\n"
		// UTC, not localtime: the golden's Windows timezone is UTC with the RTC
		// treated as local time (RealTimeIsUniversal unset), so the guest's
		// wall-clock UTC must equal the RTC. offset='localtime' would feed the
		// host's local time (eg UTC+3) as the guest RTC, skewing the guest UTC
		// and making GitHub reject the runner's JIT/OAuth token (its not-before
		// is stamped in the skewed clock) -> "registration has been deleted".
		clockBlock = "  <clock offset='utc'>\n" +
			"    <timer name='rtc' tickpolicy='catchup'/>\n" +
			"    <timer name='hpet' present='no'/>\n" +
			"    <timer name='hypervclock' present='yes'/>\n" +
			"  </clock>\n"
	}

	// M3: attach the cloudbase-init config-drive as a read-only SATA CD-ROM
	// when present, so the guest fetches + runs the injected JIT bootstrap.
	configDrive := ""
	if configDriveISO != "" {
		configDrive = fmt.Sprintf(`    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='%s'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
`, html.EscapeString(configDriveISO))
	}

	return fmt.Sprintf(`<domain type='kvm'>
  <name>%s</name>
  <metadata>
%s
  </metadata>
  <memory unit='MiB'>%d</memory>
%s  <vcpu>%d</vcpu>
%s%s%s%s  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='%s'/>
      <target dev='vda' bus='virtio'/>
    </disk>
%s    <interface type='network'>
      <source network='%s'/>
      <model type='virtio'/>
    </interface>
    <graphics type='vnc' port='-1'/>
    <video>
      <model type='qxl'/>
    </video>
    <console type='pty'/>
%s  </devices>
</domain>
`, name, metaInner, mem, currentMemLine, vcpus, osBlock, features, cpuBlock, clockBlock, source, configDrive, network, balloonLine)
}
