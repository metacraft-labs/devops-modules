# VM Images Module

A Nix library for building reproducible VM images with automated unattended installation. Supports Linux (Ubuntu), macOS, and Windows guests.

## Overview

The VM Images module provides Nix functions for:

- Fetching OS installation media (ISOs, cloud images)
- Building VM images with automated installation
- Creating reproducible test environments for CI/CD

Unlike the [Desktop VMs](./desktop-vms.md) NixOS module (for running VMs locally), this module is for **building VM images** programmatically.

## Quick Start

```nix
# In your flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-modules.url = "github:metacraft-labs/devops-modules";

    # Required for macOS VM building
    osx-kvm = { url = "github:kholia/OSX-KVM"; flake = false; };
  };

  outputs = { nixpkgs, nixos-modules, osx-kvm, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      # Import the VM images module
      vmImages = import (nixos-modules + /vm-images) {
        inherit pkgs osx-kvm;
      };
    in {
      packages.x86_64-linux = {
        # Your VM image definitions here
      };
    };
}
```

## Linux VMs

### Ubuntu with Cloud-Init

Build Ubuntu VMs using official cloud images with cloud-init for configuration.

```nix
vmImages.linux.makeLinuxVM {
  name = "ubuntu-ci-agent";

  # Fetch the Ubuntu cloud image
  cloudImage = vmImages.fetchUbuntuCloudImage {
    version = "24.04";
    codename = "noble";
    sha256 = "2b5f90ffe8180def601c021c874e55d8303e8bcbfc66fee2b94414f43ac5eb1f";
  };

  # VM configuration
  hostname = "ubuntu-agent";
  username = "agent";
  sshPort = 2222;

  # Optional settings
  memory = 4096;        # MB
  cpus = 2;
  diskSize = "20G";
  installNix = true;    # Pre-install Nix
}
```

### Cloud-Init Configuration

For more control, generate cloud-init configuration separately:

```nix
let
  sshKey = vmImages.linux.cloudInit.generateTestSSHKey { name = "ci-key"; };

  cloudInitConfig = vmImages.linux.cloudInit.makeCloudInitConfig {
    hostname = "my-vm";
    username = "agent";
    sshPublicKey = sshKey.publicKey;
    sshPort = 2222;
    installNix = true;
  };
in
# Use cloudInitConfig with your VM builder
```

## macOS VMs

Build macOS VMs with automated Setup Assistant completion.

### Prerequisites

1. Add `osx-kvm` as a flake input
2. Prepare an automation config (see [Automation Engine](./automation-engine.md))

### Building a macOS VM

```nix
vmImages.darwin.makeDarwinVM {
  name = "macos-sequoia-ci";

  # Fetch macOS installation media
  baseSystemImg = vmImages.fetchMacOSBaseSystem {
    release = "sequoia";
    sha256 = "sha256-...";  # Get from Apple CDN
  };

  installAssistantIso = vmImages.fetchMacOSInstallAssistant {
    majorVersion = 15;  # Sequoia = macOS 15
    sha256 = "sha256-...";
  };

  # Automation config for Setup Assistant
  automationConfig = ./configs/macos-sequoia.yml;

  # VM settings
  diskSizeBytes = 64 * 1024 * 1024 * 1024;  # 64GB
  memoryMB = 8192;
  cpuCores = 4;

  # Credentials (used by automation and health check)
  username = "agent";
  password = "agent";

  # Network ports
  sshPort = 2222;
  vncDisplay = 0;  # VNC on port 5900
}
```

### Running a Pre-Built macOS VM

```nix
# Create a run script for an existing VM image
vmImages.darwin.makeRunScript {
  diskImage = ./macos-sequoia.qcow2;
  sshPort = 2222;
  memoryMB = 8192;
  cpuCores = 4;
  username = "agent";
  password = "agent";
}
```

### macOS Release Names

| macOS Version | Release Name | Major Version |
| ------------- | ------------ | ------------- |
| macOS 15      | Tahoe        | 15            |
| macOS 14      | Sequoia      | 14            |
| macOS 14      | Sonoma       | 14            |
| macOS 13      | Ventura      | 13            |
| macOS 12      | Monterey     | 12            |

## Windows VMs

Build Windows VMs with automated unattended installation.

### Prerequisites

1. Obtain a Windows ISO (not redistributable, must provide your own)
2. The module handles VirtIO drivers automatically

### Building a Windows VM

```nix
vmImages.windows.makeWindowsVM {
  name = "windows-11-ci";

  # Windows installation ISO (user-provided)
  windowsIso = /path/to/Win11_English_x64.iso;

  # VirtIO drivers (fetched automatically)
  virtioDriversIso = vmImages.fetchVirtIODrivers {
    sha256 = "sha256-...";  # Check fedorapeople.org for latest
  };

  # Optional: automation config for OOBE
  automationConfig = ./configs/windows-11.yml;

  # VM settings
  diskSizeGB = 60;
  memoryMB = 8192;
  cpuCores = 4;

  # Windows configuration
  username = "agent";
  password = "agent";
  computerName = "WIN11-CI";
  timezone = "UTC";

  # Network ports
  sshPort = 2222;   # OpenSSH server
  rdpPort = 3389;   # Remote Desktop
  vncDisplay = 0;

  # TPM for Windows 11
  enableTpm = true;
}
```

### Autounattend.xml Generation

Generate just the unattended installation file:

```nix
vmImages.windows.generateAutounattendXml {
  username = "Admin";
  password = "Password123";
  computerName = "MYPC";
  timezone = "Pacific Standard Time";
  virtioDriverPath = "E:\\";  # VirtIO drivers CD
  locale = "en-US";
}
```

### Windows Health Check

Create a health check script for an existing Windows VM:

