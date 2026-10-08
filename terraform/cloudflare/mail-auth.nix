# DKIM TXT records for Cloudflare zones, from a JSON data file the consumer
# keeps in its own repository (docs/Google-Workspace-DKIM.md).
#
# Usage, from a Terranix root:
#
#   let
#     devops-modules = builtins.fetchGit { url = "…/devops-modules"; rev = "…"; };
#     mailAuth = import "${devops-modules}/terraform/cloudflare/mail-auth.nix" {
#       data = builtins.fromJSON (builtins.readFile ./mail-auth.json);
#       comment = "Google Workspace DKIM (docs/runbooks/…)";   # optional
#     };
#   in
#   { imports = [ mailAuth ]; … }          # or recursiveUpdate it into the root
#
# THE DATA CONTRACT (mail-auth.json). The same file is edited by the
# `google-workspace-dkim publish` tool, so it stays plain JSON:
#
#   {
#     "version": 1,
#     "domains": {
#       "example.com": {
#         "zone_id": "<32 hex: the Cloudflare zone holding the domain>",
#         "dkim": { "google": "v=DKIM1; k=rsa; p=MIIBIjANBg…" }
#       }
#     }
#   }
#
# A domain is declared (with its zone id) by a person, once; the tool only ever
# adds or replaces a `dkim.<selector>` value under a declared domain. A value is
# the TXT content exactly as the provider's console shows it, as ONE unquoted
# string: Cloudflare splits a value longer than 255 characters into DNS
# character-strings on the wire, so nothing here pre-splits it.
#
# WHAT IT RENDERS. One `resource.cloudflare_dns_record.<resourceName>` with a
# `for_each` keyed `"<selector>._domainkey.<domain>|TXT"` — the key shape of the
# adopted-records maps the shared import tooling uses, and STABLE: adding a
# domain or a selector adds one key and never re-keys an existing record, so a
# rotation (a second, dated selector next to the first) is a pure create.
# Records are TXT, unproxied, ttl 1 (automatic), with `comment`. Written for the
# provider v5 `cloudflare_dns_record` (zone_id, name, type, content, ttl,
# proxied, comment). With no DKIM values at all it renders NOTHING (not an empty
# for_each), so declaring domains ahead of their keys leaves a plan unchanged.
#
# VALIDATION. The evaluation throws on: an unknown `version`; a zone id that is
# not 32 lowercase hex; a domain or selector that is not a lowercase DNS name /
# label; a value that does not start with `v=DKIM1;` or that holds a character
# outside the DKIM tag alphabet (letters, digits, `=;+/ ._-`). The last rule is
# also what makes the inline `for_each` safe: Terraform's JSON syntax reads a
# string as a template, and no permitted value can contain `${` or `%{`.
{
  data,
  resourceName ? "mail_auth_dkim",
  comment ? "DKIM public key (docs/Google-Workspace-DKIM.md)",
}:
let
  inherit (builtins)
    attrNames
    concatMap
    listToAttrs
    match
    throw
    ;

  domains = data.domains or { };

  check =
    cond: msg: v:
    if cond then v else throw "mail-auth.nix: ${msg}";

  isZoneId = z: builtins.isString z && match "[0-9a-f]{32}" z != null;
  isDomain = d: match "([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,63}" d != null;
  isSelector = s: match "[a-z0-9]([a-z0-9._-]*[a-z0-9])?" s != null;
  isDkimValue = v: builtins.isString v && match "v=DKIM1;[A-Za-z0-9=;+/ ._-]*" v != null;

  recordsFor =
    domain:
    let
      d = domains.${domain};
      dkim = d.dkim or { };
      zoneId = check (isZoneId (
        d.zone_id or null
      )) "domain ${domain}: zone_id must be the 32-hex Cloudflare zone id" d.zone_id;
    in
    check (isDomain domain) "\"${domain}\" is not a lowercase domain name" (
      map (
        selector:
        let
          name = "${selector}._domainkey.${domain}";
          value = dkim.${selector};
        in
        check (isSelector selector) "domain ${domain}: \"${selector}\" is not a valid selector" (
          check (isDkimValue value)
            "${name}: the value must be one unquoted string starting with \"v=DKIM1;\" (letters, digits and =;+/ ._- only)"
            {
              name = "${name}|TXT";
              value = {
                zone_id = zoneId;
                inherit name;
                content = value;
              };
            }
        )
      ) (attrNames dkim)
    );

  records = listToAttrs (concatMap recordsFor (attrNames domains));
in
check ((data.version or null) == 1) "data.version must be 1" (
  if records == { } then
    { }
  else
    {
      resource.cloudflare_dns_record.${resourceName} = {
        for_each = records;
        zone_id = "\${each.value.zone_id}";
        name = "\${each.value.name}";
        type = "TXT";
        content = "\${each.value.content}";
        proxied = false;
        ttl = 1;
        inherit comment;
      };
    }
)
