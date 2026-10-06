module mcl.utils.cachix;

import mcl.utils.test;

import mcl.commands.ci_matrix : Package;

import std.algorithm : map;
import std.array : assocArray;
import std.format : fmt = format;
import std.json : JSONValue;
import std.typecons : tuple;

string getCachixDeploymentApiUrl(string workspace, string machine, uint deploymentId)
in (workspace && machine && deploymentId) =>
    "https://app.cachix.org/api/v1/deploy/deployment/%s/%s/%s"
    .fmt(workspace, machine, deploymentId);

@("getCachixDeploymentApiUrl")
unittest
{
    assert(getCachixDeploymentApiUrl("my-workspace", "my-machine", 123) ==
            "https://app.cachix.org/api/v1/deploy/deployment/my-workspace/my-machine/123");

}

string cachixNixStoreUrl(string cachixCache) =>
    "https://%s.cachix.org".fmt(cachixCache);

@("cachixNixStoreUrl")
unittest
{
    assert(cachixNixStoreUrl("my-cache") == "https://my-cache.cachix.org");
}

struct DeploySpec
{
    string[string] agents;

    void toString(W)(auto ref W writer) const
    {
        import std.range : byPair;
        import std.format : formattedWrite;
        writer.formattedWrite("DeploySpec(\n  agents: [\n");
        writer.formattedWrite("    %(%(%s: %s%)\n    %)", agents.byPair);
        writer.formattedWrite("  ]\n)");
    }
}

DeploySpec createMachineDeploySpec(Package[] packages) =>
    DeploySpec(
        agents: packages
            .map!(pkg => tuple(pkg.name, pkg.output))
            .assocArray
    );

@("createMachineDeploySpec")
unittest
{
    import std.json : parseJSON;

    // Command was used to generate the store path hash:
    // nix hash file --base32 (echo test | psub) | head -c 32

    auto result = createMachineDeploySpec([
        Package(name: "my-machine-1", output: "/nix/store/1lkgqb6fclns49861dwk9rzb6xnfkxbp-nixos-system-my-machine-1-24.05.20240711.a046c12"),
        Package(name: "my-machine-2", output: "/nix/store/1x9gyyamm7d9p2hm06hx9vx6gm4sd1mk-nixos-system-my-machine-2-24.05.20240711.a046c12"),
    ]);

    assert(result == DeploySpec(
        agents: [
            "my-machine-1":"/nix/store/1lkgqb6fclns49861dwk9rzb6xnfkxbp-nixos-system-my-machine-1-24.05.20240711.a046c12",
            "my-machine-2":"/nix/store/1x9gyyamm7d9p2hm06hx9vx6gm4sd1mk-nixos-system-my-machine-2-24.05.20240711.a046c12"
        ]
    ));
}
