module mcl.commands.get_fstab;

import std.stdio : writeln;
import std.conv : to;
import std.json : JSONValue;
import std.format : fmt = format;
import std.exception : enforce;

import argparse : Command, Description, NamedArgument, PositionalArgument, Required, Placeholder, EnvFallback;

import mcl.utils.cachix : cachixNixStoreUrl, getCachixDeploymentApiUrl;
import mcl.utils.fetch : fetchJson;
import mcl.utils.nix : queryStorePath, nix;
import mcl.utils.string : camelCaseToCapitalCase;
import mcl.utils.process : execute;

export int get_fstab(GetFstabArgs args)
{
    args.cachixStoreUrl = cachixNixStoreUrl(args.cachixCache);
    if (!args.cachixDeployWorkspace)
        args.cachixDeployWorkspace = args.cachixCache;

    const machineStorePath = getCachixDeploymentStorePath(args);
    const fstabStorePath = queryStorePath(
        machineStorePath,
        ["-etc", "-etc-fstab"],
        args.cachixStoreUrl
    );
    nix.build(fstabStorePath);
    writeln(fstabStorePath);
    return 0;
}

@(Command("get-fstab", "get_fstab")
    .Description("Get the store path of the fstab file for a deployment"))
struct GetFstabArgs
{
    @(NamedArgument(["cachix-auth-token"]).Required().Placeholder("XXX").Description("Auth Token for Cachix").EnvFallback("CACHIX_AUTH_TOKEN"))
    string cachixAuthToken;
    @(NamedArgument(["cachix-cache"]).Required().Placeholder("cache").Description("Which Cachix cache to use").EnvFallback("CACHIX_CACHE"))
    string cachixCache;

    @(NamedArgument(["cachix-store-url"]).Placeholder("https://...").Description("URL of the Cachix store"))
    string cachixStoreUrl = "";
    @(NamedArgument(["cachix-deploy-workspace"]).Placeholder("agent-workspace").Description("Cachix workspace to deploy to"))
    string cachixDeployWorkspace = "";

    @(PositionalArgument(0).Placeholder("machine-name").Description("Name of the machine"))
    string machineName;
    @(PositionalArgument(1).Placeholder("deployment-id").Description("ID of the deployment"))
    uint deploymentId;
}

string getCachixDeploymentStorePath(GetFstabArgs args)
{
    const url = getCachixDeploymentApiUrl(args.cachixDeployWorkspace, args.machineName, args.deploymentId);
    const response = fetchJson(url, args.cachixAuthToken);
    return response["storePath"].get!string;
}
