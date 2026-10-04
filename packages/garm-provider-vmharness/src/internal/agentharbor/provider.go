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

// Package agentharbor implements garm-provider-agentharbor: GARM's v0.1.1
// external-provider interface over agent-harbor's direct (no-agent)
// sandbox-launch REST API (agent-harbor specs/REST-Service/
// Direct-Sandbox-Launch.md).
//
// The provider is a THIN, STATELESS client. It persists nothing: GARM's DB is
// the source of truth for which instances should exist, and the ah server's
// job ledger is the source of truth for which do. Every call recomputes from
// the REST API. A GARM instance maps 1:1 onto a sandbox job: the instance name
// is the job `name`, the job `id` (sbj_...) is the GARM provider_id, and the
// job carries garm-controller-id / garm-pool-id labels as owner tags.
package agentharbor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"time"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
	commonExecution "github.com/cloudbase/garm-provider-common/execution/common"
	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/provider"
	"github.com/metacraft-labs/garm-provider-vmharness/internal/version"
)

// Owner-tag labels every job carries.
const (
	LabelController = "garm-controller-id"
	LabelPool       = "garm-pool-id"
	LabelManagedBy  = "garm-managed-by"
	managedByValue  = "garm-provider-agentharbor"
)

// Provider implements executionv011.ExternalProvider.
type Provider struct {
	cfg    *Config
	client *Client
	// now is injectable for manifest-expiry tests.
	now func() time.Time
}

// New builds a Provider from the config file GARM passes.
func New(configFile string) (*Provider, error) {
	cfg, err := Parse(configFile)
	if err != nil {
		return nil, err
	}
	return NewWithConfig(cfg)
}

// NewWithConfig builds a Provider from a parsed config.
func NewWithConfig(cfg *Config) (*Provider, error) {
	token, err := cfg.ResolveToken()
	if err != nil {
		return nil, err
	}
	client, err := NewClient(cfg.Endpoint, AuthHeader(cfg.AuthScheme, token),
		time.Duration(cfg.RequestTimeoutSec)*time.Second, cfg.CACertFile)
	if err != nil {
		return nil, err
	}
	return &Provider{cfg: cfg, client: client, now: time.Now}, nil
}

// poolExtraSpecs are the per-pool overrides (GARM pool `extra_specs` JSON).
// Unknown keys are ignored on purpose: the same JSON also carries GARM's own
// cloudconfig keys (runner_install_template, pre_install_scripts, ...).
type poolExtraSpecs struct {
	TTLSeconds         *uint64 `json:"ttl_seconds,omitempty"`
	IdleTimeoutSeconds *uint64 `json:"idle_timeout_seconds,omitempty"`
	RunnerTemplate     string  `json:"runner_template,omitempty"`
	MemoryMax          string  `json:"memory_max,omitempty"`
	CPUMax             string  `json:"cpu_max,omitempty"`
	PidsMax            uint32  `json:"pids_max,omitempty"`
}

func parseExtraSpecs(raw []byte) (poolExtraSpecs, error) {
	var spec poolExtraSpecs
	if len(raw) == 0 || string(raw) == "null" {
		return spec, nil
	}
	if err := json.Unmarshal(raw, &spec); err != nil {
		return spec, fmt.Errorf("invalid extra_specs: %w", err)
	}
	if spec.TTLSeconds != nil && *spec.TTLSeconds == 0 {
		return spec, fmt.Errorf("extra_specs.ttl_seconds must be > 0")
	}
	switch spec.RunnerTemplate {
	case "", TemplateSandbox, TemplateUpstream:
	default:
		return spec, fmt.Errorf("extra_specs.runner_template %q must be sandbox or upstream", spec.RunnerTemplate)
	}
	return spec, nil
}

