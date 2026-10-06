module mcl.utils.deploy_manifest;

import std.algorithm : canFind, map, sort;
import std.array : array, join, split;
import std.conv : to;
import std.file : deleteme, exists, mkdir, readText, remove, rmdirRecurse, tempDir,
    write;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath;
import std.string : strip;
import std.typecons : Nullable;
import std.uuid : randomUUID;

import mcl.utils.deployment_events : ClosureSummary, storePathHash, utcTimestamp;
import mcl.utils.process : ProcessInputRunner, ProcessResult, ProcessRunner,
    runProcessCapture, runProcessWithInputCapture;

enum manifestSignatureAlgorithm = "openssh-signature-v1";
enum manifestSignatureNamespace = "mcl-deployment-manifest";

struct ManifestHealthCheck
{
    string name;
    string kind = "command";
    string target;
    ulong timeoutSeconds = 30;
}

struct ManifestSubstituter
{
    string url;
    string trustedPublicKey;
}

struct ManifestBuildRequest
{
    string deploymentId;
    string target;
    string system = "x86_64-linux";
    string gitRevision;
    ulong sequence;
    string desiredSystemPath;
    Nullable!ClosureSummary closure;
    ManifestSubstituter[] substituters;
    string availabilityMode = "none";
    bool requiredBeforeActivation;
    ManifestHealthCheck[] healthChecks;
    string rollbackMode = "manual";
    ulong rollbackMaxAttempts;
    string onHealthCheckFailure = "mark-failed";
    JSONValue supersededState = JSONValue(null);
    string currentState = "accepted";
}

struct ManifestSigningRequest
{
    string keyPath;
    string keyId;
}

string canonicalJson(JSONValue value)
{
    final switch (value.type)
    {
        case JSONType.object:
            auto keys = value.object.keys.array.sort.array;
            return "{" ~ keys
                .map!(key => JSONValue(key).toString(JSONOptions.doNotEscapeSlashes)
                    ~ ":" ~ canonicalJson(value.object[key]))
                .join(",") ~ "}";
        case JSONType.array:
            return "[" ~ value.array.map!(item => canonicalJson(item)).array.join(",") ~ "]";
        case JSONType.string:
        case JSONType.integer:
        case JSONType.uinteger:
        case JSONType.float_:
        case JSONType.true_:
        case JSONType.false_:
        case JSONType.null_:
            return value.toString(JSONOptions.doNotEscapeSlashes);
    }
}

JSONValue manifestWithClearedSignature(JSONValue manifest)
{
    auto unsigned = manifest.toString(JSONOptions.doNotEscapeSlashes).parseJSON;
    JSONValue[string] signature = [
        "algorithm": JSONValue(signatureAlgorithm(manifest)),
        "keyId": JSONValue(signatureKeyId(manifest)),
        "signature": JSONValue(""),
    ];
    unsigned.object["manifestSignature"] = JSONValue(signature);
    return unsigned;
}

string canonicalManifestPayload(JSONValue manifest)
{
    return canonicalJson(manifestWithClearedSignature(manifest));
}

string signatureAlgorithm(JSONValue manifest)
{
    if (manifest.type == JSONType.object)
        if (auto sig = "manifestSignature" in manifest.object)
            if (sig.type == JSONType.object)
                if (auto algorithm = "algorithm" in sig.object)
                    return algorithm.str;
    return manifestSignatureAlgorithm;
}

string signatureKeyId(JSONValue manifest)
{
    if (manifest.type == JSONType.object)
        if (auto sig = "manifestSignature" in manifest.object)
            if (sig.type == JSONType.object)
                if (auto keyId = "keyId" in sig.object)
                    return keyId.str;
    return "";
}

string manifestSignature(JSONValue manifest)
{
    if (manifest.type == JSONType.object)
        if (auto sig = "manifestSignature" in manifest.object)
            if (sig.type == JSONType.object)
                if (auto signature = "signature" in sig.object)
                    return signature.str;
    return "";
}

string manifestTarget(JSONValue manifest) => manifest["target"]["name"].str;
string manifestSystem(JSONValue manifest) => manifest["target"]["system"].str;
string manifestDeploymentId(JSONValue manifest) => manifest["deploymentId"].str;
string manifestDesiredSystemPath(JSONValue manifest) => manifest["desiredSystemPath"].str;
ulong manifestSequence(JSONValue manifest) => manifest["sequence"].integer.to!ulong;

