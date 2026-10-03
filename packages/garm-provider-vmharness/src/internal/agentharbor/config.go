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

package agentharbor

import (
	"fmt"
	"net/url"
	"os"
	"strings"

	"github.com/BurntSushi/toml"
)

// Substrates of the direct sandbox-launch API (Direct-Sandbox-Launch.md
// § Concepts), in their wire spelling.
const (
	SubstrateLocalSandbox = "local-sandbox"
	SubstrateVM           = "vm"
	SubstrateCloudVM      = "cloud-vm"
)

// Runner-install templates the provider can hand the sandbox as stdin.
const (
	// TemplateSandbox is the rootless Linux payload for local-sandbox: it
	// fetches the JIT credentials into the job's per-job workspace and execs
	// the host's Nix-packaged actions runner (nixpkgs `github-runner`, see
	// [runner]) the way the NixOS `services.github-runners` module runs it.
	// It downloads nothing. The default for local-sandbox.
	TemplateSandbox = "sandbox"
	// TemplateUpstream is GARM upstream's cloudconfig template (plus the
	// cached-runner version guard). It needs root in a full guest OS, so it is
	// the default for the vm/cloud-vm substrates.
	TemplateUpstream = "upstream"
)

// Authentication schemes of the ah REST service (API.md § Authentication).
const (
	AuthAPIKey = "apikey"
	AuthBearer = "bearer"
	AuthNone   = "none"
)

// DefaultTTLSeconds is GitHub's job ceiling, matching the server default. The
// provider ALWAYS sends an explicit TTL so a runner's lifetime never depends on
// a server-side default the operator did not choose.
const DefaultTTLSeconds = 21600

// Config is the TOML file GARM passes through GARM_PROVIDER_CONFIG_FILE. It
// holds NO secrets: the API credential is read from AuthTokenFile or the
// environment variable AuthTokenEnv at startup.
type Config struct {
	// Backend is accepted for symmetry with the services.garm module, which
	// prefixes every provider config with `backend = "<name>"`; it must be
	// "agentharbor" when present.
	Backend string `toml:"backend"`
	// Endpoint is the ah REST service base URL (scheme://host[:port]); the
	// provider appends /api/v1/... to it.
	Endpoint string `toml:"endpoint"`
	// AuthScheme selects the Authorization header: "apikey" (ApiKey <token>),
	// "bearer" (Bearer <jwt>) or "none" (a loopback per-user daemon without
	// configured auth).
	AuthScheme    string `toml:"auth_scheme"`
	AuthTokenFile string `toml:"auth_token_file"`
	AuthTokenEnv  string `toml:"auth_token_env"`
	// CACertFile optionally pins the CA bundle for an https endpoint.
	CACertFile string `toml:"ca_cert_file"`
	// RequestTimeoutSec bounds each REST call. A launch returns only once the
	// substrate spawned the job, so this must cover a VM boot for vm substrates.
	RequestTimeoutSec int `toml:"request_timeout_sec"`

	// Substrate is where jobs run: local-sandbox | vm | cloud-vm.
	Substrate string `toml:"substrate"`
	// RunnerTemplate is "sandbox" or "upstream" (see the constants above);
	// empty picks the substrate's default.
	RunnerTemplate string `toml:"runner_template"`
	// Command is the argv that executes the install script piped on stdin.
	Command []string `toml:"command"`
	// Env is extra, NON-SECRET environment for every job (the server gives the
	// job only an allow-listed base environment plus this map).
	Env map[string]string `toml:"env"`

	TTLSeconds         uint64 `toml:"ttl_seconds"`
	IdleTimeoutSeconds uint64 `toml:"idle_timeout_seconds"`

	// Guest-reachable GARM URLs, when the sandbox cannot reach the URLs GARM
	// hands out (same meaning as in garm-provider-vmharness).
	GuestMetadataURL string `toml:"guest_metadata_url"`
	GuestCallbackURL string `toml:"guest_callback_url"`

	Sandbox      SandboxOptions     `toml:"sandbox"`
	Capabilities CapabilitiesConfig `toml:"capabilities"`
	// Runner is the Nix-packaged actions runner the `sandbox` payload execs.
	Runner NixRunnerConfig `toml:"runner"`
}

// DefaultMaxMinorLag is the staleness rule of infra's actions-runner pin check
// (services/github-runners/check-runner-version.sh, MAX_MINOR_LAG): a runner
// two or more minor releases behind the latest one is stale, and GitHub soon
// refuses to dispatch jobs to it.
const DefaultMaxMinorLag = 2