// mapError translates the spec's error model (§ Error model) into GARM's error
// kinds. Only NotFound (exit 30) and Duplicate (exit 31) change the exit code
// GARM sees; the others keep the ah `code` in the message so an operator can
// tell a misconfigured pool (400/422/501) from a saturated host (503).
func mapError(op string, err error) error {
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		return fmt.Errorf("%s: %w", op, err)
	}
	msg := fmt.Sprintf("%s: %s", op, apiErr.Error())
	switch {
	case apiErr.Status == http.StatusNotFound:
		return garmErrors.NewNotFoundError("%s", msg)
	case apiErr.Status == http.StatusConflict:
		return garmErrors.NewDuplicateUserError(msg)
	case apiErr.Status == http.StatusUnauthorized || apiErr.Status == http.StatusForbidden:
		return garmErrors.NewUnauthorizedError(msg)
	case apiErr.Status == http.StatusBadRequest ||
		apiErr.Status == http.StatusUnprocessableEntity ||
		apiErr.Status == http.StatusNotImplemented:
		return garmErrors.NewBadRequestError("%s", msg)
	case apiErr.Retryable():
		return garmErrors.NewProviderError("%s (transient, retry later)", msg)
	default:
		return garmErrors.NewProviderError("%s", msg)
	}
}

func (p *Provider) ownerLabels(controllerID string) map[string]string {
	return map[string]string{
		LabelController: controllerID,
		LabelManagedBy:  managedByValue,
	}
}

// verifyHost fetches + verifies the signed capability manifest when a key is
// pinned, and checks that it offers the configured substrate and every ah-*
// label the pool advertises. No key pinned => no check (fail-open is the
// operator's explicit choice by not pinning; documented in the module).
func (p *Provider) verifyHost(ctx context.Context, poolLabels []string) error {
	if !p.cfg.Capabilities.Enabled() {
		return nil
	}
	env, err := p.client.Capabilities(ctx)
	if err != nil {
		return mapError("fetching capability manifest", err)
	}
	m, err := VerifyManifest(env, p.cfg.Capabilities, p.now())
	if err != nil {
		return garmErrors.NewProviderError("capability manifest rejected: %s", err)
	}
	if !m.SubstrateAvailable(p.cfg.Substrate) {
		return garmErrors.NewProviderError("host %s's signed capability manifest does not offer substrate %q", m.ServerID, p.cfg.Substrate)
	}
	if err := m.CheckPoolLabels(poolLabels); err != nil {
		return garmErrors.NewProviderError("%s", err)
	}
	return nil
}

func (p *Provider) renderInstallScript(bootstrap commonParams.BootstrapInstance, template string) ([]byte, error) {
	tools, err := provider.PickTools(bootstrap)
	if err != nil {
		return nil, err
	}
	switch template {
	case TemplateSandbox:
		return provider.RenderLinuxSandboxRunnerInstallScript(bootstrap, tools, bootstrap.Name)
	default:
		return provider.RenderUpstreamRunnerInstallScript(bootstrap, tools, bootstrap.Name)
	}
}

