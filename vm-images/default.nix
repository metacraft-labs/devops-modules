# Unified VM Images Module
#
# This module provides a unified entry point for all VM image building functionality,
# including Linux (Ubuntu), macOS (Darwin), and Windows VM builders, as well as
# image fetching utilities.
#
# =============================================================================
# HOW TO USE FROM A CONSUMING FLAKE
# =============================================================================
#
# In your flake.nix:
#
#   {
#     inputs = {
#       nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
#       nixos-modules.url = "github:metacraft-labs/devops-modules";
#
#       # Optional: Required only for macOS BaseSystem fetching
#       osx-kvm = { url = "github:kholia/OSX-KVM"; flake = false; };
#     };
#
#     outputs = { self, nixpkgs, nixos-modules, osx-kvm, ... }:
#       let
#         pkgs = nixpkgs.legacyPackages.x86_64-linux;
#
#         # Import the VM images module with optional dependencies
#         vmImages = import (nixos-modules + /vm-images) {
#           inherit pkgs;
#           lib = pkgs.lib;
#           inherit osx-kvm;  # Optional: needed for macOS BaseSystem fetching
#           # yaml-automation-runner is auto-created if not provided
#         };
#       in {
#         packages.x86_64-linux = {
#           # Example: Build an Ubuntu VM
#           ubuntu-vm = vmImages.linux.makeLinuxVM {
#             name = "my-ubuntu-vm";
#             cloudImage = vmImages.fetchUbuntuCloudImage {
#               version = "24.04";
#               codename = "noble";
#               sha256 = "2b5f90ffe8180def601c021c874e55d8303e8bcbfc66fee2b94414f43ac5eb1f";
#             };
#             hostname = "ubuntu-follower";
#             username = "agent";
#             sshPort = 2224;
#           };
#
#           # Example: Build a macOS VM
#           macos-vm = vmImages.darwin.makeDarwinVM {
#             name = "my-macos-vm";
#             baseSystemImg = vmImages.fetchMacOSBaseSystem {
#               release = "sonoma";
#               sha256 = "sha256-...";
#             };
#             installAssistantIso = vmImages.fetchMacOSInstallAssistant {
#               majorVersion = 14;
#               sha256 = "sha256-...";
#             };
#             automationConfig = vmImages.automationConfigs.macos-sonoma;
#           };
#
#           # Example: Build a Windows VM
#           windows-vm = vmImages.windows.makeWindowsVM {
#             name = "my-windows-vm";
#             windowsIso = /path/to/Win11_English_x64.iso;
#             virtioDriversIso = vmImages.fetchVirtIODrivers {
#               sha256 = "sha256-...";
#             };
#             username = "admin";
#             password = "admin";
#             computerName = "WIN11-AGENT";
#           };
#         };
#       };
#   }
#
# =============================================================================
# OPTIONAL DEPENDENCIES
# =============================================================================
#
# osx-kvm:
#   Required for: fetchMacOSBaseSystem (uses fetch-macOS-v2.py script)
#   Source: https://github.com/kholia/OSX-KVM (or a fork with Nix packaging)
#   If not provided, fetchMacOSBaseSystem will throw a helpful error.
#
# yaml-automation-runner:
#   Required for: macOS and Windows VM builders (GUI automation via VNC + OCR)
#   If not provided, it will be auto-created from packages/vm-automation.
#   You can also provide your own custom build.
#
# =============================================================================
# EXPORTED API
# =============================================================================
#
# ISO/Image Fetchers:
#   - fetchUbuntuCloudImage { version, codename, sha256 }
#   - fetchMacOSBaseSystem { release, sha256 }  (requires osx-kvm)
#   - fetchMacOSInstallAssistant { majorVersion, sha256 }
#   - fetchVirtIODrivers { version?, sha256 }
#   - validateWindowsISO { isoPath }
#
# Linux Builders:
#   - linux.makeLinuxVM { name, cloudImage, hostname, username, sshPort, ... }
#   - linux.cloudInit.makeCloudInitConfig { ... }
#   - linux.cloudInit.generateTestSSHKey { ... }
#
# Darwin (macOS) Builders:
#   - darwin.makeDarwinVM { name, baseSystemImg, installAssistantIso, automationConfig, ... }
#   - darwin.makeDarwinCachedBootTest { vmDir, ... }
#   - darwin.makeDarwinRunScript { ... }
#   - darwin.makeRunScript { diskImage, ... }
#
# Windows Builders:
#   - windows.generateAutounattendXml { username, password, computerName, timezone, ... }
#   - windows.makeAutounattendFloppy { autounattendXml, additionalFiles? }
#   - windows.makeAutounattendIso { autounattendXml, additionalFiles?, volumeLabel? }
#   - windows.makeWindowsVMPackage { name, windowsIsoPath, ... }
#   - windows.makeWindowsVM { name, windowsIso, virtioDriversIso, ... }
#   - windows.makeWindowsRunScript { ... }
#   - windows.makeWindowsCachedBootTest { vmDir, ... }
#   - windows.makeWindowsHealthCheck { ... }
#
# Automation:
#   - yaml-automation-runner (the automation engine package)
#   - automationConfigs.macos-ventura (YAML config for macOS Ventura OOBE)
#   - automationConfigs.macos-sonoma (YAML config for macOS Sonoma OOBE)
#   - automationConfigs.macos-sequoia (YAML config for macOS Sequoia OOBE)
#   - automationConfigs.macos-tahoe (YAML config for macOS Tahoe OOBE)
#   - automationConfigs.windows-11 (YAML config for Windows 11 OOBE)
#
# =============================================================================
# References:
# - Ubuntu Cloud Images: https://cloud-images.ubuntu.com/releases/
# - macOS Recovery Images: fetch-macOS-v2.py from OSX-KVM
# - Windows VirtIO Drivers: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/
# - OSX-KVM: https://github.com/kholia/OSX-KVM
# - NixThePlanet: https://github.com/MatthewCroughan/NixThePlanet
# =============================================================================

