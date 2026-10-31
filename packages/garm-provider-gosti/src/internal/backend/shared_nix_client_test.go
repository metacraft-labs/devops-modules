//go:build linux

package backend

// The fixture client below only records the selected NIX_REMOTE and argv. It
// keeps these real filesystem/process controls independent of a host daemon;
// it does not simulate Nix, Incus, daemon trust, or cross-guest reuse. The
// immutable-artifact probe and existing native shared-store gates cover those
// separate boundaries. Linux is the supported host scope of this client mode.

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func runSharedNixSetup(t *testing.T, bin, destination string) ([]byte, error) {
	t.Helper()
	return exec.Command("bash", "-c", sharedNixClientSetupScript, "--", bin, destination).CombinedOutput()
}

func TestSharedNixClientWrapperContract(t *testing.T) {
	root := t.TempDir()
	bin, destination := filepath.Join(root, "selected client"), filepath.Join(root, "output bin")
	for _, dir := range []string{bin, destination} {
		if err := os.Mkdir(dir, 0755); err != nil {
			t.Fatal(err)
		}
	}
	leaf := []byte("#!/bin/sh\nprintf '%s\\000' \"$NIX_REMOTE\" \"$@\"\n")
	for _, tool := range []string{"nix", "nix-store"} {
		if err := os.WriteFile(filepath.Join(bin, tool), leaf, 0755); err != nil {
			t.Fatal(err)
		}
	}
	sentinel := filepath.Join(destination, "unrelated")
	if err := os.WriteFile(sentinel, []byte("preserve"), 0640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destination, "nix"), []byte("stale"), 0755); err != nil {
		t.Fatal(err)
	}
	if output, err := runSharedNixSetup(t, bin, destination); err != nil {
		t.Fatalf("setup: %v: %s", err, output)
	}
	for _, tool := range []string{"nix", "nix-store"} {
		path := filepath.Join(destination, tool)
		actual, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		want := fmt.Sprintf("#!/bin/sh\nexport NIX_REMOTE=daemon\nexec \"%s\" \"$@\"\n", filepath.Join(bin, tool))
		if string(actual) != want {
			t.Fatalf("%s wrapper bytes: got %q, want %q", tool, actual, want)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0755 {
			t.Fatalf("%s mode: %v", tool, info.Mode())
		}
	}
	if _, err := os.Stat(filepath.Join(destination, "nix-env")); !os.IsNotExist(err) {
		t.Fatalf("missing optional client was fabricated: %v", err)
	}
	if actual, err := os.ReadFile(sentinel); err != nil || string(actual) != "preserve" {
		t.Fatalf("unrelated file changed: %q, %v", actual, err)
	}
	args := []string{"", "space value", "literal$[]*", "'quoted'"}
	command := exec.Command(filepath.Join(destination, "nix"), args...)
	command.Env = append(os.Environ(), "NIX_REMOTE=must-not-be-used")
	actual, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("wrapper: %v: %s", err, actual)
	}
	want := append([]byte("daemon\x00"), []byte("\x00space value\x00literal$[]*\x00'quoted'\x00")...)
	if !bytes.Equal(actual, want) {
		t.Fatalf("selected daemon/argv: got %q, want %q", actual, want)
	}
}

func TestSharedNixClientRejectsNonDirectoryDestination(t *testing.T) {
	root := t.TempDir()
	bin := filepath.Join(root, "client")
	if err := os.Mkdir(bin, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "nix"), []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(root, "not a directory")
	if err := os.WriteFile(destination, []byte("preserve"), 0644); err != nil {
		t.Fatal(err)
	}
	if output, err := runSharedNixSetup(t, bin, destination); err == nil {
		t.Fatalf("invalid destination passed: %s", output)
	}
	if actual, err := os.ReadFile(destination); err != nil || string(actual) != "preserve" {
		t.Fatalf("destination changed: %q, %v", actual, err)
	}
}
