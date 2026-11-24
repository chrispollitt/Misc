# Router::Op and `router-op`

One way to ask any of the three home routers the same questions.

| Name | Router | Module |
|---|---|---|
| `cmrouter` | Actiontec T3200M (the Telus box) | [`Router::Actiontec::T3200M`](../Router-Actiontec-T3200M) |
| `vr180` | D-Link DIR-655 | [`Router::DLink`](../Router-DLink) |
| `cpbee` | the Debian gateway (dnsmasq + nftables) | [`Router::Cpbee`](../Router-Cpbee) |

The three modules stay as they are (each has its own CLI and tests). `Router::Op` sits on top of them: it picks the
module by name, puts **one shape** on what they return, says in **one table** what each router can do, and makes
a call a router cannot do fail the **same way** on all three.

## `router-op`

```
router-op [--yes] [--active] [--probe HOST:PORT] [--conf FILE] ROUTER|all COMMAND
router-op list | capabilities
```

| Command | What |
|---|---|
| `status` (default) | one line: internet UP/DOWN, WAN address, gateway, link, uptime. Exit 0 if up, 1 if not |
| `internet` | `UP` or `DOWN` only. With `all`, exit 0 if **any** router has the internet |
| `hosts` | name, IP, MAC, active, addressing (`--active`: only devices on the LAN now) |
| `wan`, `device` | every key of the one shape, sorted |
| `uptime` | `up 12d 22h 43m (1118602 s)` |
| `reboot` | asks `Reboot NAME (model)? [y/N]` unless `--yes`; needs **one named router**, never `all`; then waits for it to come back |
| `port-forwards`, `wifi`, `firewall` | not available yet: they say so, the same way on every router (see the table) |

```
$ router-op all status
cmrouter  internet UP  ip 209.121.12.33  gw 209.121.12.1  link Up  uptime 12d
vr180     internet DOWN  ip 192.168.5.5  gw 192.168.5.5  link Down  uptime 0d
cpbee     internet UP  ip 192.168.1.68  gw 192.168.1.254  link Up  uptime 12d
$ router-op cpbee internet --probe 1.1.1.1:443     # also one TCP connect from cpbee
$ router-op cmrouter reboot
```

A router that fails (not answering, no vault record, a locked vault) prints `NAME: ERROR: ...` and the others carry on;
the exit status is then 1. Logins come from the vault (`auth get https HOST --with-login`, read by the modules); the
vault must be unlocked for `cmrouter` (reboot only) and `vr180`. Nothing secret is ever put on a command line or in a file.

## The one shape

Every key is always there (an empty string, or `undef` for the two time stamps, when the router does not know it); the
router's own extra keys are kept too.

| | keys |
|---|---|
| host | `name ip mac medium addressing active reserved lease_expires` (`lease_expires`: epoch time or `undef`) |
| wan | `link` (`Up`/`Down`) `isp_status mac ip netmask gateway dns` (list) `lease_secs protocol addressing up_secs` |
| device | `model serial firmware hardware hostname uptime_secs` (whole seconds) |

Differences the layer hides: the D-Link only lists DHCP clients, so each counts as `active`; its link is
`Connected`/`Disconnected`, here `Up`/`Down`; the Actiontec reports uptime as `1045207.50`, here whole seconds.

## What each router can do

`yes` works, `no` the router cannot, `todo` it could and nobody has written it. Also `router-op capabilities`.

| call | cmrouter | vr180 | cpbee |
|---|---|---|---|
| hosts, wan, device, uptime, internet_up | yes | yes | yes |
| reboot | yes | yes | yes (never run live: it takes the whole LAN down) |
| `wan.up_secs` | no | yes | no |
| `wan.lease_secs` | yes | no | yes |
| `hosts.reserved`, `hosts.lease` | no | yes | yes |
| port forwards | todo | todo | todo |
| wifi | todo | todo | no (no radio) |
| firewall | todo | todo | todo |

A call that is not `yes` croaks `not supported: CALL on ROUTER (why)` before anything touches the router or the
vault, so a script can `eval` it or ask `$r->supports('wifi')` first.

## As a module

```perl
use Router::Op;
my $r = Router::Op->connect('vr180');
printf "%-20s %-15s %s\n", @$_{qw(name ip mac)} for $r->hosts( active => 1 );
print "up\n" if $r->internet_up;
eval { $r->wifi } or warn $@;
```

More names (a second D-Link, say) go in `~/.config/router-op` (or `$ROUTER_OP_CONF`): `NAME MODULE [HOST]`, for
example `lab Router::DLink labdlink`. Names only, never a login.

## Tests

`prove -Ilib t/` (needs the three sibling directories). 161 checks, offline: the modules' own fixtures are run through
the normalisers, a fake module records every call, and the CLI is run only on commands that need no router.
**Nothing here can reboot a router**: the handle refuses `reboot` without `confirm => 1`, and the CLI asks first.
A live read-only run of `router-op all status` / `uptime` / `hosts` was done on 2026-11-23.

## What changed for the old scripts

| Old | Now |
|---|---|
| `vr180 status|hosts|wan|reboot` | `router-op vr180 ...` (the old CLI still works) |
| `cmrouter status|hosts|wan|device` | `router-op cmrouter ...` |
| `cpbee-router ...` | `router-op cpbee ...` |
| `router_reboot` (D-Link only) | `router_reboot [ROUTER]`, default `vr180`: runs `router-op ROUTER reboot` |
| `landata.pl`, `isinternetup.pl`, `GetHosts.pm` | take the router by name (see each script's header) |
