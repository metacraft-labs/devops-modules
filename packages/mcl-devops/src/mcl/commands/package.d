module mcl.commands;

import std.meta : ApplyLeft, staticMap;

private enum commandModulesToExport =
[
    "mcl.commands.deploy_apply" : ["deploy_apply"],
    "mcl.commands.deploy_agent" : ["deploy_agent"],
    "mcl.commands.deploy_plan" : ["deploy_plan"],
    "mcl.commands.deploy_reconcile" : ["deploy_reconcile"],
    "mcl.commands.deploy_spec" : ["deploy_spec"],
    "mcl.commands.deploy_status" : ["deploy_status"],
    "mcl.commands.deploy_ssh" : ["deploy_ssh"],
    "mcl.commands.cache" : ["cache"],
    "mcl.commands.ci_matrix" : ["ci_matrix", "print_table", "merge_ci_matrices"],
    "mcl.commands.shard_matrix" : ["shard_matrix"],
    "mcl.commands.ci" : ["ci"],
    "mcl.commands.host_info" : ["host_info"],
    "mcl.commands.machine" : ["machine"],
    "mcl.commands.config" : ["config"],
    "mcl.commands.hosts" : ["hosts"],
    "mcl.commands.secret" : ["secret"],
];

template ImportAll(alias aa)
{
    import std.meta : AliasSeq;
    alias A = AliasSeq!();
    static foreach (moduleName, symbols; aa)
        static foreach (symbolName; symbols)
            A = AliasSeq!(A, __traits(getMember, imported!moduleName, symbolName));
    alias ImportAll = A;
}

alias SubCommandFunctions = ImportAll!commandModulesToExport;