JSONValue buildManifest(ManifestBuildRequest request)
{
    auto closure = request.closure.isNull
        ? ClosureSummary(
            count: 1,
            totalBytes: Nullable!ulong(0),
            rootHashes: [storePathHash(request.desiredSystemPath)],
        )
        : request.closure.get;

    JSONValue[string] closureJson = [
        "count": JSONValue(cast(long) closure.count),
        "totalBytes": closure.totalBytes.isNull
            ? JSONValue(0)
            : JSONValue(cast(long) closure.totalBytes.get),
        "rootHashes": JSONValue(closure.rootHashes.map!(hash => JSONValue(hash)).array),
    ];

    JSONValue[] substituters = request.substituters
        .map!(substituter => JSONValue([
            "url": JSONValue(substituter.url),
            "trustedPublicKey": JSONValue(substituter.trustedPublicKey),
        ]))
        .array;

    JSONValue[] healthChecks = request.healthChecks
        .map!(check => JSONValue([
            "name": JSONValue(check.name),
            "kind": JSONValue(check.kind),
            "target": JSONValue(check.target),
            "timeoutSeconds": JSONValue(cast(long) check.timeoutSeconds),
        ]))
        .array;

    JSONValue[string] manifest = [
        "schemaVersion": JSONValue(1),
        "deploymentId": JSONValue(request.deploymentId),
        "target": JSONValue([
            "name": JSONValue(request.target),
            "system": JSONValue(request.system),
        ]),
        "gitRevision": JSONValue(request.gitRevision),
        "sequence": JSONValue(cast(long) request.sequence),
        "manifestSignature": JSONValue([
            "algorithm": JSONValue(manifestSignatureAlgorithm),
            "keyId": JSONValue(""),
            "signature": JSONValue(""),
        ]),
        "desiredSystemPath": JSONValue(request.desiredSystemPath),
        "cacheRequirements": JSONValue([
            "closure": JSONValue(closureJson),
            "substituters": JSONValue(substituters),
            "availability": JSONValue([
                "mode": JSONValue(request.availabilityMode),
                "requiredBeforeActivation": JSONValue(request.requiredBeforeActivation),
            ]),
        ]),
        "healthChecks": JSONValue(healthChecks),
        "rollbackPolicy": JSONValue([
            "mode": JSONValue(request.rollbackMode),
            "maxAttempts": JSONValue(cast(long) request.rollbackMaxAttempts),
            "onHealthCheckFailure": JSONValue(request.onHealthCheckFailure),
        ]),
        "currentState": JSONValue(request.currentState),
        "supersededState": request.supersededState,
        "retryTimestamps": JSONValue(JSONValue[].init),
    ];

    return JSONValue(manifest);
}

JSONValue signManifest(
    JSONValue manifest,
    ManifestSigningRequest request,
    ProcessRunner runProcess = null,
)
{
    import std.exception : enforce;

    ProcessResult defaultRunner(string[] args) { return runProcessCapture(args); }
    auto runner = runProcess is null ? &defaultRunner : runProcess;
    enforce(request.keyPath != "", "A manifest signing key is required.");
    enforce(request.keyPath.exists, "Manifest signing key does not exist: " ~ request.keyPath);

    auto keyId = request.keyId == "" ? request.keyPath.baseName : request.keyId;
    auto unsigned = manifestWithClearedSignature(manifest);
    unsigned.object["manifestSignature"] = JSONValue([
        "algorithm": JSONValue(manifestSignatureAlgorithm),
        "keyId": JSONValue(keyId),
        "signature": JSONValue(""),
    ]);

    auto payload = canonicalJson(unsigned);
    auto temp = tempDir.buildPath("mcl-manifest-sign-" ~ randomUUID.toString);
    temp.mkdir;
    auto payloadPath = temp.buildPath("payload.json");
    auto sigPath = payloadPath ~ ".sig";
    scope(exit) if (temp.exists) temp.rmdirRecurse;

    payloadPath.write(payload);
    auto result = runner([
        "ssh-keygen", "-Y", "sign",
        "-f", request.keyPath,
        "-n", manifestSignatureNamespace,
        payloadPath,
    ]);
    enforce(result.succeeded, "Manifest signing failed: " ~ result.stderr.strip);

    auto signed = manifest.toString(JSONOptions.doNotEscapeSlashes).parseJSON;
    signed.object["manifestSignature"] = JSONValue([
        "algorithm": JSONValue(manifestSignatureAlgorithm),
        "keyId": JSONValue(keyId),
        "signature": JSONValue(sigPath.readText),
    ]);
    return signed;
}

