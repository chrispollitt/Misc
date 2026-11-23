# Router::DLink

Perl module for the D-Link router `vr180` (DIR-655 hardware A3, firmware 1.37, web server `Ubicom/1.1`).
It replaces the 2018 `~/user_perl/Router/DLink.pm` (same package name; `new`, `login`, `logout`, `get_wan_data`,
`get_lan_data`, `reboot` still work) and has the same shape as `Router::Actiontec::T3200M`
(`wan`, `hosts`, `clients`, `internet_up`, `device`, `reboot(confirm => 1)`, `wait_until_up`, `new_from_vault`),
so the three routers (cmrouter = Actiontec, vr180 = D-Link, cpbee = the Linux gateway) can share one small
`router` command later (status | hosts | reboot).

Core Perl plus LWP only (`Digest::MD5`, `LWP::UserAgent`).

## How the router works

* The login page carries a `salt`. The page's JavaScript sends
  `salt . md5_hex(salt . password, padded to 16 bytes, padded to 63 bytes, with \x01; then "U" for the
  `user` login or \x01 for `admin`)` as `/post_login.xml?hash=...&auth_code=&auth_id=...`.
  The answer is `<login>Basic/Internet.shtml</login>` (or `error`, `timeout`, `auth_error`).
* No cookie: the router ties the session to the client's address. Only one login at a time is useful.
* If "graphical authentication" (a picture code) is switched on in the router, scripts cannot log in; the module says so.
* Data pages (all need the login; otherwise the router answers every URL with a "redirected to the login page" stub):
  `wan_connection_status.xml`, `wan_lan_status.xml`, `dhcp_clients.xml`, `Status/Device_Info.shtml`.
* Reboot: the "Reboot Now" button does `GET /reboot.cgi?reset=false`. **Never fetch `/reboot.cgi` casually.**
* vr180 has nothing in its WAN port (it serves the LAN only), so `wan` shows placeholder addresses and
  `internet_up` is false; `state`/`link` say `Disconnected`.

## Credentials

Never in a file or on a command line. `new_from_vault` runs `auth get https vr180 --with-login`
(output: LOGIN, a tab, the secret) through a pipe. To add the record (hidden prompt):

```bash
auth set https@vr180 LOGIN        # LOGIN is the router user: admin (full) or user (read only)
identity add chris https@vr180.cmnet LOGIN --why "the D-Link router web login"
```

## Use

```perl
use Router::DLink;
my $r = Router::DLink->new_from_vault(host => 'vr180')->login;
printf "%-15s %-17s %s\n", @$_ for $r->clients;      # [ip, mac, name]
print $r->device->{firmware}, "\n";
$r->logout;
```

Command line:

```bash
perl bin/vr180 status        # exit 1 when the WAN is down (it is, on vr180: nothing in the WAN port)
perl bin/vr180 hosts
perl bin/vr180 wan
perl bin/vr180 reboot        # asks first; --yes skips the question
router_reboot                # ~/bin/router_reboot: the same reboot, asks first, -y to skip
```

Documentation: `perldoc lib/Router/DLink.pm`.

## Tests

```bash
prove -l t
```

They run with no router and no vault: `t/lib/FakeDLink.pm` plays the router (login hash check, session,
data pages, reboot). The login hash is checked against golden values made by running the router's own
`md5.js` and `send_login()` in node. `t/data/` holds the real login page and sanitized copies of the real XML
(invented addresses and hosts).

## Known limits

* `reboot` (`GET /reboot.cgi?reset=false`, the router's own button) was run live on 2026-11-22 via `router_reboot -y`:
  the router came back in about 40 s with an uptime of 33 s and the same DHCP table.
* `hosts` is the DHCP lease table (`dhcp_clients.xml`); wired/static clients that never asked for a lease are not in it.
