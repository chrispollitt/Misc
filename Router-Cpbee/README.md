# Router::Cpbee

Perl module for **cpbee**, the Debian 13 box that routes the home LAN (`lan0`, 192.168.10.0/24) to the upstream
router on `wan0` (dnsmasq + nftables + systemd-networkd; set up by `POSIX/cmpi-router/bin/setup-router.sh`).
It is the sibling of [`Router::Actiontec::T3200M`](../Router-Actiontec-T3200M): the same calls and result shapes,
so a script can be pointed at either router.

Core Perl only (`JSON::PP`, `IPC::Open2`). Nothing is installed on cpbee and no password is involved.

## How it works

Each call runs one fixed, read-only shell script on cpbee through `ssh cpbee sh -s` (key login, `BatchMode`)
and parses the output: `ip -j` addresses, links, routes and neighbours, `/var/lib/misc/dnsmasq.leases`,
`/etc/dnsmasq.d/*.conf` (the `dhcp-host=` reservations and `server=` resolvers), `networkctl` online state,
uptime and load. On cpbee itself the script runs locally. About 0.5 s per call.

| Call | What |
|---|---|
| `hosts(active => 0/1)`, `clients` | LAN devices merged by MAC from reservations, leases and the neighbour table: `name ip mac medium addressing active lease_expires reserved`. `clients` = `[ip, mac, name]` rows of the active ones (what `GetHosts.pm` wants) |
| `wan` | `link isp_status ifname mac ip netmask gateway dns lease_secs protocol addressing` |
| `internet_up(probe => 'host[:port]')` | link up + address + default route + networkd not `offline`; with `probe`, also one TCP connect from cpbee |
| `device` | `hostname model kernel uptime_secs load1 load5 load15` |
| `login`, `logout` | reachability check / no-op (kept for parity with the T3200M module) |
| `reboot(confirm => 1)`, `wait_until_up` | `sudo -n systemctl reboot` on cpbee; **not run live**. Needs passwordless sudo for that command, otherwise it croaks and nothing happens. It takes the whole LAN offline |

An `active` host is one the kernel has in its neighbour table now (not `FAILED`/`INCOMPLETE`); a lease alone
does not make a host active, because dnsmasq keeps leases for 12 h after a device leaves.

## Why the probe is TCP, not ping

The upstream router (the Actiontec) drops ICMP echo to the Internet, so `ping 1.1.1.1` from cpbee fails while the
link works fine. `internet_up(probe => '1.1.1.1:443')` makes a TCP connection instead.

## Use

```perl
use Router::Cpbee;
my $r = Router::Cpbee->new;                       # host 'cpbee'
print $r->internet_up(probe => '1.1.1.1:443') ? "up\n" : "DOWN\n";
printf "%-15s %s\n", @$_[0,2] for $r->clients;
```

```bash
perl bin/cpbee-router status          # exit 1 when down; probes 1.1.1.1:443 (--probe H:P, --no-probe)
perl bin/cpbee-router hosts
perl bin/cpbee-router wan
perl bin/cpbee-router device
```

Documentation: `perldoc lib/Router/Cpbee.pm`.

## Tests

```bash
prove -l t        # a few seconds, no cpbee needed
```

`t/data/snapshot.txt` is a recorded-shape snapshot with invented MACs and documentation addresses.
`t/lib/fake_ssh.pl` stands in for `ssh cpbee sh -s`, so the real pipe code runs in the tests, including ssh
down, a timeout, a missing sudo password and the connection dropping during a reboot.

## Limits

* Only IPv4 and the interfaces `lan0` / `wan0` by default (`new(lan => [...], wan => '...')` to change).
* Wi-Fi devices behind a switch show as `Ethernet`; the module has no way to tell.
* The `vaxtap` / `vr180` interfaces are not part of `lan` and their hosts are not listed.
