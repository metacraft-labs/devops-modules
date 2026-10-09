# A domain's mail DNS records for Cloudflare zones — DKIM keys, MX, SPF, DMARC
# and the Google site-verification token — from a JSON data file the consumer
# keeps in its own repository (docs/Google-Workspace-Domains.md,
# docs/Google-Workspace-DKIM.md).
#
# Usage, from a Terranix root:
#
#   let
#     devops-modules = builtins.fetchGit { url = "…/devops-modules"; rev = "…"; };
#     mailAuth = import "${devops-modules}/terraform/cloudflare/mail-auth.nix" {
#       data = builtins.fromJSON (builtins.readFile ./mail-auth.json);
#       comment = "Google Workspace DKIM (docs/runbooks/…)";   # optional
#       recordsComment = "Mail routing (docs/runbooks/…)";      # optional
#     };
#   in
#   { imports = [ mailAuth ]; … }          # or recursiveUpdate it into the root
#
# THE DATA CONTRACT (mail-auth.json). The same file is edited by the
# `google-workspace-dkim publish` and `google-workspace-domains onboard` tools,
# so it stays plain JSON:
#
#   {
#     "version": 2,
#     "domains": {
#       "example.com": {
#         "zone_id": "<32 hex: the Cloudflare zone holding the domain>",
#         "dkim": { "google": "v=DKIM1; k=rsa; p=MIIBIjANBg…" },
#         "google_verification": [ "google-site-verification=AbC…" ],
#         "mx": [ { "priority": 1, "host": "smtp.google.com" } ],
#         "spf": { "include": [ "_spf.google.com" ], "all": "~all" },
#         "dmarc": { "p": "none", "rua": [ "mailto:dmarc@example.com" ] }
#       },
#       "example.org": { "zone_lookup": "example_org", "dkim": {} }
#     }
#   }
#
# Every field but the zone is optional, and an absent field renders nothing.
# Version 1 files (zone_id and dkim only) are still accepted unchanged and
# render exactly as before; the other fields need "version": 2.
#
#   zone_id       the 32-hex Cloudflare zone id, OR
#   zone_lookup   the key of a `data "cloudflare_zone"` the CONSUMER declares
#                 (data.cloudflare_zone.<key>), for a zone whose id the root
#                 resolves at plan time instead of committing. Exactly one of
#                 the two.
#   dkim          { "<selector>": "v=DKIM1; …" } — one TXT per selector.
#   google_verification
#                 TXT values "google-site-verification=<token>" at the apex, as
#                 Google's Site Verification API hands them out (one per
#                 verifying user, so a list).
#   mx            [{priority, host}] in the order the records are keyed. Google
#                 Workspace's current single record is smtp.google.com,
#                 priority 1; the legacy aspmx.l.google.com set stays supported
#                 and is just a longer list.
#   spf           {include: [hosts], all: "~all" | "-all" | "?all"} — rendered
#                 as ONE "v=spf1 include:… ~all" TXT at the apex (an apex may
#                 hold only one SPF record).
#   dmarc         {p, sp?, pct?, rua?, ruf?, fo?, adkim?, aspf?} — rendered as
#                 the _dmarc TXT, tags in that order. rua/ruf are lists of
#                 "mailto:" URIs.
#
# WHAT IT RENDERS. Records are `cloudflare_dns_record` (provider v5), unproxied,
# ttl 1 (automatic), with a comment, in `for_each` resources keyed by a STABLE
# string so that adding a domain or a record adds keys and never re-keys an
# existing one:
#
#   resourceName (default mail_auth_dkim), TXT only — the version-1 resource:
#     "<selector>._domainkey.<domain>|TXT"
#   recordsResourceName (default mail_auth), every other record:
#     "<domain>|MX|<n>"                    n = 1-based position in `mx`
#     "<domain>|TXT|spf"
#     "<domain>|TXT|<google-site-verification=…>"
#     "_dmarc.<domain>|TXT"
#     "<domain>._report._dmarc.<report-domain>|TXT"   (see below)
#
# MX is keyed by POSITION, not by host, on purpose: replacing a mail host
# (moving a domain's mail to Google, or from the legacy set to smtp.google.com)
# then plans as an in-place update of the same record, so the zone is never
# without an MX between a destroy and a create — a window in which senders fall
# back to the apex A record. Verification tokens are keyed by VALUE: a token is
# its own identity, and a second verifying user adds a record.
#
# Records whose zone is a `zone_lookup` go into a resource of their own,
# "<resource>_<lookup key>" (mail_auth_<key>, mail_auth_dkim_<key>), with
# zone_id = "${data.cloudflare_zone.<key>.id}". A root that `-exclude`s the
# lookup from an offline plan then excludes only those records, not every
# domain's.
#
# EXTERNAL DMARC REPORT AUTHORISATION. When a domain's rua/ruf sends reports to
# a mailbox in ANOTHER domain (RFC 7489 §7.1), receivers only deliver them if
# the report domain publishes "<domain>._report._dmarc.<report-domain>" TXT
# "v=DMARC1". If the report domain is declared in the same data file, that
# record is rendered into its zone; otherwise publishing it is the consumer's
# job.
#
# TXT CONTENT. DKIM values stay one UNQUOTED string (a 2048-bit key exceeds one
# 255-byte DNS character-string and Cloudflare splits it on the wire). Every
# other TXT is rendered as one QUOTED character-string — the form Cloudflare
# recommends, and the form records created in its dashboard carry — so adopting
# an existing record does not rewrite its content.
#
# VALIDATION. The evaluation throws, naming the entry, on: an unknown `version`
# or domain field; a zone that is neither 32 lowercase hex nor a lookup key; a
# domain, selector, host or mailbox outside its DNS/address alphabet; a DKIM
# value not starting with `v=DKIM1;` or outside the DKIM tag alphabet; a
# verification value not of the form google-site-verification=<token>; an MX
# priority outside 0..65535; an SPF `all` other than ~all/-all/?all, or an SPF
# record longer than 255 characters; a DMARC tag with a value outside its RFC
# 7489 range. Those alphabets are also what make the inline `for_each` safe:
# Terraform's JSON syntax reads a string as a template, and no permitted value
# can contain `${` or `%{`.
{
  data,
  resourceName ? "mail_auth_dkim",
  comment ? "DKIM public key (docs/Google-Workspace-DKIM.md)",
  recordsResourceName ? "mail_auth",
  recordsComment ? "Mail DNS (docs/Google-Workspace-Domains.md)",
}:
let
  inherit (builtins)
    all
    any
    attrNames
    concatLists
    concatMap
    concatStringsSep
    elem
    filter
    genList
    groupBy
    head
    isInt
    isList
    isString
    length
    listToAttrs
    match
    stringLength
    throw
    ;

  version = data.version or null;
  domains = data.domains or { };

  check =
    cond: msg: v:
    if cond then v else throw "mail-auth.nix: ${msg}";

  isZoneId = z: isString z && match "[0-9a-f]{32}" z != null;
  isLookupKey = k: isString k && match "[a-z_][a-z0-9_]*" k != null;
  isDomain = d: isString d && match "([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,63}" d != null;
  # A host an SPF include or an MX names: a DNS name whose labels may start
  # with an underscore (_spf.google.com, _mailcust.gandi.net).
  isHost =
    h: isString h && match "(([a-z0-9_]|[a-z0-9_][a-z0-9_-]*[a-z0-9])[.])+[a-z]{2,63}" h != null;
  isSelector = s: match "[a-z0-9]([a-z0-9._-]*[a-z0-9])?" s != null;
  isDkimValue = v: isString v && match "v=DKIM1;[A-Za-z0-9=;+/ ._-]*" v != null;
  isVerification = v: isString v && match "google-site-verification=[A-Za-z0-9_-]{8,}" v != null;
  isMailto =
    m:
    isString m && match "mailto:[a-z0-9._+-]+@([a-z0-9-]+[.])+[a-z]{2,63}(![0-9]+[kmgt]?)?" m != null;
  mailtoDomain = m: head (match "mailto:[^@]+@([^!]+).*" m);

  v1Fields = [
    "zone_id"
    "dkim"
  ];
  v2Fields = v1Fields ++ [
    "zone_lookup"
    "google_verification"
    "mx"
    "spf"
    "dmarc"
  ];

  # Where a domain's records go: the resource-name suffix and the zone_id
  # expression. A literal zone keeps its id per record (inside for_each); a
  # lookup puts the reference on the resource itself.
  zoneOf =
    domain:
    let
      d = domains.${domain};
      hasId = d ? zone_id;
      hasLookup = d ? zone_lookup;
    in
    check (hasId != hasLookup) "domain ${domain}: declare exactly one of zone_id and zone_lookup" (
      if hasId then
        check (isZoneId d.zone_id) "domain ${domain}: zone_id must be the 32-hex Cloudflare zone id" {
          suffix = "";
          id = d.zone_id;
        }
      else
        check (version == 2) "domain ${domain}: zone_lookup needs \"version\": 2" (
          check (isLookupKey d.zone_lookup)
            "domain ${domain}: zone_lookup must be a data.cloudflare_zone key ([a-z_][a-z0-9_]*)"
            {
              suffix = "_${d.zone_lookup}";
              id = null;
              ref = "\${data.cloudflare_zone.${d.zone_lookup}.id}";
            }
        )
    );

  checkFields =
    domain:
    let
      allowed = if version == 2 then v2Fields else v1Fields;
      bad = filter (f: !(elem f allowed)) (attrNames domains.${domain});
    in
    check (bad == [ ])
      "domain ${domain}: unknown field(s) ${concatStringsSep ", " bad}${
        if version == 1 then " (fields beyond zone_id and dkim need \"version\": 2)" else ""
      }";

  quote = s: "\"${s}\"";

  # ── DKIM (the version-1 resource) ──────────────────────────────────────────
  dkimFor =
    domain:
    let
      d = domains.${domain};
      dkim = d.dkim or { };
      zone = zoneOf domain;
    in
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
            group = zone.suffix;
            inherit zone;
            key = "${name}|TXT";
            value = {
              inherit name;
              content = value;
            }
            // (if zone.id == null then { } else { zone_id = zone.id; });
          }
      )
    ) (attrNames dkim);

  # ── everything else (version 2) ────────────────────────────────────────────
  rec' = zone: key: name: type: content: priority: {
    group = zone.suffix;
    inherit zone key;
    value = {
      inherit
        name
        type
        content
        priority
        ;
    }
    // (if zone.id == null then { } else { zone_id = zone.id; });
  };

  verificationFor =
    domain:
    let
      vs = domains.${domain}.google_verification or [ ];
    in
    check (isList vs) "domain ${domain}: google_verification must be a list of TXT values" (
      map (
        v:
        check (isVerification v)
          "domain ${domain}: \"${toString v}\" is not a google-site-verification=<token> value"
          (rec' (zoneOf domain) "${domain}|TXT|${v}" domain "TXT" (quote v) null)
      ) vs
    );

  mxFor =
    domain:
    let
      mx = domains.${domain}.mx or [ ];
    in
    check (isList mx) "domain ${domain}: mx must be a list of {priority, host}" (
      genList (
        i:
        let
          m = builtins.elemAt mx i;
          p = m.priority or null;
          h = m.host or null;
          bad = filter (f: f != "priority" && f != "host") (attrNames m);
        in
        check (bad == [ ])
          "domain ${domain}: mx[${toString i}] has unknown field(s) ${concatStringsSep ", " bad}"
          (
            check (isInt p && p >= 0 && p <= 65535)
              "domain ${domain}: mx[${toString i}].priority must be an integer 0..65535"
              (
                check (isHost h) "domain ${domain}: mx[${toString i}].host is not a host name" (
                  rec' (zoneOf domain) "${domain}|MX|${toString (i + 1)}" domain "MX" h p
                )
              )
          )
      ) (length mx)
    );

  spfFor =
    domain:
    let
      d = domains.${domain};
      s = d.spf;
      includes = s.include or [ ];
      allQ = s.all or "~all";
      bad = filter (f: f != "include" && f != "all") (attrNames s);
      content = concatStringsSep " " ([ "v=spf1" ] ++ map (h: "include:${h}") includes ++ [ allQ ]);
    in
    if !(d ? spf) then
      [ ]
    else
      check (bad == [ ]) "domain ${domain}: spf has unknown field(s) ${concatStringsSep ", " bad}" (
        check (isList includes && all isHost includes)
          "domain ${domain}: spf.include must be a list of host names"
          (
            check
              (elem allQ [
                "~all"
                "-all"
                "?all"
              ])
              "domain ${domain}: spf.all must be one of ~all, -all, ?all"
              (
                check (stringLength content <= 255)
                  "domain ${domain}: the SPF record is ${toString (stringLength content)} characters, over one 255-character TXT string"
                  [ (rec' (zoneOf domain) "${domain}|TXT|spf" domain "TXT" (quote content) null) ]
              )
          )
      );

  dmarcTags = [
    "p"
    "sp"
    "pct"
    "rua"
    "ruf"
    "fo"
    "adkim"
    "aspf"
  ];
  policies = [
    "none"
    "quarantine"
    "reject"
  ];
  alignments = [
    "r"
    "s"
  ];

  dmarcOf = domain: domains.${domain}.dmarc;

  dmarcFor =
    domain:
    let
      d = domains.${domain};
      m = dmarcOf domain;
      bad = filter (f: !(elem f dmarcTags)) (attrNames m);
      uris = f: m.${f} or [ ];
      okUris = f: isList (uris f) && uris f != [ ] && all isMailto (uris f);
      tag =
        f:
        if !(m ? ${f}) then
          [ ]
        else if f == "rua" || f == "ruf" then
          check (okUris f) "domain ${domain}: dmarc.${f} must be a non-empty list of mailto: URIs" [
            "${f}=${concatStringsSep "," (uris f)}"
          ]
        else if f == "pct" then
          check (isInt m.pct && m.pct >= 0 && m.pct <= 100) "domain ${domain}: dmarc.pct must be 0..100" [
            "pct=${toString m.pct}"
          ]
        else if f == "p" || f == "sp" then
          check (elem m.${f} policies) "domain ${domain}: dmarc.${f} must be none, quarantine or reject" [
            "${f}=${m.${f}}"
          ]
        else if f == "adkim" || f == "aspf" then
          check (elem m.${f} alignments) "domain ${domain}: dmarc.${f} must be r or s" [ "${f}=${m.${f}}" ]
        else
          # fo: colon-separated options from 0 1 d s
          check (
            isString m.fo && match "[01ds](:[01ds])*" m.fo != null
          ) "domain ${domain}: dmarc.fo must be 0, 1, d or s, colon-separated" [ "fo=${m.fo}" ];
      content = concatStringsSep "; " ([ "v=DMARC1" ] ++ concatMap tag dmarcTags);
    in
    if !(d ? dmarc) then
      [ ]
    else
      check (bad == [ ]) "domain ${domain}: dmarc has unknown field(s) ${concatStringsSep ", " bad}" (
        check (m ? p) "domain ${domain}: dmarc.p is required" [
          (rec' (zoneOf domain) "_dmarc.${domain}|TXT" "_dmarc.${domain}" "TXT" (quote content) null)
        ]
      );

  # The report domains of a domain's DMARC that are neither the domain itself
  # nor under it, and that this data file declares.
  externalReportDomains =
    domain:
    let
      d = domains.${domain};
      m = dmarcOf domain;
      uris = (m.rua or [ ]) ++ (m.ruf or [ ]);
      rds = map mailtoDomain (filter isMailto uris);
      external =
        r: r != domain && match ".*[.]${builtins.replaceStrings [ "." ] [ "[.]" ] domain}" r == null;
    in
    if !(d ? dmarc) then
      [ ]
    else
      attrNames (
        listToAttrs (
          map (r: {
            name = r;
            value = null;
          }) (filter (r: external r && domains ? ${r}) rds)
        )
      );

  reportAuthFor =
    domain:
    map (
      r:
      let
        name = "${domain}._report._dmarc.${r}";
      in
      rec' (zoneOf r) "${name}|TXT" name "TXT" (quote "v=DMARC1") null
    ) (externalReportDomains domain);

  domainNames = map (
    domain:
    check (isDomain domain) "\"${domain}\" is not a lowercase domain name" (
      # The zone is validated even for a domain that declares no record yet.
      builtins.seq (builtins.deepSeq (zoneOf domain) null) (checkFields domain domain)
    )
  ) (attrNames domains);

  # The version-1 domains need nothing but this to stay byte-identical.
  dkimRecords = concatMap dkimFor domainNames;
  otherRecords =
    if version == 2 then
      concatLists (
        map (
          domain:
          verificationFor domain ++ mxFor domain ++ spfFor domain ++ dmarcFor domain ++ reportAuthFor domain
        ) domainNames
      )
    else
      [ ];

  # One resource per zone group: "" (literal zone ids) or "_<lookup key>".
  resources =
    base: commentText: extra: records:
    let
      groups = groupBy (r: r.group) records;
      keys = map (r: r.key) records;
      dupes = filter (k: length (filter (x: x == k) keys) > 1) keys;
    in
    check (dupes == [ ]) "duplicate record key(s): ${concatStringsSep ", " dupes}" (
      listToAttrs (
        map (
          g:
          let
            rs = groups.${g};
            zone = (head rs).zone;
          in
          {
            name = "${base}${g}";
            value = {
              for_each = listToAttrs (
                map (r: {
                  name = r.key;
                  inherit (r) value;
                }) rs
              );
              zone_id = if zone.id == null then zone.ref else "\${each.value.zone_id}";
              name = "\${each.value.name}";
              proxied = false;
              ttl = 1;
              comment = commentText;
            }
            // extra;
          }
        ) (attrNames groups)
      )
    );

  dkimResources = resources resourceName comment {
    type = "TXT";
    content = "\${each.value.content}";
  } dkimRecords;
  otherResources = resources recordsResourceName recordsComment {
    type = "\${each.value.type}";
    content = "\${each.value.content}";
    # try(): a renderer that drops null attributes (terranix does) leaves the
    # TXT entries without `priority` at all.
    priority = "\${try(each.value.priority, null)}";
  } otherRecords;

  all' = dkimResources // otherResources;
in
check
  (elem version [
    1
    2
  ])
  "data.version must be 1 or 2"
  (
    check (!(any (n: dkimResources ? ${n}) (attrNames otherResources)))
      "resourceName and recordsResourceName collide"
      (if all' == { } then { } else { resource.cloudflare_dns_record = all'; })
  )
