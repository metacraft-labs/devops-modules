// Copyright 2026 Metacraft Labs
//
//    Licensed under the Apache License, Version 2.0 (the "License"); you may
//    not use this file except in compliance with the License. You may obtain a
//    copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

// ServeClient is the Go counterpart of vm-harness' Nim `ServeClient`
// (src/vm_harness/serve/client.nim): a thin RPC client for the RA1 `vm-harness
// serve` protocol v1. It speaks the IDENTICAL wire contract so the remote-mode
// provider (RB1) drives a remote host's VM/container lifecycle byte-equivalently
// to the local-exec path:
//
//   - GET  /v1/info      — capability report (protocol, host, backends[]).
//   - POST /v1/exec      — run a forwarded vm-harness CLI argv on the daemon
//     host and STREAM its output as chunked NDJSON
//     (`log`/`exit`/`error` events).
//   - POST /v1/shutdown  — graceful stop (unused by the provider).
//
// Every route requires `Authorization: Bearer <token>`; a 401 is surfaced as
// ServeAuthError so a caller can distinguish rejected credentials from a
// transport failure — matching the Nim client's ServeAuthError/ServeError
// split. The transport is Go stdlib net/http; chunked transfer-decoding is
// handled transparently, so the exec body is a live stream we scan line by line.
package backend

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// ProtocolVersion mirrors serve/protocol.nim ProtocolVersion. It is sent in the
// `v` field of every request and checked in the URL prefix.
const ProtocolVersion = "1"

const (
	apiPrefix   = "/v" + ProtocolVersion
	pathInfo    = apiPrefix + "/info"
	pathExec    = apiPrefix + "/exec"
	authScheme  = "Bearer "
	authHeader  = "Authorization"
	contentJSON = "application/json"
)

// ServeAuthError is returned when the daemon rejects the credential (HTTP 401).
type ServeAuthError struct{ msg string }

func (e *ServeAuthError) Error() string { return e.msg }

// ServeClient is a bearer-authenticated client for a single `vm-harness serve`
// endpoint. It is safe to construct once and reuse across lifecycle calls.
type ServeClient struct {
	// Endpoint is the daemon address as host:port.
	Endpoint string
	// Token is the bearer credential.
	Token string
	// HTTPClient is used for non-streaming requests (/v1/info). Streaming
	// (/v1/exec) uses a client with NO overall timeout because a job can run
	// for hours; the remote worker enforces its own --timeout-sec.
	HTTPClient *http.Client
}

// NewServeClient builds a client for host:port using the given bearer token.
// requestTimeout bounds a non-streaming request (0 ⇒ 30s default).
func NewServeClient(endpoint, token string, requestTimeout time.Duration) *ServeClient {
	if requestTimeout <= 0 {
		requestTimeout = 30 * time.Second
	}
	return &ServeClient{
		Endpoint:   endpoint,
		Token:      token,
		HTTPClient: &http.Client{Timeout: requestTimeout},
	}
}

func (c *ServeClient) url(path string) string {
	return "http://" + c.Endpoint + path
}

// ExecEvent is a decoded NDJSON event from /v1/exec (mirrors serve ExecEvent).
type ExecEvent struct {
	Kind    string // "log" | "exit" | "error"
	Line    string // ekLog
	Code    int    // ekExit
	Message string // ekError
}

