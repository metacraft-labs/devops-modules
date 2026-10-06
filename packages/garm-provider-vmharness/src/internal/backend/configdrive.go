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
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// M3: config-drive injection.
//
// On libvirt there is no cloud metadata service, so the rendered GARM runner
// bootstrap (CreateArgs.Bootstrap — the Windows PowerShell JIT script) is
// delivered into the guest via a cloudbase-init ConfigDrive: an ISO9660 volume
// labelled `config-2` carrying the OpenStack config-drive layout
//
//	openstack/latest/meta_data.json   (instance identity)
//	openstack/latest/user_data        (the bootstrap; cloudbase-init's
//	                                   userdata plugin runs it on first boot)
//
// The golden has cloudbase-init installed + configured for the ConfigDrive
// datasource, so attaching this ISO as a read-only CD-ROM causes the guest to
// fetch the JIT config from GARM's metadata endpoint (per-instance JWT) and
// launch the actions runner on first boot. This mirrors vm-harness's
// buildConfigDriveIso (the same layout + `config-2` label).

// configDriveISOPath is the per-job config-drive ISO path (next to the domain
// overlay so teardown removes exactly it).
func configDriveISOPath(poolDir, name string) string {
	return filepath.Join(poolDir, name+".config-drive.iso")
}

// buildConfigDriveISO writes a cloudbase-init ConfigDrive ISO at isoPath
// carrying the rendered bootstrap as openstack/latest/user_data plus a minimal
// meta_data.json. It prefers genisoimage/mkisofs and falls back to xorriso. The
// volume label MUST be `config-2` (cloudbase-init's ConfigDrive datasource
// probes for it). Returns isoPath on success.
func buildConfigDriveISO(ctx context.Context, isoPath, name string, userData []byte) (string, error) {
	staging, err := os.MkdirTemp("", "garm-configdrive-")
	if err != nil {
		return "", fmt.Errorf("configdrive staging: %w", err)
	}
	defer os.RemoveAll(staging)

	osDir := filepath.Join(staging, "openstack", "latest")
	if err := os.MkdirAll(osDir, 0o755); err != nil {
		return "", fmt.Errorf("configdrive layout: %w", err)
	}
	meta := map[string]string{"uuid": name, "hostname": name, "name": name}
	metaBytes, err := json.Marshal(meta)
	if err != nil {
		return "", fmt.Errorf("meta_data.json: %w", err)
	}
	if err := os.WriteFile(filepath.Join(osDir, "meta_data.json"), metaBytes, 0o644); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(osDir, "user_data"), userData, 0o644); err != nil {
		return "", err
	}

	// genisoimage / mkisofs first, then xorriso's mkisofs emulation.
	type isoCmd struct {
		bin  string
		args []string
	}
	candidates := []isoCmd{
		{"genisoimage", []string{"-quiet", "-output", isoPath, "-volid", "config-2", "-joliet", "-rock", staging}},
		{"mkisofs", []string{"-quiet", "-output", isoPath, "-volid", "config-2", "-joliet", "-rock", staging}},
		{"xorriso", []string{"-as", "mkisofs", "-quiet", "-o", isoPath, "-V", "config-2", "-J", "-R", staging}},
	}
	var lastErr error
	for _, c := range candidates {
		if _, err := exec.LookPath(c.bin); err != nil {
			continue
		}
		cmd := exec.CommandContext(ctx, c.bin, c.args...)
		if out, err := cmd.CombinedOutput(); err != nil {
			lastErr = fmt.Errorf("%s: %w: %s", c.bin, err, string(out))
			continue
		}
		return isoPath, nil
	}
	if lastErr != nil {
		return "", lastErr
	}
	return "", fmt.Errorf("no ISO tool (genisoimage/mkisofs/xorriso) found on PATH")
}