// buildCreateRequest turns GARM's BootstrapInstance into the launch request.
// The runner-install script is the job's stdin; nothing secret goes into env,
// labels or argv (the server never echoes stdin back).
func (p *Provider) buildCreateRequest(bootstrap commonParams.BootstrapInstance, controllerID string) (CreateJobRequest, error) {
	spec, err := parseExtraSpecs(bootstrap.ExtraSpecs)
	if err != nil {
		return CreateJobRequest{}, garmErrors.NewBadRequestError("%s", err)
	}
	template := p.cfg.RunnerTemplate
	if spec.RunnerTemplate != "" {
		template = spec.RunnerTemplate
	}
	script, err := p.renderInstallScript(bootstrap, template)
	if err != nil {
		return CreateJobRequest{}, garmErrors.NewBadRequestError("rendering runner install script: %s", err)
	}
	if len(script) > MaxStdinBytes {
		return CreateJobRequest{}, garmErrors.NewBadRequestError("runner install script is %d bytes, over the %d-byte stdin limit", len(script), MaxStdinBytes)
	}
	stdin := string(script)

	ttl := p.cfg.TTLSeconds
	if spec.TTLSeconds != nil {
		ttl = *spec.TTLSeconds
	}
	var idle *uint64
	if p.cfg.IdleTimeoutSeconds > 0 {
		v := p.cfg.IdleTimeoutSeconds
		idle = &v
	}
	if spec.IdleTimeoutSeconds != nil && *spec.IdleTimeoutSeconds > 0 {
		v := *spec.IdleTimeoutSeconds
		idle = &v
	}
	sandbox := p.cfg.Sandbox
	if spec.MemoryMax != "" {
		sandbox.MemoryMax = spec.MemoryMax
	}
	if spec.CPUMax != "" {
		sandbox.CPUMax = spec.CPUMax
	}
	if spec.PidsMax != 0 {
		sandbox.PidsMax = spec.PidsMax
	}

	labels := p.ownerLabels(controllerID)
	labels[LabelPool] = bootstrap.PoolID

	req := CreateJobRequest{
		Name:               bootstrap.Name,
		Substrate:          p.cfg.Substrate,
		Command:            append([]string(nil), p.cfg.Command...),
		Stdin:              &stdin,
		Env:                p.cfg.Env,
		Labels:             labels,
		TTLSeconds:         &ttl,
		IdleTimeoutSeconds: idle,
		Sandbox:            sandbox,
	}
	// image/flavor are VM concepts; the server rejects them (422) for
	// local-sandbox, so they are only forwarded to VM substrates.
	if p.cfg.Substrate != SubstrateLocalSandbox {
		if bootstrap.Image != "" {
			img := bootstrap.Image
			req.Image = &img
		}
		if bootstrap.Flavor != "" {
			fl := bootstrap.Flavor
			req.Flavor = &fl
		}
	}
	return req, nil
}

// idempotencyKey is deterministic in (controller, instance name), so a
// CreateInstance that GARM retries after a lost response is answered with the
// original job instead of launching a second runner — without the provider
// remembering anything.
func idempotencyKey(controllerID, name string) string {
	return "garm-" + controllerID + "-" + name
}

// CreateInstance launches one ephemeral runner as a sandbox job.
func (p *Provider) CreateInstance(ctx context.Context, bootstrap commonParams.BootstrapInstance) (commonParams.ProviderInstance, error) {
	controllerID := os.Getenv("GARM_CONTROLLER_ID")
	bootstrap = provider.ApplyGuestURLOverrides(bootstrap, p.cfg.GuestMetadataURL, p.cfg.GuestCallbackURL)
	failed := func(err error) (commonParams.ProviderInstance, error) {
		return commonParams.ProviderInstance{
			Name:          bootstrap.Name,
			OSType:        bootstrap.OSType,
			OSArch:        bootstrap.OSArch,
			Status:        commonParams.InstanceError,
			ProviderFault: []byte(err.Error()),
		}, err
	}

	if err := p.verifyHost(ctx, bootstrap.Labels); err != nil {
		return failed(err)
	}
	req, err := p.buildCreateRequest(bootstrap, controllerID)
	if err != nil {
		return failed(err)
	}

	job, err := p.client.CreateJob(ctx, req, idempotencyKey(controllerID, bootstrap.Name))
	if err != nil {
		var apiErr *APIError
		if !errors.As(err, &apiErr) || apiErr.Code != CodeNameConflict {
			return failed(mapError("launching sandbox job", err))
		}
		// 409: a live job already holds this name (a retried create whose
		// idempotency record is gone). Adopt it iff it is OURS; never launch
		// a second one.
		ref := apiErr.ExistingJobID
		if ref == "" {
			ref = bootstrap.Name
		}
		existing, gerr := p.client.GetJob(ctx, ref)
		if gerr != nil {
			return failed(mapError("resolving name conflict", gerr))
		}
		if existing.Labels[LabelController] != controllerID {
			return failed(garmErrors.NewDuplicateUserError(fmt.Sprintf(
				"sandbox job name %q is held by job %s, which this GARM controller does not own", bootstrap.Name, existing.ID)))
		}
		job = existing
	}

	// The cleanupToken is what lets a reaper free the job without the ledger
	// (spec R5/R7, and AH6's no-leak guarantee). A job without one is not
	// leak-safe: tear it down and fail rather than hand GARM an unreapable
	// runner.
	if job.CleanupToken == "" {
		_, _, _ = p.client.DeleteJob(ctx, job.ID)
		return failed(garmErrors.NewProviderError("agent-harbor returned job %s without a cleanupToken; refusing it", job.ID))
	}

	inst := toProviderInstance(job, bootstrap.OSType)
	if job.State == StateFailed {
		reason := "launch failed"
		if job.Error != nil && *job.Error != "" {
			reason = *job.Error
		}
		err := garmErrors.NewProviderError("sandbox job %s failed to launch: %s", job.ID, reason)
		inst.ProviderFault = []byte(err.Error())
		return inst, err
	}
	return inst, nil
}