// wireEvent is the on-the-wire NDJSON shape.
type wireEvent struct {
	V       string `json:"v"`
	Type    string `json:"type"`
	Line    string `json:"line"`
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// execRequest is the /v1/exec body (mirrors serve ExecRequest).
type execRequest struct {
	V          string   `json:"v"`
	Argv       []string `json:"argv"`
	Stdin      string   `json:"stdin"`
	TimeoutSec int      `json:"timeoutSec"`
	// UserData carries raw cloud-init user-data bytes (e.g. the rendered runner
	// bootstrap). When non-empty the daemon materializes it to a per-request
	// 0600 temp file and appends `--user-data <path>` to the worker argv, so
	// the token-bearing bytes reach the remote guest without the client needing
	// a filesystem path on the daemon host. omitempty keeps the wire clean (and
	// backward compatible with a daemon that predates the field) when unset.
	UserData string `json:"userData,omitempty"`
}

// Info issues GET /v1/info and returns the decoded capability report. A wrong
// or missing token yields a *ServeAuthError. It doubles as a liveness + auth
// probe for the stateless identity-recovery path (the provider has no local
// state; the remote daemon is the source of truth for host reachability).
func (c *ServeClient) Info(ctx context.Context) (map[string]any, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url(pathInfo), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set(authHeader, authScheme+c.Token)
	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("serve info %s: %w", c.Endpoint, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, &ServeAuthError{msg: fmt.Sprintf("serve %s rejected credentials (401)", c.Endpoint)}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("serve info %s: unexpected status %d: %s", c.Endpoint, resp.StatusCode, string(body))
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("serve info %s: decoding body: %w", c.Endpoint, err)
	}
	return out, nil
}

// ExecStream issues POST /v1/exec, runs argv as a vm-harness CLI invocation on
// the daemon host, and streams its output. onEvent (may be nil) is called for
// each decoded event as it arrives. It returns the worker's exit code (from the
// terminal `exit` event). A wrong/missing token yields a *ServeAuthError; a
// stream that ends without an exit event is an error (carrying any `error`
// event message), mirroring the Nim client's contract exactly.
func (c *ServeClient) ExecStream(ctx context.Context, argv []string, onEvent func(ExecEvent)) (int, error) {
	return c.ExecStreamWithUserData(ctx, argv, "", onEvent)
}

// ExecStreamWithUserData is ExecStream plus a cloud-init user-data payload. When
// userData is non-empty the daemon writes it to a per-request 0600 temp file and
// appends `--user-data <path>` to the worker argv (see serve/server.applyUserData),
// so the rendered runner bootstrap reaches a remote ephemeral guest. userData may
// carry a runner registration token and is never logged by the client or daemon.
func (c *ServeClient) ExecStreamWithUserData(ctx context.Context, argv []string, userData string, onEvent func(ExecEvent)) (int, error) {
	reqBody, err := json.Marshal(execRequest{V: ProtocolVersion, Argv: argv, UserData: userData})
	if err != nil {
		return -1, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url(pathExec), bytes.NewReader(reqBody))
	if err != nil {
		return -1, err
	}
	req.Header.Set(authHeader, authScheme+c.Token)
	req.Header.Set("Content-Type", contentJSON)

	// A dedicated client with NO Timeout: the response is a long-lived stream
	// for the whole remote job. Transport dial/response-header timeouts still
	// bound the CONNECT so an unreachable endpoint fails fast.
	stream := &http.Client{
		Transport: &http.Transport{
			DialContext:           (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
			ResponseHeaderTimeout: 30 * time.Second,
		},
	}
	resp, err := stream.Do(req)
	if err != nil {
		return -1, fmt.Errorf("serve exec %s: %w", c.Endpoint, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		return -1, &ServeAuthError{msg: fmt.Sprintf("serve %s rejected credentials (401)", c.Endpoint)}
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return -1, fmt.Errorf("serve exec %s: unexpected status %d: %s", c.Endpoint, resp.StatusCode, string(body))
	}

	exitCode := -1
	sawExit := false
	errMsg := ""
	scanner := bufio.NewScanner(resp.Body)
	// Runner bootstrap/log lines can be long; grow the token buffer generously.
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var we wireEvent
		if err := json.Unmarshal([]byte(line), &we); err != nil {
			// A non-JSON line on the stream is a protocol violation; surface it.
			return -1, fmt.Errorf("serve exec %s: undecodable event %q: %w", c.Endpoint, line, err)
		}
		ev := ExecEvent{Kind: we.Type, Line: we.Line, Code: we.Code, Message: we.Message}
		if onEvent != nil {
			onEvent(ev)
		}
		switch we.Type {
		case "exit":
			exitCode = we.Code
			sawExit = true
		case "error":
			errMsg = we.Message
		}
	}
	if err := scanner.Err(); err != nil {
		return -1, fmt.Errorf("serve exec %s: reading stream: %w", c.Endpoint, err)
	}
	if !sawExit {
		if errMsg != "" {
			return -1, fmt.Errorf("serve exec %s: stream ended without exit (%s)", c.Endpoint, errMsg)
		}
		return -1, fmt.Errorf("serve exec %s: stream ended without an exit event", c.Endpoint)
	}
	return exitCode, nil
}
