# jq functions over a mail-auth data file (terraform/cloudflare/mail-auth.nix
# documents the contract). They restate, for the tools, what the Terranix
# helper renders: the resource addresses and the record contents. The check
# `cloudflare-mail-auth` compares the addresses with the helper's rendering of
# the test fixtures, so the two cannot drift silently.
#
#   jq -L <this dir> 'include "mail-auth"; …'

# The domain's resource-name suffix: "" or "_<zone_lookup>".
def mail_auth_suffix($d): (.domains[$d].zone_lookup // null) as $l | if $l then "_" + $l else "" end;

def mail_auth_mailto_domain: sub("^mailto:[^@]*@"; "") | sub("!.*$"; "");

# The report domains of $d's DMARC record that need an authorisation record:
# declared in this file, and neither $d nor under it.
def mail_auth_report_domains($d):
  . as $f
  | [ ((.domains[$d].dmarc // {}) | (.rua // []) + (.ruf // []))[]
      | mail_auth_mailto_domain
      | select(. != $d and (endswith("." + $d) | not) and ($f.domains[.] != null)) ]
  | unique;

# Every resource address the helper renders, one per output.
def mail_auth_addresses($dkim; $rec):
  . as $f
  | .domains | keys[] as $d
  | $f.domains[$d] as $v
  | ($f | mail_auth_suffix($d)) as $s
  | "cloudflare_dns_record." + (
        ( ($v.dkim // {}) | keys[] | "\($dkim)\($s)[\"\(.)._domainkey.\($d)|TXT\"]" ),
        ( ($v.google_verification // [])[] | "\($rec)\($s)[\"\($d)|TXT|\(.)\"]" ),
        ( ($v.mx // []) | keys[] | "\($rec)\($s)[\"\($d)|MX|\(. + 1)\"]" ),
        ( if $v.spf then "\($rec)\($s)[\"\($d)|TXT|spf\"]" else empty end ),
        ( if $v.dmarc then "\($rec)\($s)[\"_dmarc.\($d)|TXT\"]" else empty end ),
        ( $f | mail_auth_report_domains($d)[] as $r
          | "\($rec)\($f | mail_auth_suffix($r))[\"\($d)._report._dmarc.\($r)|TXT\"]" )
      );
def mail_auth_addresses: mail_auth_addresses("mail_auth_dkim"; "mail_auth");

# Record contents as DNS serves them (one string, no quotes), or null when the
# data declares none.
def mail_auth_spf($d):
  .domains[$d].spf as $s
  | if $s == null then null
    else (["v=spf1"] + [($s.include // [])[] | "include:" + .] + [$s.all // "~all"]) | join(" ")
    end;

def mail_auth_dmarc($d):
  .domains[$d].dmarc as $m
  | if $m == null then null
    else (["v=DMARC1"]
          + [ ("p", "sp", "pct", "rua", "ruf", "fo", "adkim", "aspf") as $t
              | select($m[$t] != null)
              | "\($t)=" + (if ($m[$t] | type) == "array" then $m[$t] | join(",") else $m[$t] | tostring end) ])
         | join("; ")
    end;

# "<priority> <host>" lines, sorted by codepoint — the form lookup_mx prints
# (it sorts with LC_ALL=C; callers comparing the two should sort both alike).
def mail_auth_mx($d): [(.domains[$d].mx // [])[] | "\(.priority) \(.host)"] | sort | .[];
