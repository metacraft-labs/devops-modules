# Add a MacOS OSType constant

## Summary

`OSType` has constants for Windows and Linux only, so every caller that wants
to talk about a macOS guest has to spell `params.OSType("macos")` inline. This
adds `MacOS OSType = "macos"` next to the existing constants.

## Why

External providers already use that string inline: a provider driving Apple
Virtualization guests has no other way to say what it is running. The same
string is what garm stores, what it exports as the `os_type` metrics label,
and what it hands back in `BootstrapInstance`. Naming it once means garm and
the providers agree on the spelling, and garm's OS allow-lists can refer to it
by constant. A companion garm PR uses it to accept `os_type=macos` for pools,
matching what scale sets already accept.

## What this does not do

It adds a name. It does not make any existing code path treat macOS
differently. In particular `util.GetTools()` and `cloudconfig` still accept
only Linux and Windows. A provider that renders its own runner bootstrap does
not reach them, and widening them is a separate change with its own testing
story.

## Testing

`go build ./...` and `go test ./...` pass. The change is a single new constant
and changes no behaviour, so it carries no test of its own; the garm PR that
uses it tests the pool path end to end.

<!-- After opening, record the PR URL here: -->
<!-- PR: https://github.com/cloudbase/garm-provider-common/pull/XXXX -->
