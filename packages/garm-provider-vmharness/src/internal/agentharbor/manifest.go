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

// Verification of the host's signed capability manifest
// (Direct-Sandbox-Launch.md § Capability manifest, § Signing rules):
//
//   - the signature is Ed25519 over the EXACT decoded `payload` bytes — never
//     over a re-serialisation of the informational `manifest` copy;
//   - the key is pinned out of band (provider config); the embedded publicKey
//     is not a trust root;
//   - keyId = "ahcap-" + the first 16 hex chars of SHA-256(publicKey);
//   - an expired manifest is rejected;
//   - labels are derived ONLY from the signed payload, and a substrate that is
//     not `available` contributes no label.

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// ManifestSchema is the only manifest schema this provider understands.
const ManifestSchema = "ah.sandbox.capabilities/v1"

// SignedManifest is the GET /api/v1/sandbox/capabilities envelope.
type SignedManifest struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
	Alg       string `json:"alg"`
	KeyID     string `json:"keyId"`
	PublicKey string `json:"publicKey"`
}

// SubstrateCapability is one substrate entry of the manifest.
type SubstrateCapability struct {
	Name      string   `json:"name"`
	Available bool     `json:"available"`
	Isolation []string `json:"isolation,omitempty"`
	Reason    string   `json:"reason,omitempty"`
}

// Manifest is the signed capability statement.
type Manifest struct {
	Schema     string                `json:"schema"`
	ServerID   string                `json:"serverId"`
	IssuedAt   time.Time             `json:"issuedAt"`
	ExpiresAt  time.Time             `json:"expiresAt"`
	OS         string                `json:"os"`
	Arch       string                `json:"arch"`
	Substrates []SubstrateCapability `json:"substrates"`
	Labels     []string              `json:"labels"`
}

func decodeB64URL(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
}

func decodePublicKey(s string) (ed25519.PublicKey, error) {
	raw, err := decodeB64URL(s)
	if err != nil {
		return nil, fmt.Errorf("not base64url: %w", err)
	}
	if len(raw) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("want a %d-byte Ed25519 public key, got %d bytes", ed25519.PublicKeySize, len(raw))
	}
	return ed25519.PublicKey(raw), nil
}

// KeyIDFor computes the spec's key id for a public key.
func KeyIDFor(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return "ahcap-" + hex.EncodeToString(sum[:])[:16]
}

// VerifyManifest checks env against the pinned key and returns the decoded,
// verified manifest.
func VerifyManifest(env SignedManifest, pinned CapabilitiesConfig, now time.Time) (Manifest, error) {
	pub, err := decodePublicKey(pinned.PublicKey)
	if err != nil {
		return Manifest{}, fmt.Errorf("pinned public key: %w", err)
	}
	wantKeyID := KeyIDFor(pub)
	if pinned.KeyID != "" && pinned.KeyID != wantKeyID {
		return Manifest{}, fmt.Errorf("pinned key_id %q does not match the pinned public key (%s)", pinned.KeyID, wantKeyID)
	}
	if env.Alg != "Ed25519" {
		return Manifest{}, fmt.Errorf("manifest alg %q is not Ed25519", env.Alg)
	}
	if env.KeyID != wantKeyID {
		return Manifest{}, fmt.Errorf("manifest signed by key %q, but %q is pinned", env.KeyID, wantKeyID)
	}
	payload, err := decodeB64URL(env.Payload)
	if err != nil {
		return Manifest{}, fmt.Errorf("manifest payload is not base64url: %w", err)
	}
	sig, err := decodeB64URL(env.Signature)
	if err != nil {
		return Manifest{}, fmt.Errorf("manifest signature is not base64url: %w", err)
	}
	if !ed25519.Verify(pub, payload, sig) {
		return Manifest{}, fmt.Errorf("manifest signature does not verify against the pinned key %s", wantKeyID)
	}
	var m Manifest
	if err := json.Unmarshal(payload, &m); err != nil {
		return Manifest{}, fmt.Errorf("decoding signed manifest: %w", err)
	}
	if m.Schema != ManifestSchema {
		return Manifest{}, fmt.Errorf("manifest schema %q, want %q", m.Schema, ManifestSchema)
	}
	if !m.ExpiresAt.After(now) {
		return Manifest{}, fmt.Errorf("manifest expired at %s", m.ExpiresAt.UTC().Format(time.RFC3339))
	}
	return m, nil
}

// SubstrateAvailable reports whether the verified manifest offers name.
func (m Manifest) SubstrateAvailable(name string) bool {
	for _, s := range m.Substrates {
		if s.Name == name {
			return s.Available
		}
	}
	return false
}

// DerivedLabels recomputes the labels the signed content entitles the host to
// (spec § Signing rules): ah-sandbox, ah-substrate-<name> per AVAILABLE
// substrate, the OS, the GitHub arch spelling, plus the operator's extra labels
// as signed in `labels`. A label the manifest lists for an UNAVAILABLE
// substrate is dropped, so a host cannot talk its way into a runner class it
// cannot serve.
func (m Manifest) DerivedLabels() map[string]bool {
	out := map[string]bool{"ah-sandbox": true}
	unavailable := map[string]bool{}
	for _, s := range m.Substrates {
		if s.Available {
			out["ah-substrate-"+s.Name] = true
		} else {
			unavailable["ah-substrate-"+s.Name] = true
		}
	}
	if m.OS != "" {
		out[m.OS] = true
	}
	if m.Arch != "" {
		out[githubArch(m.Arch)] = true
	}
	for _, l := range m.Labels {
		if !unavailable[l] {
			out[l] = true
		}
	}
	return out
}

func githubArch(arch string) string {
	switch arch {
	case "x86_64", "amd64":
		return "x64"
	case "aarch64", "arm64":
		return "arm64"
	default:
		return arch
	}
}

// CheckPoolLabels enforces "advertised ⊆ derived" for the ah capability
// namespace: every pool label starting with "ah-" must be derivable from the
// signed manifest. Other labels (self-hosted, repo-specific names) are the
// operator's business and are not constrained here.
func (m Manifest) CheckPoolLabels(labels []string) error {
	derived := m.DerivedLabels()
	var missing []string
	for _, l := range labels {
		if strings.HasPrefix(l, "ah-") && !derived[l] {
			missing = append(missing, l)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("host %s's signed capability manifest does not grant label(s) %s", m.ServerID, strings.Join(missing, ", "))
	}
	return nil
}
