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

// configJSONSchema describes the provider config file (config.go). GARM shows
// it to operators via `garm-cli provider show`.
const configJSONSchema = `{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "garm-provider-agentharbor config",
  "type": "object",
  "required": ["endpoint"],
  "additionalProperties": false,
  "properties": {
    "backend": {"type": "string", "enum": ["agentharbor"]},
    "endpoint": {"type": "string", "description": "agent-harbor REST service base URL (http/https); /api/v1 is appended"},
    "auth_scheme": {"type": "string", "enum": ["apikey", "bearer", "none"], "default": "apikey"},
    "auth_token_file": {"type": "string", "description": "file holding the API key / JWT (first line)"},
    "auth_token_env": {"type": "string", "default": "AH_API_TOKEN", "description": "environment variable holding the credential when no file is set"},
    "ca_cert_file": {"type": "string"},
    "request_timeout_sec": {"type": "integer", "minimum": 1, "default": 300},
    "substrate": {"type": "string", "enum": ["local-sandbox", "vm", "cloud-vm"], "default": "local-sandbox"},
    "runner_template": {"type": "string", "enum": ["sandbox", "upstream"], "description": "default: sandbox for local-sandbox, upstream otherwise"},
    "command": {"type": "array", "items": {"type": "string"}, "default": ["bash", "-s"]},
    "env": {"type": "object", "additionalProperties": {"type": "string"}, "description": "non-secret environment for every job"},
    "ttl_seconds": {"type": "integer", "minimum": 1, "default": 21600},
    "idle_timeout_seconds": {"type": "integer", "minimum": 0},
    "guest_metadata_url": {"type": "string"},
    "guest_callback_url": {"type": "string"},
    "sandbox": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "allow_network": {"type": "boolean"},
        "allow_containers": {"type": "boolean"},
        "allow_kvm": {"type": "boolean"},
        "memory_max": {"type": "string"},
        "memory_high": {"type": "string"},
        "pids_max": {"type": "integer", "minimum": 1},
        "cpu_max": {"type": "string"},
        "tmpfs_size": {"type": "string"}
      }
    },
    "capabilities": {
      "type": "object",
      "additionalProperties": false,
      "description": "pinned Ed25519 key of the host's signed capability manifest; when set, launches are refused on hosts whose manifest does not verify",
      "properties": {
        "key_id": {"type": "string", "pattern": "^ahcap-[0-9a-f]{16}$"},
        "public_key": {"type": "string", "description": "base64url 32-byte Ed25519 public key"}
      }
    }
  }
}`

// extraSpecsJSONSchema describes the per-pool extra specs this provider reads.
// Other keys (GARM's own cloudconfig keys) are allowed and passed through.
const extraSpecsJSONSchema = `{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "garm-provider-agentharbor pool extra specs",
  "type": "object",
  "additionalProperties": true,
  "properties": {
    "ttl_seconds": {"type": "integer", "minimum": 1},
    "idle_timeout_seconds": {"type": "integer", "minimum": 0},
    "runner_template": {"type": "string", "enum": ["sandbox", "upstream"]},
    "memory_max": {"type": "string"},
    "cpu_max": {"type": "string"},
    "pids_max": {"type": "integer", "minimum": 1}
  }
}`
