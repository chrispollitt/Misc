# Router::Actiontec::T3200M

Perl module for the home router `cmrouter`, an Actiontec T3200M (firmware 31.164L.22, the Telus box).
It replaces the old `Router/Actiontec.pm`, which targeted an older Actiontec at 192.168.1.254 and had its
login switched off.

Core Perl plus LWP only (`Math::BigInt`, `MIME::Base64`, `LWP::UserAgent`, `HTTP::Cookies`). No CPAN extras.

## What it does

| Call | Needs login | What |
|---|---|---|
| `hosts`, `clients` | no | LAN clients the router knows (`name ip mac medium addressing active`); `clients` gives the `[ip, mac, name]` rows `GetHosts.pm` wants |
| `wan`, `internet_up` | no | WAN link / ISP status, address, gateway, DNS |
| `device` | no | model, firmware, uptime |
| `login`, `logout` | | the router's RSA-encrypted login (`login.cgi`) |
| `reboot(confirm => 1)` | yes | same request as the router's Reboot button; **not yet run against the live box** |
| `wait_until_up` | no | poll until the router answers again |

The T3200M embeds its status as JavaScript variables in the home page (`/`), and serves that page without a
login, so the read-only calls need no password. The login matters for the admin pages and for `reboot`.
The password is RSA-encrypted (PKCS#1 v1.5, e = 0x10001) with the key in the login page and posted base64-encoded.

## Credentials

Never in a file or on a command line. `new_from_vault` runs `auth get https cmrouter --with-login`
(output: LOGIN, a tab, the secret) through a pipe. To add the record (hidden prompt):

```bash
auth set https@cmrouter LOGIN
```

## Use

```perl
use Router::Actiontec::T3200M;
my $r = Router::Actiontec::T3200M->new(host => 'cmrouter');   # status only, no login
print $r->internet_up ? "up\n" : "DOWN\n";
printf "%s %s\n", @$_[0,2] for $r->clients;

my $a = Router::Actiontec::T3200M->new_from_vault(host => 'cmrouter')->login;
```

Command line (read-only; add `--login` to use the vault login):

```bash
perl bin/cmrouter status      # exit status 1 when the internet is down
perl bin/cmrouter hosts
perl bin/cmrouter --login wan
```

Documentation: `perldoc lib/Router/Actiontec/T3200M.pm`.

## Tests

```bash
prove -l t        # about 20 s: the fake router decrypts with a pure-Perl RSA
```

They run with no router and no vault: `t/lib/FakeRouter.pm` plays the router (login with real RSA decryption,
sessions, lockout, reboot) using `t/data/home.tmpl`, a trimmed copy of the real home page with invented
hosts and addresses. `t/data/testkey.*` is a throwaway 1024-bit key made for the tests.

## Known limits

* `reboot` follows what the router's own page does (`GET rebootinfo.html` once logged in). Nobody has rebooted
  the live router with it yet.
* `advancedsetup_dhcpsettings.html` answers 403 even when logged in; DHCP lease times are not available.
  `hostinfo` (names, addresses, MACs, connected flag) is what the router offers.
* The router lists only clients it has seen on DHCP or ARP; a bridged VM shows under its host's name.
  `GetHosts.pm` keeps its old workaround for that.

## Callers

* `~/user_perl/GetHosts.pm` (used by `~/bin/get_hosts.pl`): ported, no longer uses `Foo_Bar` for the router.
* `~/bin/isinternetup.pl`, `~/bin/landata.pl`: still written for the Zyxel router and were not ported; they need a
  rewrite on `internet_up` / `wan`.