// DeleteInstance destroys the job. Idempotent: an unknown job (404, including
// an expired tombstone) is success, as the spec requires of clients. When the
// DELETE itself fails for a non-404 reason the provider falls back to the
// job's self-sufficient cleanupToken (POST /sandbox-jobs/cleanup) so a job the
// server can still describe is never stranded.
func (p *Provider) DeleteInstance(ctx context.Context, instance string) error {
	_, _, err := p.client.DeleteJob(ctx, instance)
	if err == nil || IsNotFound(err) {
		return nil
	}
	job, gerr := p.client.GetJob(ctx, instance)
	if IsNotFound(gerr) {
		return nil
	}
	if gerr == nil && job.CleanupToken != "" {
		if _, cerr := p.client.Cleanup(ctx, job.CleanupToken); cerr == nil || IsNotFound(cerr) {
			return nil
		}
	}
	return mapError("destroying sandbox job", err)
}

// GetInstance recomputes one instance from the job record. A tombstoned
// (destroyed) job is reported as not found: to GARM it no longer exists.
func (p *Provider) GetInstance(ctx context.Context, instance string) (commonParams.ProviderInstance, error) {
	job, err := p.client.GetJob(ctx, instance)
	if err != nil {
		return commonParams.ProviderInstance{}, mapError("getting sandbox job", err)
	}
	if job.State == StateDestroyed {
		return commonParams.ProviderInstance{}, garmErrors.NewNotFoundError("sandbox job %s is destroyed", job.ID)
	}
	return toProviderInstance(job, ""), nil
}

// ListInstances lists this controller's live jobs for a pool.
func (p *Provider) ListInstances(ctx context.Context, poolID string) ([]commonParams.ProviderInstance, error) {
	labels := p.ownerLabels(os.Getenv("GARM_CONTROLLER_ID"))
	labels[LabelPool] = poolID
	jobs, err := p.client.ListJobs(ctx, labels)
	if err != nil {
		return nil, mapError("listing sandbox jobs", err)
	}
	out := make([]commonParams.ProviderInstance, 0, len(jobs))
	for _, job := range jobs {
		if job.State == StateDestroyed {
			continue
		}
		out = append(out, toProviderInstance(job, ""))
	}
	return out, nil
}

// RemoveAllInstances destroys every live job this controller owns.
func (p *Provider) RemoveAllInstances(ctx context.Context) error {
	jobs, err := p.client.ListJobs(ctx, p.ownerLabels(os.Getenv("GARM_CONTROLLER_ID")))
	if err != nil {
		return mapError("listing sandbox jobs", err)
	}
	var errs []error
	for _, job := range jobs {
		if job.State == StateDestroyed {
			continue
		}
		if derr := p.DeleteInstance(ctx, job.ID); derr != nil {
			errs = append(errs, derr)
		}
	}
	return errors.Join(errs...)
}

var errNoPowerControl = garmErrors.NewBadRequestError(
	"agent-harbor sandbox jobs are ephemeral and cannot be stopped or restarted; delete the instance instead")