{
  pkgs,
  lib ? pkgs.lib,
  # Optional: Required for macOS BaseSystem fetching
  # Source: https://github.com/kholia/OSX-KVM
  osx-kvm ? null,
  # Optional: YAML automation runner for GUI automation
  # If not provided, it will be auto-created from packages/vm-automation
  yaml-automation-runner ? null,
}:

let
  # ==========================================================================
  # Internal: Auto-create yaml-automation-runner if not provided
  # ==========================================================================
  resolvedYamlAutomationRunner =
    if yaml-automation-runner != null then
      yaml-automation-runner
    else
      import ../packages/vm-automation { inherit pkgs lib; };

  # ==========================================================================
  # Import ISO/Image fetchers
  # ==========================================================================
  isoFetchers = import ./lib/iso-fetchers.nix {
    inherit pkgs osx-kvm;
    # Use the fetch-installassistant.py script from the lib directory
    fetchInstallAssistantScript = ./lib/fetch-installassistant.py;
  };

  # ==========================================================================
  # Import Linux (Ubuntu) VM builder
  # ==========================================================================
  linuxBuilder = import ./ubuntu { inherit pkgs lib; };

  # Import cloud-init utilities separately for more granular access
  cloudInit = import ./ubuntu/cloud-init.nix { inherit pkgs lib; };

  # ==========================================================================
  # Import Darwin (macOS) VM builder
  # ==========================================================================
  darwinBuilder =
    if osx-kvm != null then
      import ./darwin {
        inherit pkgs lib osx-kvm;
        yaml-automation-runner = resolvedYamlAutomationRunner;
      }
    else
      # Create a placeholder that throws helpful errors when used
      let
        throwOsxKvmRequired =
          name:
          throw ''
            darwin.${name} requires the osx-kvm input to be provided.

            To use macOS VM builders, provide the osx-kvm input when importing vm-images:

              vmImages = import (nixos-modules + /vm-images) {
                inherit pkgs lib;
                osx-kvm = osx-kvm-input;  # Add this
              };

            Where osx-kvm-input is a flake input like:

              osx-kvm = { url = "github:kholia/OSX-KVM"; flake = false; };
          '';
      in
      {
        makeDarwinVM = _: throwOsxKvmRequired "makeDarwinVM";
        makeDarwinCachedBootTest = _: throwOsxKvmRequired "makeDarwinCachedBootTest";
        makeDarwinRunScript = _: throwOsxKvmRequired "makeDarwinRunScript";
        makeRunScript = _: throwOsxKvmRequired "makeRunScript";
      };

  # ==========================================================================
  # Import Windows VM builder
  # ==========================================================================
  windowsBuilder = import ./windows {
    inherit pkgs lib;
    yaml-automation-runner = resolvedYamlAutomationRunner;
  };

