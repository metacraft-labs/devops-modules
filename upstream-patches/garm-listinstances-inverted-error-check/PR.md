# Fix inverted error check in external provider ListInstances

## Summary

`ListInstances` in the v0.1.1 external provider guards the result of
`execWithTimeout` with an inverted condition (`if err == nil`), where every
sibling command in the same file uses `if err != nil`. This flips the single
line so the error branch fires only on a genuine failure.

## The bug

`runner/providers/v0.1.1/external.go`, in `ListInstances`:

```go
out, err := e.execWithTimeout(ctx, nil, asEnv)
if err == nil {   // <-- inverted; should be `if err != nil`
    metrics.InstanceOperationFailedCount.WithLabelValues(
        "ListInstances", e.cfg.Name, e.cfg.ProviderType, e.controllerID,
    ).Inc()
    return []commonParams.ProviderInstance{}, garmErrors.NewProviderError(
        "provider binary %s returned error: %s", e.execPath, err)
}
```

Every other command in this file — `CreateInstance`, `DeleteInstance`,
`GetInstance`, `RemoveAllInstances`, `Start`, `Stop` — correctly uses
`if err != nil`. `ListInstances` is the only outlier.

## Impact

On a **successful** provider `ListInstances` run (`err == nil`), GARM takes the
failure branch:

- it formats the `nil` error with `%s`, logging
  `provider binary <path> returned error: %!s(<nil>)` on every list cycle
  (recurring ERROR log spam);
- it returns an **empty** instance slice and never parses the provider's real
  output;
- so scale-set runner-state consolidation (`consolidateRunnerState`) never sees
  the instances the provider actually reported — producing genuine runner
  **state drift** for external providers.

We hit the `%!s(<nil>)` errors continuously on a GARM deployment using an
external provider, which is how this surfaced.

## The fix

Flip the check to `if err != nil`, so the error branch fires only on a genuine
provider failure and the successful output is parsed as intended — matching all
sibling commands. One line.

## Testing

Builds cleanly (`go build ./...`); on the external-provider list path the parsed
instances are now returned on success, and an error is returned only when the
provider binary genuinely fails.

<!-- After opening, record the PR URL here: -->
<!-- PR: https://github.com/cloudbase/garm/pull/XXXX -->
