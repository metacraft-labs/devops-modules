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

    "an unknown version is refused" = throws (render (one { google = value; } // { version = 2; }));
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
  };
in
builtins.filter (name: !cases.${name}) (builtins.attrNames cases)