in
{
  # ==========================================================================
  # ISO/Image Fetchers - Top-level exports for convenience
  # ==========================================================================

  # Fetch Ubuntu cloud-init QCOW2 images from official Ubuntu cloud images repository
  # Parameters: { version, codename, sha256 }
  # Example: fetchUbuntuCloudImage { version = "24.04"; codename = "noble"; sha256 = "..."; }
  inherit (isoFetchers) fetchUbuntuCloudImage;

  # Fetch macOS BaseSystem.img from Apple CDN (requires osx-kvm input)
  # Parameters: { release, sha256 }
  # Example: fetchMacOSBaseSystem { release = "sonoma"; sha256 = "sha256-..."; }
  inherit (isoFetchers) fetchMacOSBaseSystem;

  # Fetch macOS InstallAssistant.pkg and convert to ISO
  # Parameters: { majorVersion, sha256 }
  # Example: fetchMacOSInstallAssistant { majorVersion = 14; sha256 = "sha256-..."; }
  inherit (isoFetchers) fetchMacOSInstallAssistant;

  # Fetch VirtIO drivers ISO for Windows VMs
  # Parameters: { version?, sha256 }
  # Example: fetchVirtIODrivers { sha256 = "sha256-..."; }
  inherit (isoFetchers) fetchVirtIODrivers;

  # Validate a user-provided Windows ISO for required installation files
  # Parameters: { isoPath }
  # Returns: Derivation with validation results in JSON format
  inherit (isoFetchers) validateWindowsISO;

  # ==========================================================================
  # Linux VM Builders
  # ==========================================================================
  linux = {
    # Create a bootable Linux VM from a cloud image
    # Parameters: { name, cloudImage, hostname, username, sshPort, memory?, cpus?, diskSize?, installNix?, ahFollowerdPath? }
    inherit (linuxBuilder) makeLinuxVM;

    # Cloud-init utilities
    cloudInit = {
      # Generate cloud-init configuration files
      # Parameters: { hostname, username, sshPublicKey, sshPort?, installNix?, ahFollowerdPath? }
      inherit (cloudInit) makeCloudInitConfig;

      # Generate a test SSH key pair (for testing only, not secure)
      # Parameters: { name? }
      inherit (cloudInit) generateTestSSHKey;
    };
  };

  # ==========================================================================
  # Darwin (macOS) VM Builders
  # ==========================================================================
  darwin = {
    # Build a macOS VM image with automated OOBE setup
    # Parameters: { name, baseSystemImg, installAssistantIso, automationConfig, diskSizeBytes?, memoryMB?, cpuCores?, sshPort?, vncDisplay?, username?, password?, allowImpure? }
    inherit (darwinBuilder) makeDarwinVM;

    # Create a cached boot test script for a pre-built macOS VM
    # Parameters: { vmDir, sshPort?, memoryMB?, cpuCores?, vncDisplay?, username?, password?, bootTimeoutSeconds?, sshRetries?, sshRetryDelay? }
    inherit (darwinBuilder) makeDarwinCachedBootTest;

    # Create a run script for a macOS VM directory (output of makeDarwinVM)
    # Parameters: { sshPort?, memoryMB?, cpuCores?, vncDisplay?, username?, password? }
    inherit (darwinBuilder) makeDarwinRunScript;

    # Create a run script for an existing macOS VM image (standalone QCOW2)
    # Parameters: { diskImage, sshPort?, memoryMB?, cpuCores?, username?, password? }
    inherit (darwinBuilder) makeRunScript;
  };

  # ==========================================================================
  # Windows VM Builders
  # ==========================================================================
  windows = {
    # Generate a customized autounattend.xml file for Windows unattended installation
    # Parameters: { username?, password?, computerName?, timezone?, virtioDriverPath?, locale? }
    inherit (windowsBuilder) generateAutounattendXml;

    # Create a floppy disk image containing the autounattend.xml
    # Parameters: { autounattendXml, additionalFiles? }
    inherit (windowsBuilder) makeAutounattendFloppy;

    # Create an ISO image containing the autounattend.xml
    # Parameters: { autounattendXml, additionalFiles?, volumeLabel? }
    inherit (windowsBuilder) makeAutounattendIso;

    # Build a complete Windows VM installation package (scripts + media)
    # Parameters: { name, windowsIsoPath, username?, password?, computerName?, timezone?, memoryMB?, cpuCores?, diskSizeGB?, sshPort?, rdpPort?, vncDisplay?, useIso? }
    inherit (windowsBuilder) makeWindowsVMPackage;

    # Build a Windows VM image with automated unattended installation
    # Parameters: { name, windowsIso, virtioDriversIso, automationConfig?, diskSizeGB?, memoryMB?, cpuCores?, sshPort?, rdpPort?, vncDisplay?, username?, password?, computerName?, timezone?, installTimeoutSeconds?, enableTpm?, allowImpure? }
    inherit (windowsBuilder) makeWindowsVM;

    # Create a run script for a Windows VM directory (output of makeWindowsVM)
    # Parameters: { sshPort?, rdpPort?, memoryMB?, cpuCores?, vncDisplay?, username?, password? }
    inherit (windowsBuilder) makeWindowsRunScript;

    # Create a cached boot test script for a pre-built Windows VM
    # Parameters: { vmDir, sshPort?, rdpPort?, memoryMB?, cpuCores?, vncDisplay?, username?, password?, bootTimeoutSeconds?, sshRetries?, sshRetryDelay? }
    inherit (windowsBuilder) makeWindowsCachedBootTest;

    # Create a health check script for Windows VM (SSH-based)
    # Parameters: { sshPort?, username?, password?, bootTimeoutSeconds?, sshRetries?, sshRetryDelay? }
    inherit (windowsBuilder) makeWindowsHealthCheck;
  };

  # ==========================================================================
  # Automation Engine
  # ==========================================================================

  # The YAML automation runner for GUI automation via VNC + OCR
  # This is either the provided yaml-automation-runner or auto-created from packages/vm-automation
  yaml-automation-runner = resolvedYamlAutomationRunner;

  # ==========================================================================
  # Automation Configs
  # ==========================================================================

  # Pre-built YAML automation configs for unattended OS installation.
  # These configs automate the OOBE (Out-of-Box Experience) setup via VNC + OCR,
  # creating VMs with SSH enabled and admin/admin credentials.
  #
  # Usage:
  #   vmImages.darwin.makeDarwinVM {
  #     automationConfig = vmImages.automationConfigs.macos-sequoia;
  #     ...
  #   };
  automationConfigs =
    let
      configsDir = ../packages/vm-automation/configs;
    in
    {
      macos-ventura = configsDir + /macos-ventura.yml;
      macos-sonoma = configsDir + /macos-sonoma.yml;
      macos-sequoia = configsDir + /macos-sequoia.yml;
      macos-tahoe = configsDir + /macos-tahoe.yml;
      windows-11 = configsDir + /windows-11.yml;
    };

  # ==========================================================================
  # Raw module access (for advanced use cases)
  # ==========================================================================

  # Direct access to the underlying modules for advanced customization
  _internal = {
    inherit
      isoFetchers
      linuxBuilder
      cloudInit
      darwinBuilder
      windowsBuilder
      ;
  };
}
