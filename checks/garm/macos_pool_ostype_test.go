// Gate t_garm_macos_pools_supported (Runner-Fleet-M3-ARM-Wave MA11) — this file
// is the SINGLE SOURCE OF TRUTH for the macOS pool-path assertions. It is
// injected into BOTH a patched and an UNPATCHED garm tree by
// checks/t_garm_macos_pools_supported.sh, so the negative control runs the
// identical assertions, and it is the same file
// upstream-patches/garm-allow-macos-pools/open-pr.sh hands to upstream.
//
// WHAT IS UNDER TEST
//
//	GARM's OWN pool-creation parameter gate, `Runner.appendTagsToCreatePoolParams()`
//	— the exact function whose refusal the live controller reported as
//	    CreateOrgPool … {"details":"error fetching pool params: invalid OS type macos"}
//	Nothing is re-implemented: the real `params.CreatePoolParams` goes into the
//	real method on a real `Runner`. The only thing constructed by hand is the
//	provider map, because the gate's third check ("no such provider") is the
//	only other thing the method needs, and standing up a real external provider
//	would test the provider, not the allow-list.
//
//	The method is unexported, so this is an INTERNAL test (package runner). That
//	is deliberate and is what makes it a test of the real refusal rather than of
//	a re-derived predicate: an external test could only reach `IsSupportedOSType`,
//	which is a map lookup, and would pass even if the caller stopped consulting it.
//
// WHAT IS NOT MOCKED, AND WHY IT DOES NOT NEED TO BE
//
//	`appendTagsToCreatePoolParams` touches no store, no forge and no provider
//	behaviour — it calls `param.Validate()`, two allow-list lookups and one map
//	membership test. So there is no boundary here worth faking; a `nil` provider
//	value is sufficient because the code only ever asks whether the KEY exists.
package runner

import (
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"
	"github.com/cloudbase/garm/params"
	"github.com/cloudbase/garm/runner/common"
)

const macosGateProvider = "macos-gate-provider"

// runnerWithProvider builds the smallest Runner appendTagsToCreatePoolParams
// can be called on. Only the provider map is consulted.
func runnerWithProvider() *Runner {
	return &Runner{
		providers: map[string]common.Provider{
			macosGateProvider: nil,
		},
	}
}

// validPoolParams returns params that satisfy every check in
// CreatePoolParams.Validate(), so the ONLY thing that can make a case fail is
// the OS/arch allow-list under test. Note that Validate() itself does not look
// at OSType at all — the OS gate is exclusively IsSupportedOSType.
func validPoolParams(osType commonParams.OSType, osArch commonParams.OSArch) params.CreatePoolParams {
	return params.CreatePoolParams{
		ProviderName:   macosGateProvider,
		MaxRunners:     1,
		MinIdleRunners: 0,
		Image:          "golden",
		Flavor:         "default",
		OSType:         osType,
		OSArch:         osArch,
		Tags:           []string{"self-hosted", "macos", "arm64"},
		Enabled:        true,
	}
}

// TestMacOSPoolOSTypeAccepted is the assertion the live 400 corresponds to.
// It FAILS on an unpatched tree.
func TestMacOSPoolOSTypeAccepted(t *testing.T) {
	r := runnerWithProvider()
	in := validPoolParams(commonParams.OSType("macos"), commonParams.Arm64)

	out, err := r.appendTagsToCreatePoolParams(in)
	if err != nil {
		t.Fatalf("appendTagsToCreatePoolParams(os_type=macos) returned %v; the pool path still refuses macOS", err)
	}
	if out.OSType != commonParams.OSType("macos") {
		t.Fatalf("OSType was rewritten to %q; it must pass through untouched", out.OSType)
	}
	if out.ProviderName != macosGateProvider {
		t.Fatalf("ProviderName was rewritten to %q", out.ProviderName)
	}
}

// TestMacOSIsSupportedOSType checks the allow-list directly, so a failure can be
// attributed to the map rather than to the caller.
func TestMacOSIsSupportedOSType(t *testing.T) {
	if !IsSupportedOSType(commonParams.OSType("macos")) {
		t.Fatal("IsSupportedOSType(macos) is false — supportedOSType does not admit macOS")
	}
}

// TestLinuxAndWindowsPoolsStillAccepted is a property the change must NOT
// alter, and is what proves an unpatched run is failing for the right reason
// rather than because the test file does not build or the params are invalid.
// It passes on BOTH trees.
func TestLinuxAndWindowsPoolsStillAccepted(t *testing.T) {
	r := runnerWithProvider()
	for _, osType := range []commonParams.OSType{commonParams.Linux, commonParams.Windows} {
		if _, err := r.appendTagsToCreatePoolParams(validPoolParams(osType, commonParams.Amd64)); err != nil {
			t.Fatalf("appendTagsToCreatePoolParams(os_type=%s) returned %v; the pre-existing OS types must keep working", osType, err)
		}
		if !IsSupportedOSType(osType) {
			t.Fatalf("IsSupportedOSType(%s) is false", osType)
		}
	}
}

// TestUnknownOSTypeStillRejected: the allow-list must still be an allow-list.
// A change that simply removed the check would pass every test above and fail
// this one. Passes on BOTH trees.
func TestUnknownOSTypeStillRejected(t *testing.T) {
	r := runnerWithProvider()
	_, err := r.appendTagsToCreatePoolParams(validPoolParams(commonParams.OSType("plan9"), commonParams.Amd64))
	if err == nil {
		t.Fatal("appendTagsToCreatePoolParams(os_type=plan9) succeeded — the OS allow-list has been removed, not widened")
	}
	if !contains(err.Error(), "invalid OS type") {
		t.Fatalf("expected an 'invalid OS type' rejection, got %v", err)
	}
}

// TestUnsupportedArchStillRejected guards the neighbouring check, which sits in
// the same function and must not have been disturbed. Passes on BOTH trees.
func TestUnsupportedArchStillRejected(t *testing.T) {
	r := runnerWithProvider()
	_, err := r.appendTagsToCreatePoolParams(validPoolParams(commonParams.Linux, commonParams.OSArch("s390x")))
	if err == nil {
		t.Fatal("appendTagsToCreatePoolParams(os_arch=s390x) succeeded — the architecture allow-list was disturbed")
	}
	if !contains(err.Error(), "invalid OS architecture") {
		t.Fatalf("expected an 'invalid OS architecture' rejection, got %v", err)
	}
}

// TestUnknownProviderStillRejected proves the fixture reaches the END of the
// function (the provider-map lookup is the last check), so a macOS "pass" above
// is a real traversal and not an early return. Passes on BOTH trees.
func TestUnknownProviderStillRejected(t *testing.T) {
	r := runnerWithProvider()
	p := validPoolParams(commonParams.Linux, commonParams.Amd64)
	p.ProviderName = "no-such-provider"
	if _, err := r.appendTagsToCreatePoolParams(p); err == nil {
		t.Fatal("appendTagsToCreatePoolParams with an unregistered provider succeeded")
	}
}

func contains(haystack, needle string) bool {
	if len(needle) > len(haystack) {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
