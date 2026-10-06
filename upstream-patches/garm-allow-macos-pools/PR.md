# Allow macOS pools, matching what scale sets already accept

## Summary

GARM accepts `os_type: macos` on a **runner scale set** and refuses it on a
**pool**, for no reason that survives reading the code. One line closes the
gap. It needs a companion one-line change in `garm-provider-common` first,
because that is where the `OSType` constants live.

## The bug

`runner/types.go` declares the OS allow-list:

```go
var (
	supportedOSType map[params.OSType]struct{} = map[params.OSType]struct{}{
		params.Linux:   {},
		params.Windows: {},
	}
)

func IsSupportedOSType(osType params.OSType) bool {
	_, ok := supportedOSType[osType]
	return ok
}
```

`IsSupportedOSType` has exactly one caller in the whole tree —
`appendTagsToCreatePoolParams()` in `runner/runner.go`:

```go
if !IsSupportedOSType(param.OSType) {
	return params.CreatePoolParams{}, runnerErrors.NewBadRequestError("invalid OS type %s", param.OSType)
}
```

which every entity's create-pool endpoint goes through
(`CreateRepoPool`, `CreateOrgPool`, `CreateEnterprisePool`, `CreateEntityPool`).

The scale-set path has no equivalent. `CreateScaleSetParams.Validate()`
(`params/requests.go`) checks the provider name, the runner counts, the flavor,
the image and the name — and not the OS. `CreateEntityScaleSet()` never calls
`appendTagsToCreatePoolParams` or any allow-list. `CreatePoolParams.Validate()`
is the same shape as its scale-set sibling and likewise does not look at
`OSType`; the entire difference is that one code path additionally calls
`IsSupportedOSType`.

So the same declaration is accepted as a scale set and rejected as a pool:

```
POST /organizations/{orgID}/pools
400 {"error":"Bad Request","details":"error fetching pool params: invalid OS type macos"}
```

## Impact

Anyone running macOS runners through an external provider can use scale sets
and cannot use pools. That is not a small difference in practice: a scale set
is addressed by its single precise name as the whole `runs-on` value, while a
pool provisions classic runners carrying labels, which is what a
`runs-on: [self-hosted, macos, arm64]` label array matches. A fleet that moves
from scale sets to labelled pools loses its macOS classes entirely at the
moment it moves, and the failure arrives as a 400 during reconciliation rather
than as anything a user could have anticipated from the documentation.

It is also a fail-stop for a declarative reconciler: one refused pool aborts
the run, so the pools declared after it are never created either.

## The fix

Add `params.MacOS: {}` to `supportedOSType`. One line.

Nothing behind the allow-list requires Linux or Windows for an external
provider. For a pool, `OSType` is:

- stored on the pool and copied onto each instance;
- exported as the `os_type` metrics label (a free-form string);
- used to select the runner-install template, which is a name lookup against
  the templates table, not an allow-list;
- passed verbatim to the provider inside `BootstrapInstance`, which
  `runner/providers/v0.1.1/external.go` JSON-marshals whole.

JIT config generation and runner registration never consult it: neither
`GetEntityJITConfig` nor `GenerateJitRunnerConfig` takes an OS argument, and
no OS-derived label is ever added to a runner (`ResolveToGithubTag`, the helper
that would do that, has no callers).

## What this change deliberately does not do

Two paths still accept only Linux and Windows, and both are out of scope here
because they need their own testing story rather than a map entry:

- `util.GetTools()` in `garm-provider-common` filters the GitHub runner
  download list and rejects an unknown OS outright; it also maps OS names
  through `githubOSTypeMap`, which has no macOS entry (GitHub labels those
  downloads `osx`). It is reached from `GetInstanceMetadata` and
  `GetRunnerInstallScript` — i.e. from the metadata service. A provider that
  renders its own runner bootstrap and only uses the JIT-credentials and
  callback endpoints, which is what the Apple-silicon providers do, never
  reaches it.
- `cloudconfig.InstallRunnerScript()` / `GetCloudConfig()` in
  `garm-provider-common`, which providers use only when they have not supplied
  their own `runner_install_template`.

Mentioning them explicitly so the scope of this PR is not mistaken for a claim
that macOS is supported everywhere.

## Ordering: this needs a garm-provider-common change first

`OSType` and its constants are defined in
`cloudbase/garm-provider-common/params`, which has `Windows`, `Linux` and
`Unknown` only. The companion patch adds `MacOS OSType = "macos"` there. That
is worth doing as a named constant rather than an inline
`params.OSType("macos")` because external providers already spell that string
inline today, and garm's allow-lists should be able to refer to it.

So: merge `garm-provider-common#<n>`, tag it, bump `garm`'s `go.mod` and
`vendor/`, then merge this.

## Testing

`runner/macos_pool_ostype_test.go` drives the real
`Runner.appendTagsToCreatePoolParams()` — the function that produced the 400 —
against a `Runner` carrying a registered provider, and asserts:

- `macos` is accepted, and the returned params are unchanged;
- `linux` and `windows` are still accepted (the change adds, never replaces);
- an unknown OS type is still rejected with `invalid OS type`, so the
  allow-list is still an allow-list;
- an unsupported _architecture_ is still rejected, so the neighbouring check
  was not disturbed;
- `IsSupportedOSType` agrees with all of the above.

Every macOS assertion fails without this change and passes with it; the others
pass on both.

<!-- After opening, record the PR URLs here: -->
<!-- garm-provider-common PR: https://github.com/cloudbase/garm-provider-common/pull/XXXX -->
<!-- garm PR: https://github.com/cloudbase/garm/pull/XXXX -->
