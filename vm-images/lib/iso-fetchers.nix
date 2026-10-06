# VM ISO and Cloud Image Fetchers
#
# This module provides fixed-output derivations (FODs) for fetching VM images
# from official sources. FODs are required for Nix sandbox builds since they
# allow network access during the fetch phase while ensuring reproducibility
# through hash verification.
#
# References:
# - Ubuntu Cloud Images: https://cloud-images.ubuntu.com/releases/
# - macOS Recovery Images: fetch-macOS-v2.py from OSX-KVM
# - Windows VirtIO Drivers: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/
# - Nix FOD documentation: https://nixos.org/manual/nix/stable/language/advanced-attributes.html#adv-attr-outputHash

{
  pkgs,
  osx-kvm ? null,
  # Default to the fetch-installassistant.py script in the same directory
  fetchInstallAssistantScript ? ./fetch-installassistant.py,
}:

{
  # Fetch Ubuntu cloud-init QCOW2 images from official Ubuntu cloud images repository.
  #
  # Parameters:
  #   version: Ubuntu version (e.g., "24.04", "22.04")
  #   codename: Ubuntu codename (e.g., "noble", "jammy")
  #   sha256: Expected SHA256 hash of the image file
  #
  # Returns: A derivation that downloads and verifies the Ubuntu cloud image
  #
  # Example usage:
  #   fetchUbuntuCloudImage {
  #     version = "24.04";
  #     codename = "noble";
  #     sha256 = "2b5f90ffe8180def601c021c874e55d8303e8bcbfc66fee2b94414f43ac5eb1f";
  #   }
  fetchUbuntuCloudImage =
    {
      version,
      codename,
      sha256,
      # Immutable dated respin directory, e.g. "release-20260615". The
      # default "release" is a ROLLING pointer that Canonical re-publishes
      # in place (~weekly, on every point release / security respin), so its
      # content -- and therefore this fixed-output hash -- is not
      # reproducible. Pin a dated directory to make the FOD stable.
      releaseDir ? "release",
    }:
    let
      # Construct the download URL for the release image
      # Format: https://cloud-images.ubuntu.com/releases/{codename}/{releaseDir}/ubuntu-{version}-server-cloudimg-amd64.img
      url = "https://cloud-images.ubuntu.com/releases/${codename}/${releaseDir}/ubuntu-${version}-server-cloudimg-amd64.img";

      # Image name for the derivation
      name = "ubuntu-${version}-server-cloudimg-amd64.img";
    in
    pkgs.fetchurl {
      inherit name url sha256;

      # Additional metadata for better derivation documentation
      meta = {
        description = "Ubuntu ${version} (${codename}) server cloud image for QEMU/KVM";
        homepage = "https://cloud-images.ubuntu.com/";
        # Cloud images are published under Ubuntu's standard license
        license = pkgs.lib.licenses.free;
      };
    };

  # Fetch macOS BaseSystem.img from Apple CDN using fetch-macOS-v2.py
  #
  # Parameters:
  #   release: macOS release name (e.g., "ventura", "sonoma")
  #   sha256: Expected SHA256 hash of the resulting BaseSystem.img file
  #
  # Returns: A derivation that downloads BaseSystem.dmg from Apple CDN and converts it to .img
  #
  # Example usage:
  #   fetchMacOSBaseSystem {
  #     release = "ventura";
  #     sha256 = "sha256-Qy9Whu8pqHo+m6wHnCIqURAR53LYQKc0r87g9eHgnS4=";
  #   }
  #
  # This function uses the fetch-macOS-v2.py script from OSX-KVM to download the BaseSystem.dmg
  # from Apple's CDN, then converts it to .img format using dmg2img. The resulting image can be
  # used to boot macOS in QEMU for automated VM testing.
  #
  # References:
  # - OSX-KVM: https://github.com/kholia/OSX-KVM
  # - fetch-macOS-v2.py: https://github.com/kholia/OSX-KVM/blob/master/fetch-macOS-v2.py
  fetchMacOSBaseSystem =
    {
      release,
      sha256,
    }:
    if osx-kvm == null then
      throw "fetchMacOSBaseSystem requires osx-kvm input to be provided"
    else
      pkgs.runCommand "BaseSystem-${release}.img"
        {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.dmg2img
            pkgs.qemu_kvm
          ];
          outputHashAlgo = "sha256";
          outputHash = sha256;
          outputHashMode = "recursive";
        }
        ''
          # Copy fetch-macOS-v2.py script from osx-kvm input
          cp --no-preserve=mode ${osx-kvm}/fetch-macOS-v2.py .
          chmod +x ./fetch-macOS-v2.py
          patchShebangs ./fetch-macOS-v2.py

          # Download BaseSystem.dmg from Apple CDN
          # The --shortname parameter specifies the macOS release (e.g., ventura, sonoma)
          ./fetch-macOS-v2.py --shortname ${release}

          # Convert DMG to IMG format for QEMU
          # dmg2img extracts the disk image from the DMG container
          dmg2img -i BaseSystem.dmg $out
        '';

  # Fetch VirtIO drivers ISO for Windows VMs
  #
  # Parameters:
  #   version: VirtIO driver version (e.g., "0.1.285")
  #   sha256: Expected SHA256 hash of the ISO file
  #
  # Returns: A derivation that downloads the VirtIO drivers ISO from Fedora
  #
  # Example usage:
  #   fetchVirtIODrivers {
  #     version = "0.1.285";
  #     sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  #   }
  #
  # The VirtIO drivers ISO contains Windows drivers for:
  #   - VirtIO block devices (viostor) - required for disk access
  #   - VirtIO network adapters (netkvm) - required for network access
  #   - VirtIO balloon driver (balloon) - for memory management
  #   - VirtIO serial driver (vioserial) - for host-guest communication
  #   - QEMU guest agent (qemu-ga) - for VM management
  #
  # These drivers are required for Windows guests to use VirtIO devices in QEMU/KVM,
  # which provide better performance than emulated IDE/e1000 devices.
  #
  # References:
  # - Fedora VirtIO-Win: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/
  # - VirtIO-Win GitHub: https://github.com/virtio-win/virtio-win-pkg-scripts
  # - Quickemu: vendor/vm-research/quickemu/quickget (lines ~3342)
  fetchVirtIODrivers =
    {
      version ? "0.1.285",
      sha256,
    }:
    let
      # The stable-virtio directory always contains the latest stable version
      # For specific versions, use the archive directory
      url = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso";

      # Alternative URL for specific versions (in archive):
      # archiveUrl = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-${version}-1/virtio-win-${version}.iso";

      name = "virtio-win-${version}.iso";
    in
    pkgs.fetchurl {
      inherit name url sha256;

      meta = {
        description = "VirtIO drivers for Windows guests in QEMU/KVM (version ${version})";
        homepage = "https://fedorapeople.org/groups/virt/virtio-win/";
        # VirtIO-Win drivers are under various licenses (Red Hat, Microsoft)
        # The package itself is distributed by Fedora under their terms
        license = pkgs.lib.licenses.unfree;
      };
    };

  # Validate a user-provided Windows ISO for required installation files
  #
  # Parameters:
  #   isoPath: Path to the Windows ISO file (string)
  #
  # Returns: An attribute set with:
  #   - valid: boolean indicating if the ISO appears to be a valid Windows installer
  #   - errors: list of error messages if validation failed
  #   - warnings: list of warning messages
  #
  # This function checks for the presence of required Windows installation files:
  #   - boot.wim or install.wim (Windows installation image)
  #   - bootx64.efi or bootia32.efi (EFI boot files)
  #
  # Note: This is a helper function, not a derivation. It can be used during
  # evaluation time to validate user-provided ISO paths before attempting to
  # use them in VM builds.
  #
  # Example usage:
  #   let
  #     validation = validateWindowsISO { isoPath = "/path/to/windows.iso"; };
  #   in
  #   if validation.valid then
  #     # proceed with VM build
  #   else
  #     throw "Invalid Windows ISO: ${builtins.concatStringsSep ", " validation.errors}"
  #
  # References:
  # - Windows ISO structure: https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/wim-files
  # - UEFI boot requirements: https://uefi.org/specs/UEFI/2.10/
  validateWindowsISO =
    { isoPath }:
    let
      # This derivation mounts the ISO and checks for required files
      # It outputs a JSON file with validation results
      validationScript =
        pkgs.runCommand "validate-windows-iso"
          {
            nativeBuildInputs = [
              pkgs.p7zip
              pkgs.jq
            ];
            # Allow network access since we're reading a user-provided file
            __impure = true;
          }
          ''
            # Initialize validation state
            VALID=true
            ERRORS="[]"
            WARNINGS="[]"

            add_error() {
              ERRORS=$(echo "$ERRORS" | ${pkgs.jq}/bin/jq --arg err "$1" '. + [$err]')
              VALID=false
            }

            add_warning() {
              WARNINGS=$(echo "$WARNINGS" | ${pkgs.jq}/bin/jq --arg warn "$1" '. + [$warn]')
            }

            ISO_PATH="${isoPath}"

            # Check if the ISO file exists
            if [ ! -f "$ISO_PATH" ]; then
              add_error "ISO file not found: $ISO_PATH"
            else
              # List the contents of the ISO using 7z
              CONTENTS=$(${pkgs.p7zip}/bin/7z l "$ISO_PATH" 2>/dev/null || echo "")

              if [ -z "$CONTENTS" ]; then
                add_error "Unable to read ISO contents (file may be corrupted or not a valid ISO)"
              else
                # Check for Windows installation images (boot.wim or install.wim)
                if echo "$CONTENTS" | grep -qi "boot\.wim\|install\.wim"; then
                  echo "Found Windows installation image (WIM file)"
                else
                  add_error "Missing Windows installation image (boot.wim or install.wim not found)"
                fi

                # Check for EFI boot files
                if echo "$CONTENTS" | grep -qi "bootx64\.efi\|bootia32\.efi"; then
                  echo "Found EFI boot files"
                else
                  add_warning "Missing EFI boot files (bootx64.efi or bootia32.efi) - ISO may not boot in UEFI mode"
                fi

                # Check for sources directory (standard Windows ISO structure)
                if echo "$CONTENTS" | grep -qi "sources/"; then
                  echo "Found sources directory (standard Windows ISO structure)"
                else
                  add_warning "Missing sources directory - ISO may have non-standard structure"
                fi
              fi
            fi

            # Write validation results as JSON
            mkdir -p $out
            ${pkgs.jq}/bin/jq -n \
              --argjson valid "$VALID" \
              --argjson errors "$ERRORS" \
              --argjson warnings "$WARNINGS" \
              '{valid: $valid, errors: $errors, warnings: $warnings}' \
              > $out/validation.json
          '';
    in
    # Note: This returns the derivation path. To get actual results,
    # the caller must build this and read the JSON output.
    # For evaluation-time validation, users should build this derivation
    # and read the results, or use a different approach with IFD.
    validationScript;

  # Fetch macOS InstallAssistant.pkg dynamically from Apple's Software Update Catalog
  #
  # This function uses fetch-installassistant.py to dynamically discover and download
  # the latest InstallAssistant.pkg for a specified macOS version, then converts it to ISO.
  #
  # Parameters:
  #   majorVersion: macOS major version number (e.g., 14 for Sonoma, 13 for Ventura)
  #   sha256: Expected SHA256 hash of the resulting ISO file
  #
  # Returns: A derivation containing the InstallAssistant as an ISO image
  #
  # Example usage:
  #   fetchMacOSInstallAssistant {
  #     majorVersion = 14;  # Sonoma
  #     sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  #   }
  #
  # The InstallAssistant.pkg contains the full macOS installer and is required
  # for automated VM installation. We convert it to ISO format for QEMU.
  #
  # This approach is more robust than hardcoded URLs since it dynamically fetches
  # current URLs from Apple's software update catalog, similar to how fetch-macOS-v2.py
  # works for BaseSystem images.
  #
  # References:
  # - NixThePlanet: vendor/vm-research/NixThePlanet/makeDarwinImage/default.nix
  # - Apple Software Update Catalog: https://swscan.apple.com/
  fetchMacOSInstallAssistant =
    {
      majorVersion,
      sha256,
    }:
    pkgs.runCommand "InstallAssistant-macos${toString majorVersion}.iso"
      {
        nativeBuildInputs = [
          (pkgs.python3.withPackages (ps: [ ps.certifi ]))
          pkgs.cdrkit
          pkgs.xar
          pkgs.pbzx
          pkgs.cpio
        ];
        outputHashAlgo = "sha256";
        outputHash = sha256;
        outputHashMode = "flat";
      }
      ''
        # Copy and make executable our fetch script
        cp --no-preserve=mode ${fetchInstallAssistantScript} ./fetch-installassistant.py
        chmod +x ./fetch-installassistant.py
        ${pkgs.python3}/bin/python3 ./fetch-installassistant.py --version ${toString majorVersion} --output-dir . > download-log.txt 2>&1

        # The script outputs the path to the downloaded .pkg file
        PKG_FILE=$(tail -1 download-log.txt)

        if [ ! -f "$PKG_FILE" ]; then
          echo "Error: InstallAssistant.pkg not found"
          cat download-log.txt
          exit 1
        fi

        echo "Downloaded: $PKG_FILE"
        ls -lh "$PKG_FILE"

        # Extract the PKG to get the Install macOS *.app bundle
        # The PKG contains:
        #   - Payload: pbzx-compressed cpio archive with the .app bundle
        #   - SharedSupport.dmg: The actual installer data (13GB)
        echo "Extracting PKG..."
        mkdir -p pkg_extract
        cd pkg_extract
        ${pkgs.xar}/bin/xar -xf "../$PKG_FILE"
        cd ..

        # Delete the PKG immediately to free up 13GB
        rm "$PKG_FILE"

        # Extract the Payload to get the .app bundle
        cd pkg_extract
        mkdir -p payload_contents
        cd payload_contents
        ${pkgs.pbzx}/bin/pbzx -n ../Payload | ${pkgs.cpio}/bin/cpio -i 2>&1
        cd ../..

        # Create ISO contents directory and move (not copy) to save space
        mkdir -p iso_contents

        # Move the extracted .app bundle to the ISO root
        # The run_offline.sh script expects to find "Install macOS *.app" at /Volumes/
        mv pkg_extract/payload_contents/Applications/* iso_contents/

        # Move the SharedSupport.dmg from the PKG (rename to InstallAssistant.pkg)
        # The run_offline.sh script will copy this into the .app bundle
        mv pkg_extract/SharedSupport.dmg iso_contents/InstallAssistant.pkg

        # Clean up extraction directories to save space before mkisofs
        rm -rf pkg_extract

        echo "ISO contents:"
        ls -lh iso_contents/

        # Create ISO image containing both the .app bundle and the .pkg file
        # Options:
        #   -allow-limited-size: Allow files larger than 4GB
        #   -l: Allow 31-character filenames
        #   -J: Generate Joliet extension records
        #   -r: Generate Rock Ridge extension records
        #   -iso-level 3: Required for files > 4GB
        #   -V: Volume label
        mkisofs -allow-limited-size -l -J -r -iso-level 3 \
          -V InstallAssistant -o $out iso_contents/

        echo "Created ISO: $out"
        ls -lh $out
      '';
}