bool verifyManifestSignature(
    JSONValue manifest,
    string trustedPublicKey,
    string allowedSignersPath,
    ProcessInputRunner runProcessWithInput = null,
)
{
    import std.exception : enforce;

    ProcessResult defaultRunner(string[] args, string input)
    {
        return runProcessWithInputCapture(args, input);
    }
    auto runner = runProcessWithInput is null
        ? &defaultRunner
        : runProcessWithInput;

    enforce(signatureAlgorithm(manifest) == manifestSignatureAlgorithm,
        "Unsupported manifest signature algorithm: " ~ signatureAlgorithm(manifest));
    enforce(signatureKeyId(manifest) != "", "Manifest signature keyId is missing.");
    enforce(manifestSignature(manifest) != "", "Manifest signature is missing.");
    enforce(trustedPublicKey != "" || allowedSignersPath != "",
        "A trusted manifest public key or allowed signers file is required.");

    auto temp = tempDir.buildPath("mcl-manifest-verify-" ~ randomUUID.toString);
    temp.mkdir;
    auto sigPath = temp.buildPath("signature.sig");
    auto allowedPath = allowedSignersPath == "" ? temp.buildPath("allowed-signers") : allowedSignersPath;
    scope(exit)
    {
        if (temp.exists) temp.rmdirRecurse;
    }

    sigPath.write(manifestSignature(manifest));
    if (allowedSignersPath == "")
        allowedPath.write(signatureKeyId(manifest) ~ " " ~ trustedPublicKey.strip ~ "\n");

    auto result = runner([
        "ssh-keygen", "-Y", "verify",
        "-f", allowedPath,
        "-I", signatureKeyId(manifest),
        "-n", manifestSignatureNamespace,
        "-s", sigPath,
    ], canonicalManifestPayload(manifest));

    return result.succeeded;
}

ManifestHealthCheck parseHealthCommand(string spec)
{
    auto parts = spec.split("|");
    if (parts.length != 3)
        throw new Exception("Health command must use NAME|TIMEOUT_SECONDS|COMMAND.");
    return ManifestHealthCheck(
        name: parts[0],
        kind: "command",
        target: parts[2],
        timeoutSeconds: parts[1].to!ulong,
    );
}

@("test_canonical_manifest_payload_clears_only_signature")
unittest
{
    auto manifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-1",
        target: "target-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system",
    ));
    manifest.object["manifestSignature"] = JSONValue([
        "algorithm": JSONValue(manifestSignatureAlgorithm),
        "keyId": JSONValue("key"),
        "signature": JSONValue("not-signed"),
    ]);

    auto payload = canonicalManifestPayload(manifest);
    assert(payload.canFind(`"keyId":"key"`));
    assert(payload.canFind(`"signature":""`));
    assert(!payload.canFind("not-signed"));
}

@("test_manifest_signature_verification_uses_canonical_payload")
unittest
{
    auto manifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-1",
        target: "target-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system",
    ));
    auto signed = manifest;
    signed.object["manifestSignature"] = JSONValue([
        "algorithm": JSONValue(manifestSignatureAlgorithm),
        "keyId": JSONValue("test-key"),
        "signature": JSONValue("signed-payload"),
    ]);

    bool verified;
    ProcessResult fakeVerify(string[] command, string input)
    {
        verified = command[0] == "ssh-keygen"
            && command.canFind("-Y")
            && command.canFind("verify")
            && input == canonicalManifestPayload(signed);
        return ProcessResult(verified ? 0 : 1, "", "");
    }

    assert(signed.verifyManifestSignature("ssh-ed25519 AAAATEST test", "", &fakeVerify));
    assert(verified);
}

@("test_manifest_signature_rejects_tampered_payload")
unittest
{
    auto base = deleteme ~ ".manifest-signature-tamper";
    auto keyPath = base ~ ".ed25519";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub"])
            if (path.exists) path.remove;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);

    auto manifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-1",
        target: "target-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system",
    ));
    auto signed = signManifest(manifest, ManifestSigningRequest(
        keyPath: keyPath,
        keyId: "deploy-test",
    ));
    auto publicKey = (keyPath ~ ".pub").readText.strip;
    assert(signed.verifyManifestSignature(publicKey, ""));

    auto tamperedPath = signed.toString(JSONOptions.doNotEscapeSlashes).parseJSON;
    tamperedPath.object["desiredSystemPath"] =
        JSONValue("/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system");
    assert(!tamperedPath.verifyManifestSignature(publicKey, ""));

    auto tamperedTarget = signed.toString(JSONOptions.doNotEscapeSlashes).parseJSON;
    auto target = tamperedTarget.object["target"];
    target.object["name"] = JSONValue("target-2");
    tamperedTarget.object["target"] = target;
    assert(!tamperedTarget.verifyManifestSignature(publicKey, ""));

    auto tamperedKeyId = signed.toString(JSONOptions.doNotEscapeSlashes).parseJSON;
    auto signature = tamperedKeyId.object["manifestSignature"];
    signature.object["keyId"] = JSONValue("other-principal");
    tamperedKeyId.object["manifestSignature"] = signature;
    assert(!tamperedKeyId.verifyManifestSignature(publicKey, ""));
}
