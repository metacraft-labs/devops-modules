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

// Command garm-provider-agentharbor is GARM's stateless external provider for
// ephemeral runners launched as agent-harbor sandbox jobs over ah's REST
// direct-sandbox-launch endpoints (Sovereign-CI-Fleet AH3).
//
// Protocol plumbing (GARM_* env, stdin BootstrapInstance, stdout JSON, exit
// codes 30/31) is garm-provider-common/execution, exactly as in
// garm-provider-vmharness.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/cloudbase/garm-provider-common/execution"
	commonExecution "github.com/cloudbase/garm-provider-common/execution/common"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/agentharbor"
)

func main() {
	ctx := context.Background()

	// Scale-set mode leaves GARM_POOL_ID empty for instance-scoped commands,
	// but garm-provider-common's env validation requires it. This provider
	// addresses jobs by instance name / provider_id only, so a placeholder is
	// harmless (same workaround as garm-provider-vmharness).
	switch commonExecution.ExecutionCommand(os.Getenv("GARM_COMMAND")) {
	case commonExecution.DeleteInstanceCommand,
		commonExecution.GetInstanceCommand,
		commonExecution.StartInstanceCommand,
		commonExecution.StopInstanceCommand:
		if os.Getenv("GARM_POOL_ID") == "" {
			_ = os.Setenv("GARM_POOL_ID", "scaleset")
		}
	}

	env, err := execution.GetEnvironment()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to get environment: %s\n", err)
		os.Exit(1)
	}

	prov, err := agentharbor.New(env.ProviderConfigFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to initialise provider: %s\n", err)
		os.Exit(1)
	}

	ret, err := env.Run(ctx, prov)
	if err != nil {
		code := commonExecution.ResolveErrorToExitCode(err)
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(code)
	}
	if ret != "" {
		fmt.Fprint(os.Stdout, ret)
	}
}
