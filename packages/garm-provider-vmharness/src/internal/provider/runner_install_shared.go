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

// Runner-install surface shared with sibling providers in this Go module.
//
// garm-provider-agentharbor (cmd/garm-provider-agentharbor) launches runners
// through agent-harbor's direct sandbox-launch REST API instead of a VM
// backend. It must hand the sandbox the SAME JIT runner-install scripts this
// provider renders (GARM upstream's cloudconfig template plus the cached-runner
// version guard, and this package's own templates), so the templates live
// here once and are exported through the thin wrappers below rather than
// copied.

import (
	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
)

// PickTools selects the runner tools entry matching the bootstrap's OS/arch.
func PickTools(bootstrapParams commonParams.BootstrapInstance) (commonParams.RunnerApplicationDownload, error) {
	return pickTools(bootstrapParams)
}

// RenderUpstreamRunnerInstallScript renders GARM upstream's default runner
// install script (garm-provider-common cloudconfig, honouring a pool's
// `runner_install_template` extra spec) with the cached-runner version guard
// injected. The script expects root in a full guest OS (it creates the runner
// user and runs installdependencies.sh), so it suits VM substrates.
func RenderUpstreamRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	return renderRunnerBootstrapForBackend(config.BackendIncus, bootstrapParams, tools, runnerName)
}

// ApplyGuestURLOverrides replaces the metadata/callback URLs GARM hands the
// runner (and every occurrence inside the pool's cloudconfig extra specs) with
// the guest-reachable ones. Empty overrides leave the originals untouched.
func ApplyGuestURLOverrides(bootstrapParams commonParams.BootstrapInstance, metadataURL, callbackURL string) commonParams.BootstrapInstance {
	return applyGuestURLOverrides(bootstrapParams, &config.Config{
		GuestMetadataURL: metadataURL,
		GuestCallbackURL: callbackURL,
	})
}

// OfferedRunnerVersion is the actions/runner version GARM offers in a tools
// entry ("" when none is derivable).
func OfferedRunnerVersion(tools commonParams.RunnerApplicationDownload) string {
	return offeredRunnerVersion(tools)
}

// ShellQuote single-quotes s for POSIX shells (the templates' `shell` func).
func ShellQuote(s string) string {
	return shellQuote(s)
}