// NixRunnerConfig names the host's nixpkgs `github-runner` package, the same
// one (and the same PATH/environment) the host's systemd runners
// (`services.github-runners`) use. The services.garm module renders it from
// the package, so the version guard and infra's pin check judge one version.
type NixRunnerConfig struct {
	// Listener is the absolute path of the package's bin/Runner.Listener.
	Listener string `toml:"listener"`
	// Version is the package's actions/runner version (x.y.z).
	Version string `toml:"version"`
	// Path is the job's PATH, in order (the module's `path`: bash, coreutils,
	// git, gnutar, gzip, nix and the extra packages, as bin directories).
	Path []string `toml:"path"`
	// Env is extra, non-secret runner environment (the module's
	// extraEnvironment).
	Env map[string]string `toml:"env"`
	// MaxMinorLag refuses launches when the package is this many minor
	// releases behind the version GARM offers (default DefaultMaxMinorLag).
	MaxMinorLag int `toml:"max_minor_lag"`
}

// SandboxOptions is the non-interactive subset of `ah agent sandbox` options a
// job may set (Direct-Sandbox-Launch.md § Launch, `sandbox`). Zero values are
// omitted from the request so the server default applies.
type SandboxOptions struct {
	AllowNetwork    *bool  `toml:"allow_network" json:"allowNetwork,omitempty"`
	AllowContainers *bool  `toml:"allow_containers" json:"allowContainers,omitempty"`
	AllowKVM        *bool  `toml:"allow_kvm" json:"allowKvm,omitempty"`
	MemoryMax       string `toml:"memory_max" json:"memoryMax,omitempty"`
	MemoryHigh      string `toml:"memory_high" json:"memoryHigh,omitempty"`
	PidsMax         uint32 `toml:"pids_max" json:"pidsMax,omitempty"`
	CPUMax          string `toml:"cpu_max" json:"cpuMax,omitempty"`
	TmpfsSize       string `toml:"tmpfs_size" json:"tmpfsSize,omitempty"`
}

// CapabilitiesConfig pins the Ed25519 key the host signs its capability
// manifest with. The spec requires verifiers to pin the key out of band; when a
// public key is configured the provider refuses to launch on a host whose
// manifest does not verify, has expired, lacks the configured substrate, or
// does not derive every ah capability label the pool advertises.
type CapabilitiesConfig struct {
	KeyID     string `toml:"key_id"`
	PublicKey string `toml:"public_key"`
}

// Enabled reports whether manifest verification is configured.
func (c CapabilitiesConfig) Enabled() bool { return c.PublicKey != "" }

// Parse reads and validates the provider config file.
func Parse(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading provider config %q: %w", path, err)
	}
	cfg, err := ParseBytes(data)
	if err != nil {
		return nil, fmt.Errorf("provider config %q: %w", path, err)
	}
	return cfg, nil
}

// ParseBytes parses and validates an in-memory TOML config.
func ParseBytes(data []byte) (*Config, error) {
	var cfg Config
	md, err := toml.Decode(string(data), &cfg)
	if err != nil {
		return nil, fmt.Errorf("decoding provider config: %w", err)
	}
	if undecoded := md.Undecoded(); len(undecoded) > 0 {
		keys := make([]string, 0, len(undecoded))
		for _, k := range undecoded {
			keys = append(keys, k.String())
		}
		return nil, fmt.Errorf("unknown provider config keys: %s", strings.Join(keys, ", "))
	}
	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) applyDefaults() {
	c.Endpoint = strings.TrimRight(c.Endpoint, "/")
	if c.AuthScheme == "" {
		c.AuthScheme = AuthAPIKey
	}
	if c.AuthTokenEnv == "" {
		c.AuthTokenEnv = "AH_API_TOKEN"
	}
	if c.RequestTimeoutSec == 0 {
		c.RequestTimeoutSec = 300
	}
	if c.Substrate == "" {
		c.Substrate = SubstrateLocalSandbox
	}
	if c.RunnerTemplate == "" {
		if c.Substrate == SubstrateLocalSandbox {
			c.RunnerTemplate = TemplateSandbox
		} else {
			c.RunnerTemplate = TemplateUpstream
		}
	}
	if len(c.Command) == 0 {
		c.Command = []string{"bash", "-s"}
	}
	if c.TTLSeconds == 0 {
		c.TTLSeconds = DefaultTTLSeconds
	}
	if c.Runner.MaxMinorLag == 0 {
		c.Runner.MaxMinorLag = DefaultMaxMinorLag
	}
}

