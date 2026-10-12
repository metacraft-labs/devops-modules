# Unit test for ../mail-auth.nix. Pure evaluation: no credentials, no network,
# no provider. Returns the list of failed assertions; `checks/cloudflare-mail-auth.nix`
# fails the build when it is non-empty, and separately compares the rendering
# of ./mail-auth/data.json with the reviewed ./mail-auth/expected.json.
#
#   nix build .#checks.x86_64-linux.cloudflare-mail-auth
let
  mailAuth = import ../mail-auth.nix;
  fixture = builtins.fromJSON (builtins.readFile ./mail-auth/data.json);
  render = data: mailAuth { inherit data; };
  records = data: (render data).resource.cloudflare_dns_record.mail_auth_dkim.for_each;

  zoneA = "0123456789abcdef0123456789abcdef";
  value = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAx+/=";
  one = dkim: {
    version = 1;
    domains."example.com" = {
      zone_id = zoneA;
      inherit dkim;
    };
  };

  throws = x: !(builtins.tryEval (builtins.deepSeq x x)).success;

  # Version 2: the other mail records.
  fixture2 = builtins.fromJSON (builtins.readFile ./mail-auth/data-v2.json);
  mail = data: (render data).resource.cloudflare_dns_record.mail_auth.for_each;
  two = d: {
    version = 2;
    domains."example.com" = {
      zone_id = zoneA;
    }
    // d;
  };
  google = {
    mx = [
      {
        priority = 1;
        host = "smtp.google.com";
      }
    ];
    spf.include = [ "_spf.google.com" ];
    dmarc.p = "none";
  };

  withDomain = fixture // {
    domains = fixture.domains // {
      "example.io" = {
        zone_id = "11111111111111111111111111111111";
        dkim.google = value;
      };
    };
  };

  cases = {
    # Key stability: adding a domain only ADDS a key; every existing key keeps
    # its exact value, so no existing record is re-keyed or replaced.
    "adding a domain does not re-key or change existing records" =
      let
        before = records fixture;
        after = records withDomain;
      in
      # attrNames is sorted, so compare against the sorted expected key set.
      builtins.attrNames after == builtins.sort builtins.lessThan (
        builtins.attrNames before ++ [ "google._domainkey.example.io|TXT" ]
      )
      && builtins.all (k: after.${k} == before.${k}) (builtins.attrNames before);

    "a declared domain with no keys renders nothing" = render (one { }) == { };
    "no domains at all renders nothing" = render { version = 1; } == { };

    "the record is a TXT at <selector>._domainkey.<domain>, unproxied, ttl auto" =
      let
        r =
          (render (one {
            google = value;
          })).resource.cloudflare_dns_record.mail_auth_dkim;
      in
      r.type == "TXT"
      && r.proxied == false
      && r.ttl == 1
      &&
        r.for_each == {
          "google._domainkey.example.com|TXT" = {
            zone_id = zoneA;
            name = "google._domainkey.example.com";
            content = value;
          };
        };

    "resourceName and comment are the caller's" =
      let
        r = mailAuth {
          data = one { google = value; };
          resourceName = "dkim";
          comment = "see runbook";
        };
      in
      r.resource.cloudflare_dns_record.dkim.comment == "see runbook";

    "an unknown version is refused" = throws (render (one { google = value; } // { version = 3; }));
    "a short zone id is refused" = throws (render {
      version = 1;
      domains."example.com" = {
        zone_id = "0123";
        dkim.google = value;
      };
    });
    "an upper-case domain is refused" = throws (render {
      version = 1;
      domains."Example.com" = {
        zone_id = zoneA;
        dkim.google = value;
      };
    });
    "a selector with a space is refused" = throws (
      render (one {
        "goo gle" = value;
      })
    );
    "a value without v=DKIM1 is refused" = throws (
      render (one {
        google = "k=rsa; p=AAAA";
      })
    );
    "a quoted value is refused" = throws (
      render (one {
        google = "\"${value}\"";
      })
    );
    "a template sequence is refused" = throws (
      render (one {
        google = "v=DKIM1; p=\${x}";
      })
    );

    # ── version 2 ────────────────────────────────────────────────────────────
    "a version-1 file is refused a version-2 field" = throws (render {
      version = 1;
      domains."example.com" = {
        zone_id = zoneA;
        inherit (google) mx;
      };
    });
    "an unknown domain field is refused" = throws (
      render (two {
        mxx = [ ];
      })
    );
    "a version-2 file with only DKIM renders exactly the version-1 resource" =
      render (fixture // { version = 2; }) == render fixture;

    "MX is keyed by position, so a changed host keeps its key (an in-place update)" =
      let
        before = mail (two google);
        after = mail (
          two (
            google
            // {
              mx = [
                {
                  priority = 10;
                  host = "mail.example.com";
                }
              ];
            }
          )
        );
      in
      builtins.attrNames before == builtins.attrNames after
      && after."example.com|MX|1".content == "mail.example.com"
      && after."example.com|MX|1".priority == 10;

    "adding verification, MX, SPF and DMARC does not re-key the DKIM records" =
      let
        withMail = fixture2 // {
          domains = fixture2.domains // {
            "example.io" = {
              zone_id = "11111111111111111111111111111111";
            }
            // google;
          };
        };
        r = data: (render data).resource.cloudflare_dns_record;
        before = r fixture2;
        after = r withMail;
      in
      before.mail_auth_dkim == after.mail_auth_dkim
      && builtins.all (k: after.mail_auth.for_each.${k} == before.mail_auth.for_each.${k}) (
        builtins.attrNames before.mail_auth.for_each
      )
      &&
        builtins.attrNames after.mail_auth.for_each == builtins.sort builtins.lessThan (
          builtins.attrNames before.mail_auth.for_each
          ++ [
            "_dmarc.example.io|TXT"
            "example.io|MX|1"
            "example.io|TXT|spf"
          ]
        );

    # terranix drops null attributes, so a TXT entry reaches Terraform with no
    # `priority` at all; a bare each.value.priority then fails the plan
    # ("Unsupported attribute"), as the first consumer plan showed.
    "priority is read through try(), so null-dropping renderers still plan" =
      (render (two google)).resource.cloudflare_dns_record.mail_auth.priority
      == "\${try(each.value.priority, null)}";

    "SPF is one quoted TXT, ~all by default" =
      (mail (two google))."example.com|TXT|spf".content == "\"v=spf1 include:_spf.google.com ~all\"";
    "DMARC tags render in RFC order, quoted" =
      (mail (two {
        dmarc = {
          aspf = "s";
          p = "reject";
          adkim = "s";
          pct = 100;
        };
      }))."_dmarc.example.com|TXT".content == "\"v=DMARC1; p=reject; pct=100; adkim=s; aspf=s\"";
    "a verification token is keyed by its value" =
      (mail (two {
        google_verification = [ "google-site-verification=abcdefgh123" ];
      }))
        ? "example.com|TXT|google-site-verification=abcdefgh123";
    "an external DMARC report domain that is declared gets its authorisation record" =
      (mail fixture2)."example.net._report._dmarc.example.com|TXT".content == "\"v=DMARC1\"";
    "a report domain that is the domain itself needs no authorisation record" =
      !(builtins.any (
        k:
        builtins.match ".*_report.*example[.]net.*" k != null
        && builtins.match "example[.]net[.]_report.*" k == null
      ) (builtins.attrNames (mail fixture2)));
    # Its zone is not this file's to write: the record is the consumer's job.
    "an external DMARC report domain that is NOT declared renders no authorisation record" =
      builtins.attrNames (
        mail (two {
          dmarc = {
            p = "none";
            rua = [ "mailto:dmarc@reports.example.net" ];
          };
        })
      ) == [ "_dmarc.example.com|TXT" ];

    "a lookup zone gets its own resources, with the data-source reference" =
      let
        r = (render fixture2).resource.cloudflare_dns_record;
      in
      r.mail_auth_example_org.zone_id == "\${data.cloudflare_zone.example_org.id}"
      && r.mail_auth_dkim_example_org.zone_id == "\${data.cloudflare_zone.example_org.id}"
      && !(r.mail_auth.for_each ? "example.org|MX|1")
      && !(r.mail_auth_dkim.for_each ? "google._domainkey.example.org|TXT");

    "both zone_id and zone_lookup is refused" = throws (
      render (two {
        zone_lookup = "x";
      })
    );
    "neither zone_id nor zone_lookup is refused" = throws (render {
      version = 2;
      domains."example.com".mx = google.mx;
    });
    "a zone_lookup key with a dot is refused" = throws (render {
      version = 2;
      domains."example.com".zone_lookup = "a.b";
    });
    "an MX priority over 65535 is refused" = throws (
      render (two {
        mx = [
          {
            priority = 70000;
            host = "smtp.google.com";
          }
        ];
      })
    );
    "an MX host with a template sequence is refused" = throws (
      render (two {
        mx = [
          {
            priority = 1;
            host = "\${x}.example.com";
          }
        ];
      })
    );
    "an SPF all of +all is refused" = throws (
      render (two {
        spf = {
          include = [ "_spf.google.com" ];
          all = "+all";
        };
      })
    );
    "an SPF record over 255 characters is refused" = throws (
      render (two {
        spf.include = builtins.genList (i: "host${toString i}.spf.example.com") 20;
      })
    );
    "a DMARC policy outside none/quarantine/reject is refused" = throws (
      render (two {
        dmarc.p = "monitor";
      })
    );
    "a DMARC record without p is refused" = throws (
      render (two {
        dmarc.pct = 100;
      })
    );
    "a DMARC rua that is not a mailto URI is refused" = throws (
      render (two {
        dmarc = {
          p = "none";
          rua = [ "https://example.com/report" ];
        };
      })
    );
    "a verification value of another provider is refused" = throws (
      render (two {
        google_verification = [ "MS=ms12345678" ];
      })
    );
    "a quoted verification value is refused" = throws (
      render (two {
        google_verification = [ "\"google-site-verification=abcdefgh123\"" ];
      })
    );

    # ── TLS-RPT, MTA-STS, google kinds, pending zones ───────────────────────
    "TLS-RPT is one quoted TXT at _smtp._tls.<domain>" =
      (mail (two {
        tls_rpt.rua = [
          "mailto:tls@example.com"
          "https://r.example.com/tlsrpt"
        ];
      }))."_smtp._tls.example.com|TXT" == {
        zone_id = zoneA;
        name = "_smtp._tls.example.com";
        type = "TXT";
        content = "\"v=TLSRPTv1; rua=mailto:tls@example.com,https://r.example.com/tlsrpt\"";
        priority = null;
      };
    "a TLS-RPT URI that is http:// is refused" = throws (
      render (two {
        tls_rpt.rua = [ "http://r.example.com/" ];
      })
    );
    "an empty TLS-RPT rua is refused" = throws (
      render (two {
        tls_rpt.rua = [ ];
      })
    );
    "an MTA-STS block that is not enabled renders nothing" =
      render (two {
        mta_sts = {
          id = "1";
          mode = "testing";
        };
      }) == { };
    "an enabled MTA-STS renders only the _mta-sts TXT" =
      mail (two {
        mta_sts = {
          enabled = true;
          id = "20261011";
          mode = "enforce";
        };
      }) == {
        "_mta-sts.example.com|TXT" = {
          zone_id = zoneA;
          name = "_mta-sts.example.com";
          type = "TXT";
          content = "\"v=STSv1; id=20261011\"";
          priority = null;
        };
      };
    "an MTA-STS id with a dash is refused" = throws (
      render (two {
        mta_sts = {
          id = "2026-10";
          mode = "testing";
        };
      })
    );
    "an MTA-STS mode outside testing/enforce/none is refused, even when disabled" = throws (
      render (two {
        mta_sts = {
          id = "1";
          mode = "strict";
        };
      })
    );
    "the google field renders nothing" =
      render (two {
        google = {
          kind = "alias";
          parent = "example.net";
        };
      }) == { };
    "a google kind outside primary/secondary/alias is refused" = throws (
      render (two {
        google.kind = "subdomain";
      })
    );
    "an alias without a parent is refused" = throws (
      render (two {
        google.kind = "alias";
      })
    );
    "a secondary domain with a parent is refused" = throws (
      render (two {
        google = {
          kind = "secondary";
          parent = "example.net";
        };
      })
    );
    "an alias of itself is refused" = throws (
      render (two {
        google = {
          kind = "alias";
          parent = "example.com";
        };
      })
    );
    "a pending domain renders nothing, not even its report authorisation" =
      let
        r = (
          render {
            version = 2;
            domains = {
              "example.com" = {
                zone_id = zoneA;
              };
              "example.dev" = {
                zone_pending = true;
                dmarc = {
                  p = "none";
                  rua = [ "mailto:dmarc@example.com" ];
                };
                tls_rpt.rua = [ "mailto:dmarc@example.com" ];
                google.kind = "secondary";
              };
            };
          }
        );
      in
      r == { };
    "a domain reporting to a pending domain gets no authorisation record" =
      builtins.attrNames (mail {
        version = 2;
        domains = {
          "example.com" = {
            zone_id = zoneA;
            dmarc = {
              p = "none";
              rua = [ "mailto:dmarc@example.dev" ];
            };
          };
          "example.dev".zone_pending = true;
        };
      }) == [ "_dmarc.example.com|TXT" ];
    "a pending domain's records are still validated" = throws (render {
      version = 2;
      domains."example.dev" = {
        zone_pending = true;
        dmarc.p = "monitor";
      };
    });
    "zone_pending together with a zone_id is refused" = throws (
      render (two {
        zone_pending = true;
      })
    );
    "zone_pending in a version-1 file is refused" = throws (render {
      version = 1;
      domains."example.dev".zone_pending = true;
    });
    "adding DMARC and TLS-RPT to declared domains only adds keys" =
      let
        before = mail fixture2;
        withReports = fixture2 // {
          domains = fixture2.domains // {
            "example.io" = fixture2.domains."example.io" // {
              dmarc = {
                p = "none";
                rua = [ "mailto:dmarc@example.com" ];
              };
              tls_rpt.rua = [ "mailto:dmarc@example.com" ];
            };
          };
        };
        after = mail withReports;
      in
      builtins.all (k: after.${k} == before.${k}) (builtins.attrNames before)
      &&
        builtins.attrNames after == builtins.sort builtins.lessThan (
          builtins.attrNames before
          ++ [
            "_dmarc.example.io|TXT"
            "_smtp._tls.example.io|TXT"
            "example.io._report._dmarc.example.com|TXT"
          ]
        );
    "google_users with an upper-case address is refused" = throws (
      render (
        fixture2
        // {
          google_users."Jane@example.com".local_parts = [ "jane" ];
        }
      )
    );
    "google_users with an empty local_parts is refused" = throws (
      render (
        fixture2
        // {
          google_users."jane@example.com".local_parts = [ ];
        }
      )
    );
    "google_users in a version-1 file is refused" = throws (
      render (
        fixture
        // {
          google_users."jane@example.com".local_parts = [ "jane" ];
        }
      )
    );
    "an unknown top-level field is refused" = throws (render (fixture2 // { domain = { }; }));
    "google_users renders nothing" =
      render (
        fixture2
        // {
          google_users."jane@example.com".local_parts = [
            "jane"
            "jane.doe"
          ];
        }
      ) == render fixture2;
  };
in
builtins.filter (name: !cases.${name}) (builtins.attrNames cases)
