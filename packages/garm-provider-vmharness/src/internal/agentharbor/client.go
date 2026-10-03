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

// A thin client for agent-harbor's direct (no-agent) sandbox-job endpoints.
// Normative spec: agent-harbor specs/REST-Service/Direct-Sandbox-Launch.md.
// The wire types mirror crates/ah-rest-api-contract/src/sandbox_jobs.rs
// (camelCase JSON).

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

// Job states (spec § Lifecycle).
const (
	StatePending    = "pending"
	StateStarting   = "starting"
	StateRunning    = "running"
	StateExited     = "exited"
	StateFailed     = "failed"
	StateDestroying = "destroying"
	StateDestroyed  = "destroyed"
)

// MaxStdinBytes is the server's cap on the launch stdin payload.
const MaxStdinBytes = 1024 * 1024

// CreateJobRequest is the POST /api/v1/sandbox-jobs body.
type CreateJobRequest struct {
	Name               string            `json:"name"`
	Substrate          string            `json:"substrate"`
	Command            []string          `json:"command"`
	Stdin              *string           `json:"stdin,omitempty"`
	Env                map[string]string `json:"env,omitempty"`
	WorkingDirectory   *string           `json:"workingDirectory,omitempty"`
	Labels             map[string]string `json:"labels,omitempty"`
	TTLSeconds         *uint64           `json:"ttlSeconds,omitempty"`
	IdleTimeoutSeconds *uint64           `json:"idleTimeoutSeconds,omitempty"`
	Sandbox            SandboxOptions    `json:"sandbox"`
	Image              *string           `json:"image,omitempty"`
	Flavor             *string           `json:"flavor,omitempty"`
}

// HostInfo identifies the serving host of a job.
type HostInfo struct {
	ServerID string `json:"serverId"`
	OS       string `json:"os"`
	Arch     string `json:"arch"`
}

// Job is a SandboxJob as returned by every endpoint.
type Job struct {
	ID                 string            `json:"id"`
	Name               string            `json:"name"`
	Substrate          string            `json:"substrate"`
	State              string            `json:"state"`
	TerminationReason  *string           `json:"terminationReason"`
	ExitCode           *int              `json:"exitCode"`
	Error              *string           `json:"error"`
	Labels             map[string]string `json:"labels"`
	Command            []string          `json:"command"`
	CreatedAt          time.Time         `json:"createdAt"`
	StartedAt          *time.Time        `json:"startedAt"`
	EndedAt            *time.Time        `json:"endedAt"`
	ExpiresAt          time.Time         `json:"expiresAt"`
	TombstoneExpiresAt *time.Time        `json:"tombstoneExpiresAt"`
	TTLSeconds         uint64            `json:"ttlSeconds"`
	IdleTimeoutSeconds *uint64           `json:"idleTimeoutSeconds"`
	CleanupToken       string            `json:"cleanupToken"`
	Host               HostInfo          `json:"host"`
	Addresses          []string          `json:"addresses"`
}

type jobList struct {
	Items []Job `json:"items"`
}

type cleanupRequest struct {
	CleanupToken string `json:"cleanupToken"`
}

// CleanupResponse is the POST /api/v1/sandbox-jobs/cleanup response.
type CleanupResponse struct {
	Outcome string `json:"outcome"`
}

// Error codes of the spec's error model (§ Error model).
const (
	CodeInvalidRequest       = "invalid-request"
	CodeForbidden            = "forbidden"
	CodeNotFound             = "not-found"
	CodeNameConflict         = "name-conflict"
	CodeInvalidSandboxOption = "invalid-sandbox-option"
	CodeSubstrateUnavailable = "substrate-unavailable"
	CodeAdmissionShed        = "admission-shed"
	CodeCapacityExhausted    = "capacity-exhausted"
)

// APIError is a Problem+JSON error answer.
type APIError struct {
	Status        int    `json:"status"`
	Code          string `json:"code"`
	Title         string `json:"title"`
	Detail        string `json:"detail"`
	ExistingJobID string `json:"existingJobId"`
}

func (e *APIError) Error() string {
	code := e.Code
	if code == "" {
		code = "unknown"
	}
	msg := fmt.Sprintf("agent-harbor: HTTP %d %s", e.Status, code)
	if e.Detail != "" {
		msg += ": " + e.Detail
	}
	return msg
}

// Retryable reports whether the spec marks the error as transient ("retry
// later"): the two 503 codes.
func (e *APIError) Retryable() bool {
	return e.Code == CodeAdmissionShed || e.Code == CodeCapacityExhausted
}

// Client talks to one ah REST service.
type Client struct {
	base       string
	authHeader string
	http       *http.Client
}

