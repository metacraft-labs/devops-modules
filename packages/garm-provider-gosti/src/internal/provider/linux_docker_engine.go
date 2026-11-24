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

import _ "embed"

// linuxDockerEngineSetup is the bash fragment that gives every Tart Linux
// runner (eph-linux-arm64) a Docker Engine the runner user can reach, matching
// what the eph-linux-x64 golden bakes. It is spliced into
// linuxForegroundRunnerInstallTemplate as .BashDockerEngineSetup; see the
// header of linux_docker_engine.sh for what it installs and why.
//
//go:embed linux_docker_engine.sh
var linuxDockerEngineSetup string
