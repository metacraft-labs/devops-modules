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
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestBuildDomainXMLAttachesConfigDrive asserts that when a config-drive ISO
// path is supplied, the rendered domain XML attaches it as a read-only CD-ROM
// (the cloudbase-init ConfigDrive datasource), and that it is absent otherwise.
func TestBuildDomainXMLAttachesConfigDrive(t *testing.T) {
	args := CreateArgs{
		Name:        "m3-inject",
		SourceImage: "/var/lib/garm/golden/windows-runner.qcow2",
		Network:     "default",
	}

	// Without a config-drive: no CD-ROM.
	plain := buildDomainXML(args, "<x/>", "")
	if strings.Contains(plain, "device='cdrom'") {
		t.Fatalf("did not expect a CD-ROM without a config-drive:\n%s", plain)
	}

	// With a config-drive: a read-only CD-ROM pointing at the ISO.
	iso := "/var/lib/libvirt/images/m3-inject.config-drive.iso"
	withCD := buildDomainXML(args, "<x/>", iso)
	for _, want := range []string{"device='cdrom'", iso, "<readonly/>", "bus='sata'"} {
		if !strings.Contains(withCD, want) {
			t.Fatalf("config-drive XML missing %q:\n%s", want, withCD)
		}
	}
	// The boot disk (golden) must still be present.
	if !strings.Contains(withCD, args.SourceImage) {
		t.Fatalf("boot disk missing from XML:\n%s", withCD)
	}
}

// TestBuildConfigDriveISO builds a real config-drive ISO (when an ISO tool is
// available) and asserts it carries the openstack layout + config-2 label +
// the injected user_data payload.
func TestBuildConfigDriveISO(t *testing.T) {
	haveTool := false
	for _, b := range []string{"genisoimage", "mkisofs", "xorriso"} {
		if _, err := exec.LookPath(b); err == nil {
			haveTool = true
			break
		}
	}
	if !haveTool {
		t.Skip("no genisoimage/mkisofs/xorriso on PATH")
	}

	dir := t.TempDir()
	iso := filepath.Join(dir, "m3-inject.config-drive.iso")
	userData := []byte("#ps1_sysnative\nWrite-Output HELLO-M3-PROVIDER\n")

	got, err := buildConfigDriveISO(context.Background(), iso, "m3-inject", userData)
	if err != nil {
		t.Fatalf("buildConfigDriveISO: %v", err)
	}
	if got != iso {
		t.Fatalf("expected %q, got %q", iso, got)
	}
	raw, err := os.ReadFile(iso)
	if err != nil {
		t.Fatalf("reading ISO: %v", err)
	}
	blob := string(raw)
	for _, want := range []string{"config-2", "user_data", "HELLO-M3-PROVIDER"} {
		if !strings.Contains(blob, want) {
			t.Fatalf("config-drive ISO missing %q", want)
		}
	}
}

// TestConfigDriveISOPath asserts the per-job ISO path naming (so teardown
// removes exactly it, never the golden or a shared ISO).
func TestConfigDriveISOPath(t *testing.T) {
	p := configDriveISOPath("/var/lib/libvirt/images", "job-42")
	want := "/var/lib/libvirt/images/job-42.config-drive.iso"
	if p != want {
		t.Fatalf("expected %q, got %q", want, p)
	}
}