// NewClient builds a client. authHeader is the complete Authorization header
// value ("" for none).
func NewClient(endpoint, authHeader string, timeout time.Duration, caCertFile string) (*Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if caCertFile != "" {
		pem, err := os.ReadFile(caCertFile)
		if err != nil {
			return nil, fmt.Errorf("reading ca_cert_file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("ca_cert_file %q holds no PEM certificates", caCertFile)
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	return &Client{
		base:       strings.TrimRight(endpoint, "/") + "/api/v1",
		authHeader: authHeader,
		http:       &http.Client{Timeout: timeout, Transport: transport},
	}, nil
}

// AuthHeader renders the Authorization header for a scheme + token.
func AuthHeader(scheme, token string) string {
	switch scheme {
	case AuthAPIKey:
		return "ApiKey " + token
	case AuthBearer:
		return "Bearer " + token
	default:
		return ""
	}
}

// do issues one request and decodes a 2xx JSON body into out (when non-nil).
// Non-2xx answers become *APIError. It returns the HTTP status.
func (c *Client) do(ctx context.Context, method, path string, headers map[string]string, body, out any) (int, error) {
	var rdr io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return 0, err
		}
		rdr = bytes.NewReader(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rdr)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.authHeader != "" {
		req.Header.Set("Authorization", c.authHeader)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		// Never echo the request (it may carry the install script); the
		// transport error names only method + URL.
		return 0, fmt.Errorf("agent-harbor %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return resp.StatusCode, fmt.Errorf("agent-harbor %s %s: reading body: %w", method, path, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		apiErr := &APIError{}
		if jerr := json.Unmarshal(raw, apiErr); jerr != nil || apiErr.Status == 0 {
			// Not Problem+JSON (a proxy, an older server): keep the status so
			// the error mapping still works, and a short excerpt for humans.
			apiErr = &APIError{Detail: excerpt(raw)}
		}
		apiErr.Status = resp.StatusCode
		return resp.StatusCode, apiErr
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			return resp.StatusCode, fmt.Errorf("agent-harbor %s %s: decoding response: %w", method, path, err)
		}
	}
	return resp.StatusCode, nil
}

func excerpt(raw []byte) string {
	s := strings.TrimSpace(string(raw))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}

// CreateJob launches a job. idempotencyKey makes retries return the original.
func (c *Client) CreateJob(ctx context.Context, req CreateJobRequest, idempotencyKey string) (Job, error) {
	var job Job
	headers := map[string]string{}
	if idempotencyKey != "" {
		headers["Idempotency-Key"] = idempotencyKey
	}
	_, err := c.do(ctx, http.MethodPost, "/sandbox-jobs", headers, req, &job)
	return job, err
}

// GetJob fetches a job by id or name.
func (c *Client) GetJob(ctx context.Context, idOrName string) (Job, error) {
	var job Job
	_, err := c.do(ctx, http.MethodGet, "/sandbox-jobs/"+url.PathEscape(idOrName), nil, nil, &job)
	return job, err
}

// ListJobs lists the tenant's live jobs whose labels match every entry of
// labels (AND).
func (c *Client) ListJobs(ctx context.Context, labels map[string]string) ([]Job, error) {
	q := url.Values{}
	keys := make([]string, 0, len(labels))
	for k := range labels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		q.Add("label", k+"="+labels[k])
	}
	path := "/sandbox-jobs"
	if enc := q.Encode(); enc != "" {
		path += "?" + enc
	}
	var list jobList
	if _, err := c.do(ctx, http.MethodGet, path, nil, nil, &list); err != nil {
		return nil, err
	}
	return list.Items, nil
}

// DeleteJob destroys a job (waiting for teardown). It returns the final record
// and the HTTP status (200 destroyed, 202 still destroying).
func (c *Client) DeleteJob(ctx context.Context, idOrName string) (Job, int, error) {
	var job Job
	status, err := c.do(ctx, http.MethodDelete, "/sandbox-jobs/"+url.PathEscape(idOrName), nil, nil, &job)
	return job, status, err
}

// Cleanup redeems a cleanup token (idempotent teardown without a live job).
func (c *Client) Cleanup(ctx context.Context, token string) (CleanupResponse, error) {
	var out CleanupResponse
	_, err := c.do(ctx, http.MethodPost, "/sandbox-jobs/cleanup", nil, cleanupRequest{CleanupToken: token}, &out)
	return out, err
}

// Capabilities fetches the signed capability manifest envelope.
func (c *Client) Capabilities(ctx context.Context) (SignedManifest, error) {
	var out SignedManifest
	_, err := c.do(ctx, http.MethodGet, "/sandbox/capabilities", nil, nil, &out)
	return out, err
}

// IsNotFound reports whether err is the API's 404.
func IsNotFound(err error) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound
}