```nix
vmImages.windows.makeWindowsHealthCheck {
  sshPort = 2222;
  username = "agent";
  password = "agent";
  bootTimeoutSeconds = 300;
  sshRetries = 10;
  sshRetryDelay = 30;
}
```

## ISO/Image Fetchers

### Ubuntu Cloud Images

```nix
vmImages.fetchUbuntuCloudImage {
  version = "24.04";
  codename = "noble";
  sha256 = "...";
}
```

Find SHA256 hashes at: https://cloud-images.ubuntu.com/releases/

### macOS BaseSystem

```nix
vmImages.fetchMacOSBaseSystem {
  release = "sequoia";  # or "sonoma", "ventura", etc.
  sha256 = "sha256-...";
}
```

Requires `osx-kvm` input. Uses Apple's CDN via `fetch-macOS-v2.py`.

### macOS InstallAssistant

```nix
vmImages.fetchMacOSInstallAssistant {
  majorVersion = 15;  # macOS 15 = Sequoia
  sha256 = "sha256-...";
}
```

Fetches the full installer package and converts to ISO.

### VirtIO Drivers

```nix
vmImages.fetchVirtIODrivers {
  version = "0.1.248";  # Optional, defaults to stable
  sha256 = "sha256-...";
}
```

Download source: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/

### Validate Windows ISO

```nix
vmImages.validateWindowsISO {
  isoPath = /path/to/Windows.iso;
}
# Returns: derivation with validation results in JSON
```

## CI/CD Integration

### GitHub Actions Example

```yaml
jobs:
  build-vm:
    runs-on: ubuntu-latest
    steps:
      - uses: DeterminateSystems/nix-installer-action@v22
        with:
          determinate: false

      - name: Build VM image
        run: |
          nix build .#packages.x86_64-linux.ubuntu-ci-agent

      - name: Test VM boots
        run: |
          ./result/run.sh &
          sleep 60
          ssh -p 2222 agent@localhost 'uname -a'
```

### Caching Built Images

VM images are large but reproducible. Use binary caches:

```nix
# In flake.nix
{
  nixConfig = {
    extra-substituters = [ "https://cache.metacraft-labs.com/your-cache" ];
    extra-trusted-public-keys = [ "your-cache:..." ];
  };
}
```

## API Reference

### Linux

| Function                              | Description                |
| ------------------------------------- | -------------------------- |
| `linux.makeLinuxVM`                   | Build a complete Linux VM  |
| `linux.cloudInit.makeCloudInitConfig` | Generate cloud-init config |
| `linux.cloudInit.generateTestSSHKey`  | Generate SSH key pair      |

### Darwin (macOS)

| Function                          | Description                        |
| --------------------------------- | ---------------------------------- |
| `darwin.makeDarwinVM`             | Build a complete macOS VM          |
| `darwin.makeDarwinCachedBootTest` | Create boot test for pre-built VM  |
| `darwin.makeDarwinRunScript`      | Create run script for VM directory |
| `darwin.makeRunScript`            | Create run script for QCOW2 image  |

### Windows

| Function                            | Description                       |
| ----------------------------------- | --------------------------------- |
| `windows.makeWindowsVM`             | Build a complete Windows VM       |
| `windows.generateAutounattendXml`   | Generate autounattend.xml         |
| `windows.makeAutounattendFloppy`    | Create floppy with autounattend   |
| `windows.makeAutounattendIso`       | Create ISO with autounattend      |
| `windows.makeWindowsVMPackage`      | Build installation package        |
| `windows.makeWindowsRunScript`      | Create run script for VM          |
| `windows.makeWindowsCachedBootTest` | Create boot test for pre-built VM |
| `windows.makeWindowsHealthCheck`    | Create SSH health check script    |

### Fetchers

| Function                     | Description                   |
| ---------------------------- | ----------------------------- |
| `fetchUbuntuCloudImage`      | Fetch Ubuntu cloud QCOW2      |
| `fetchMacOSBaseSystem`       | Fetch macOS BaseSystem.img    |
| `fetchMacOSInstallAssistant` | Fetch macOS installer ISO     |
| `fetchVirtIODrivers`         | Fetch VirtIO drivers ISO      |
| `validateWindowsISO`         | Validate Windows ISO contents |

## Troubleshooting

### macOS: "osx-kvm input required"

You must provide the `osx-kvm` flake input:

```nix
inputs.osx-kvm = { url = "github:kholia/OSX-KVM"; flake = false; };
```

### Windows: Installation hangs

1. Check VirtIO drivers are accessible
2. Verify autounattend.xml is valid
3. Enable VNC and connect to watch installation
4. Check [Automation Engine](./automation-engine.md) debug mode

### Build fails with "hash mismatch"

SHA256 hashes change when upstream updates files. Get current hashes from:

- Ubuntu: https://cloud-images.ubuntu.com/releases/
- VirtIO: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/

### VM boots but SSH fails

1. Check SSH port forwarding: `ss -tlnp | grep 2222`
2. Verify SSH server is installed and running in guest
3. Check firewall rules in guest OS
4. For Windows, ensure OpenSSH Server feature is installed

## See Also

- [Virtualisation Overview](./index.md) - Overview of all VM modules
- [Desktop VMs](./desktop-vms.md) - NixOS module for local desktop VMs
- [Automation Engine](./automation-engine.md) - GUI automation for unattended installation

## References

- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/releases/)
- [OSX-KVM Project](https://github.com/kholia/OSX-KVM)
- [VirtIO Windows Drivers](https://github.com/virtio-win/virtio-win-pkg-scripts)
- [Windows Unattended Installation](https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/automate-windows-setup)
- [Cloud-Init Documentation](https://cloudinit.readthedocs.io/)