// Stop is unsupported: a sandbox job has no stopped-but-kept state.
func (p *Provider) Stop(ctx context.Context, instance string, force bool) error {
	return errNoPowerControl
}

// Start is unsupported for the same reason.
func (p *Provider) Start(ctx context.Context, instance string) error {
	return errNoPowerControl
}

// GetVersion returns the provider version.
func (p *Provider) GetVersion(ctx context.Context) string {
	return version.Version
}

// GetSupportedInterfaceVersions returns the implemented interface versions.
func (p *Provider) GetSupportedInterfaceVersions(ctx context.Context) []string {
	return []string{commonExecution.Version011}
}

// ValidatePoolInfo validates a pool's extra specs against this provider.
func (p *Provider) ValidatePoolInfo(ctx context.Context, image string, flavor string, providerConfig string, extraspecs string) error {
	spec, err := parseExtraSpecs([]byte(extraspecs))
	if err != nil {
		return garmErrors.NewBadRequestError("%s", err)
	}
	if p.cfg.Substrate != SubstrateLocalSandbox && image == "" {
		return garmErrors.NewBadRequestError("substrate %q needs a pool image", p.cfg.Substrate)
	}
	template := p.cfg.RunnerTemplate
	if spec.RunnerTemplate != "" {
		template = spec.RunnerTemplate
	}
	if template == TemplateUpstream && p.cfg.Substrate == SubstrateLocalSandbox {
		return garmErrors.NewBadRequestError("runner_template \"upstream\" needs root in a full guest OS and cannot run in a local-sandbox job")
	}
	return nil
}

// GetConfigJSONSchema returns the JSON schema of the provider config file.
func (p *Provider) GetConfigJSONSchema(ctx context.Context) (string, error) {
	return configJSONSchema, nil
}

// GetExtraSpecsJSONSchema returns the JSON schema of the per-pool extra specs.
func (p *Provider) GetExtraSpecsJSONSchema(ctx context.Context) (string, error) {
	return extraSpecsJSONSchema, nil
}

// GARMStatus maps an ah job state onto GARM's InstanceStatus (spec
// § Lifecycle table). "destroyed" has no GARM status: the instance is gone.
func GARMStatus(state string) commonParams.InstanceStatus {
	switch state {
	case StatePending:
		return commonParams.InstancePendingCreate
	case StateStarting:
		return commonParams.InstanceCreating
	case StateRunning:
		return commonParams.InstanceRunning
	case StateExited:
		return commonParams.InstanceStopped
	case StateFailed:
		return commonParams.InstanceError
	case StateDestroying:
		return commonParams.InstanceDeleting
	case StateDestroyed:
		return commonParams.InstanceDeleted
	default:
		return commonParams.InstanceStatusUnknown
	}
}

func toProviderInstance(job Job, fallbackOS commonParams.OSType) commonParams.ProviderInstance {
	osType := fallbackOS
	switch job.Host.OS {
	case "linux":
		osType = commonParams.Linux
	case "windows":
		osType = commonParams.Windows
	case "macos", "darwin":
		osType = commonParams.OSType("macos")
	}
	var osArch commonParams.OSArch
	switch job.Host.Arch {
	case "x86_64", "amd64", "x64":
		osArch = commonParams.Amd64
	case "aarch64", "arm64":
		osArch = commonParams.Arm64
	}
	inst := commonParams.ProviderInstance{
		ProviderID: job.ID,
		Name:       job.Name,
		OSType:     osType,
		OSName:     job.Host.OS,
		OSArch:     osArch,
		Status:     GARMStatus(job.State),
	}
	for _, a := range job.Addresses {
		inst.Addresses = append(inst.Addresses, commonParams.Address{Address: a, Type: commonParams.PrivateAddress})
	}
	if job.State == StateFailed && job.Error != nil {
		inst.ProviderFault = []byte(*job.Error)
	}
	return inst
}