// Validate checks the config after defaults were applied.
func (c *Config) Validate() error {
	if c.Backend != "" && c.Backend != "agentharbor" {
		return fmt.Errorf("backend %q is not agentharbor", c.Backend)
	}
	if c.Endpoint == "" {
		return fmt.Errorf("endpoint is required")
	}
	u, err := url.Parse(c.Endpoint)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("endpoint %q must be an http(s) URL", c.Endpoint)
	}
	switch c.AuthScheme {
	case AuthAPIKey, AuthBearer, AuthNone:
	default:
		return fmt.Errorf("auth_scheme %q must be one of apikey, bearer, none", c.AuthScheme)
	}
	switch c.Substrate {
	case SubstrateLocalSandbox, SubstrateVM, SubstrateCloudVM:
	default:
		return fmt.Errorf("substrate %q must be one of local-sandbox, vm, cloud-vm", c.Substrate)
	}
	switch c.RunnerTemplate {
	case TemplateSandbox, TemplateUpstream:
	default:
		return fmt.Errorf("runner_template %q must be sandbox or upstream", c.RunnerTemplate)
	}
	if c.Substrate == SubstrateLocalSandbox && c.RunnerTemplate == TemplateUpstream {
		return fmt.Errorf("runner_template upstream needs root in a full guest OS; local-sandbox takes the sandbox payload")
	}
	if c.RunnerTemplate == TemplateSandbox {
		if err := c.Runner.validate(); err != nil {
			return fmt.Errorf("runner: %w", err)
		}
	}
	if c.RequestTimeoutSec < 0 {
		return fmt.Errorf("request_timeout_sec must be positive")
	}
	if c.Capabilities.KeyID != "" && c.Capabilities.PublicKey == "" {
		return fmt.Errorf("capabilities.key_id is set but capabilities.public_key is not: a key id alone cannot verify a manifest")
	}
	if c.Capabilities.PublicKey != "" {
		if _, err := decodePublicKey(c.Capabilities.PublicKey); err != nil {
			return fmt.Errorf("capabilities.public_key: %w", err)
		}
	}
	for k := range c.Env {
		if k == "" {
			return fmt.Errorf("env keys must be non-empty")
		}
	}
	return nil
}

// ResolveToken returns the API credential: the file (first line, trimmed)
// wins over the environment variable. An empty result is an error unless
// auth_scheme = "none". The value is never logged.
func (c *Config) ResolveToken() (string, error) {
	if c.AuthScheme == AuthNone {
		return "", nil
	}
	if c.AuthTokenFile != "" {
		raw, err := os.ReadFile(c.AuthTokenFile)
		if err != nil {
			return "", fmt.Errorf("reading auth_token_file: %w", err)
		}
		tok := strings.TrimSpace(strings.SplitN(string(raw), "\n", 2)[0])
		if tok == "" {
			return "", fmt.Errorf("auth_token_file %q is empty", c.AuthTokenFile)
		}
		return tok, nil
	}
	if tok := strings.TrimSpace(os.Getenv(c.AuthTokenEnv)); tok != "" {
		return tok, nil
	}
	return "", fmt.Errorf("auth_scheme %q needs a credential: set auth_token_file or the %s environment variable", c.AuthScheme, c.AuthTokenEnv)
}

func (r NixRunnerConfig) validate() error {
	if r.Listener == "" {
		return fmt.Errorf("listener is required: the sandbox payload execs the host's Nix-packaged actions runner (<github-runner>/bin/Runner.Listener) and never downloads one")
	}
	if !strings.HasPrefix(r.Listener, "/") || !strings.HasSuffix(r.Listener, "/bin/Runner.Listener") {
		return fmt.Errorf("listener %q must be an absolute <github-runner>/bin/Runner.Listener path", r.Listener)
	}
	if _, ok := parseRunnerVersion(r.Version); !ok {
		return fmt.Errorf("version %q must be x.y.z", r.Version)
	}
	for _, d := range r.Path {
		if !strings.HasPrefix(d, "/") {
			return fmt.Errorf("path entry %q must be absolute", d)
		}
	}
	for k := range r.Env {
		if k == "" || strings.ContainsAny(k, "= ") {
			return fmt.Errorf("env key %q is not a valid variable name", k)
		}
	}
	if r.MaxMinorLag < 1 {
		return fmt.Errorf("max_minor_lag must be >= 1")
	}
	return nil
}
