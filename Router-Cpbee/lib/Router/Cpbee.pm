package Router::Cpbee;

use strict;
use warnings;

our $VERSION = '0.01';

use Carp qw(croak);
use JSON::PP ();
use Sys::Hostname ();
use IPC::Open2 qw(open2);

=head1 NAME

Router::Cpbee - read the state of cpbee, the Debian box that is the home router

=head1 SYNOPSIS

    use Router::Cpbee;

    my $r = Router::Cpbee->new;               # host 'cpbee', via ssh (or locally on cpbee)
    for my $h ($r->hosts) {
        printf "%-20s %-15s %s\n", $h->{name}, $h->{ip}, $h->{mac};
    }
    print "internet is ", ($r->internet_up ? "up" : "DOWN"), "\n";
    my $wan = $r->wan;                        # ip, gateway, dns, ...
    my @rows = $r->clients;                   # [ip, mac, name], as GetHosts.pm wants

=head1 DESCRIPTION

cpbee (Debian 13, dnsmasq + nftables + systemd-networkd) routes the home LAN
(C<lan0>, 192.168.10.0/24) to the upstream router on C<wan0>. This module is the
cpbee counterpart of L<Router::Actiontec::T3200M>: same calls, same result shapes,
so a caller can be pointed at either router.

Nothing is installed on cpbee and nothing needs a password. Each call makes one
C<ssh cpbee sh -s> (key login, C<BatchMode>) that feeds a fixed read-only shell
script on stdin and parses what comes back: C<ip -j> output, the dnsmasq lease file
and C<dnsmasq.d> configuration. When the module runs on cpbee itself the script runs
locally instead of through ssh. The script is never built from caller input except
validated interface names and the optional probe target.

=head1 CONSTRUCTOR

=head2 new(%args)

C<host> (default C<cpbee>), C<lan> (array ref of LAN interfaces, default
C<['lan0']>), C<wan> (default C<wan0>), C<ssh> (array ref, default
C<['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8']>), C<local> (true to run
the script locally; default: true when this machine's hostname is C<host>),
C<timeout> (seconds, default 30), C<runner> (code ref C<< sub { my ($script) = @_; return $output } >>,
for tests).

=cut

sub new {
    my ( $class, %a ) = @_;
    my $host = defined $a{host} ? $a{host} : 'cpbee';
    my $self = bless {
        host    => $host,
        lan     => $a{lan} || ['lan0'],
        wan     => defined $a{wan} ? $a{wan} : 'wan0',
        ssh     => $a{ssh} || [ 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8' ],
        local   => defined $a{local} ? $a{local} : ( _short_hostname() eq $host ? 1 : 0 ),
        timeout => $a{timeout} || 30,
        runner  => $a{runner},
    }, $class;
    for my $if ( @{ $self->{lan} }, $self->{wan} ) {
        croak "bad interface name '$if'" unless $if =~ /\A[A-Za-z0-9_.-]{1,15}\z/;
    }
    croak "bad host name '$host'" unless $host =~ /\A[A-Za-z0-9_.-]+\z/;
    return $self;
}

sub _short_hostname { my $h = Sys::Hostname::hostname(); $h =~ s/\..*//; return $h }

# --- running things on cpbee ---------------------------------------------

# Feed a shell script to `sh -s` on cpbee (ssh) or here; return its output.
sub _run {
    my ( $self, $script ) = @_;
    return $self->{runner}->($script) if $self->{runner};
    my @cmd = $self->{local} ? ( 'sh', '-s' ) : ( @{ $self->{ssh} }, $self->{host}, 'sh', '-s' );
    my $pid = open2( my $out, my $in, @cmd );
    my $text = '';
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $self->{timeout};
        print {$in} $script;
        close $in;
        local $/;
        $text = <$out>;
        alarm 0;
        1;
    };
    my $err = $@;
    alarm 0;
    if ( !$ok ) {
        kill 'TERM', $pid;
        waitpid( $pid, 0 );
        croak "talking to $self->{host} failed: " . ( $err =~ /timeout/ ? "no answer in $self->{timeout}s" : $err );
    }
    close $out;
    waitpid( $pid, 0 );
    $text = '' unless defined $text;
    croak "no output from $self->{host} (is ssh to it working? try: ssh $self->{host} true)"
      if $text eq '';
    return $text;
}

sub _snapshot_script {
    my ($self) = @_;
    my $wan = $self->{wan};
    return <<"SH";
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
echo '=== host';    hostname
echo '=== kernel';  uname -sr
echo '=== now';     date +%s
echo '=== uptime';  cat /proc/uptime
echo '=== load';    cat /proc/loadavg
echo '=== addr';    ip -j -4 addr show
echo '=== link';    ip -j link show
echo '=== route';   ip -j -4 route show default
echo '=== neigh';   ip -j -4 neigh show
echo '=== leases';  cat /var/lib/misc/dnsmasq.leases 2>/dev/null
echo '=== dnsmasq'; cat /etc/dnsmasq.d/*.conf 2>/dev/null
echo '=== online';  networkctl status $wan --no-pager 2>/dev/null | grep -i 'Online state'
echo '=== end'
SH
}

# Split the snapshot into { section => text }.
sub _sections {
    my ($text) = @_;
    my ( %s, $cur );
    for my $line ( split /\n/, $text ) {
        if ( $line =~ /\A=== (\w+)\s*\z/ ) { $cur = $1; $s{$cur} = ''; next }
        $s{$cur} .= "$line\n" if defined $cur;
    }
    croak "incomplete answer from cpbee (no end marker)" unless exists $s{end};
    return \%s;
}

sub _json {
    my ( $s, $what ) = @_;
    my $d = eval { JSON::PP->new->decode( length $s ? $s : '[]' ) };
    croak "cannot read $what from cpbee: $@" unless $d;
    return $d;
}

=head1 CALLS

All of them take a fresh snapshot (one round trip, well under a second on the LAN).

=head2 snapshot

Returns the parsed state: a hash ref with C<hosts>, C<wan>, C<device>.
See C<parse_snapshot> below.

=head2 hosts

List of hash refs, as in L<Router::Actiontec::T3200M>: C<name>, C<ip>, C<mac>
(lower case), C<medium> (C<Ethernet>), C<addressing> (C<DHCP> for a lease or a
fixed reservation, C<Static> for a device with no lease), C<active> (1 if the
kernel's neighbour table has it now), plus C<lease_expires> (epoch, or undef) and
C<reserved> (1 if it has a C<dhcp-host> line). Sorted by address.
C<< active => 1 >> keeps only the active ones.

=head2 clients

C<[ip, mac, name]> rows of the active hosts.

=head2 wan

C<link> (Up/Down), C<isp_status> (Connected/Disconnected), C<ifname>, C<mac>, C<ip>,
C<netmask>, C<gateway>, C<dns> (upstream resolvers dnsmasq uses), C<lease_secs>,
C<protocol>, C<addressing>.

=head2 internet_up(probe => $host)

True when the WAN link is up, it has an address and a default route, and
systemd-networkd does not say C<offline>. With C<probe> (C<host> or C<host:port>, port default 443, e.g. C<1.1.1.1:443>)
cpbee also makes one TCP connection to it. (Not a ping: the upstream router
drops ICMP echo to the Internet, so a ping would say "down" on a working link.)

=head2 device

C<hostname>, C<model> (C<cpbee>), C<kernel>, C<uptime_secs>, C<load1>, C<load5>, C<load15>.

=cut

sub snapshot {
    my ($self) = @_;
    return parse_snapshot( $self->_run( $self->_snapshot_script ), lan => $self->{lan}, wan => $self->{wan} );
}

sub hosts {
    my ( $self, %o ) = @_;
    my @h = @{ $self->snapshot->{hosts} };
    @h = grep { $_->{active} } @h if $o{active};
    return @h;
}

sub clients { map { [ @$_{qw(ip mac name)} ] } $_[0]->hosts( active => 1 ) }
sub wan     { $_[0]->snapshot->{wan} }
sub device  { $_[0]->snapshot->{device} }

sub internet_up {
    my ( $self, %o ) = @_;
    my $snap = $self->snapshot;
    my $w    = $snap->{wan};
    return 0 unless $w->{link} eq 'Up' && $w->{isp_status} eq 'Connected';
    if ( defined $o{probe} ) {
        croak "bad probe target" unless $o{probe} =~ /\A([A-Za-z0-9_.-]+)(?::(\d{1,5}))?\z/;
        my ( $h, $p ) = ( $1, $2 // 443 );
        # TCP connect, not ping: the upstream router drops ICMP echo to the Internet
        my $out = $self->_run("timeout 5 bash -c 'exec 3<>/dev/tcp/$h/$p' >/dev/null 2>&1 && echo yes || echo no\n");
        return $out =~ /^yes/ ? 1 : 0;
    }
    return 1;
}

# `login` / `logout` exist so a caller can treat both routers alike. cpbee needs
# no login: ssh keys do that. login just proves the box answers.
sub login  { my ($self) = @_; $self->_run("hostname\n"); return $self }
sub logout { $_[0] }

=head2 reboot(confirm => 1)

Reboots cpbee with C<sudo -n systemctl reboot>. Refuses without C<< confirm => 1 >>.
Needs passwordless sudo for that one command on cpbee; if sudo wants a password
the call croaks and nothing happens. It also takes the whole LAN offline while it
reboots. The ssh connection dropping as the box goes down counts as success.

=head2 wait_until_up(timeout => 300, interval => 5)

Polls until cpbee answers again. True if it did.

=cut

sub reboot {
    my ( $self, %o ) = @_;
    croak "reboot needs confirm => 1" unless defined $o{confirm} && $o{confirm} eq '1';
    $self->login;    # croaks if cpbee does not answer: then a dropped connection below really means "going down"
    my $out = eval { $self->_run("sudo -n systemctl reboot 2>&1; echo rc=\$?\n") };
    if ( !defined $out ) {
        # the connection died as the machine went down: expected
        return 1;
    }
    if ( $out =~ /rc=(\d+)/ && $1 != 0 ) {
        ( my $why = $out ) =~ s/\s*rc=\d+\s*\z//;
        $why =~ s/\s+/ /g;
        croak "cpbee refused the reboot ($why); sudo -n needs passwordless sudo for systemctl reboot";
    }
    return 1;
}

sub wait_until_up {
    my ( $self, %o ) = @_;
    my $deadline = time + ( $o{timeout} || 300 );
    my $interval = $o{interval} || 5;
    while (1) {
        return 1 if eval { $self->login; 1 };
        return 0 if time >= $deadline;
        sleep $interval;
    }
}

=head1 PARSING (usable without cpbee)

=head2 parse_snapshot($text, lan => [...], wan => 'wan0')

Parses the script output into C<{hosts, wan, device}>. Croaks on a truncated answer.

=cut

sub parse_snapshot {
    my ( $text, %o ) = @_;
    my @lan = @{ $o{lan} || ['lan0'] };
    my $wan = defined $o{wan} ? $o{wan} : 'wan0';
    my $s   = _sections($text);
    chomp( my $now = $s->{now} // '' );
    $now = time unless $now =~ /\A\d+\z/;

    # ---- device
    my ( $up ) = ( $s->{uptime} // '' ) =~ /\A(\d+(?:\.\d+)?)/;
    my ( $l1, $l5, $l15 ) = ( $s->{load} // '' ) =~ /\A(\S+)\s+(\S+)\s+(\S+)/;
    my %dev = (
        hostname     => _line( $s->{host} ),
        model        => 'cpbee',
        kernel       => _line( $s->{kernel} ),
        uptime_secs  => defined $up ? int($up) : undef,
        load1 => $l1, load5 => $l5, load15 => $l15,
    );

    # ---- wan
    my $addrs = _json( $s->{addr},  'addresses' );
    my $links = _json( $s->{link},  'links' );
    my $route = _json( $s->{route}, 'routes' );
    my ($if)  = grep { $_->{ifname} eq $wan } @$addrs;
    my ($a4)  = $if ? grep { ( $_->{family} // '' ) eq 'inet' } @{ $if->{addr_info} || [] } : ();
    my ($def) = grep { ( $_->{dev} // '' ) eq $wan && ( $_->{dst} // '' ) eq 'default' } @$route;
    my ($online) = ( $s->{online} // '' ) =~ /Online state:\s*(\w+)/i;
    my $link = ( $if && ( $if->{operstate} // '' ) eq 'UP' ) ? 'Up' : 'Down';
    my $has_ip = $a4 && $a4->{local} ? 1 : 0;
    my $connected = ( $link eq 'Up' && $has_ip && $def && $def->{gateway}
          && !( defined $online && lc $online eq 'offline' ) ) ? 1 : 0;

    my @dns;
    for my $l ( split /\n/, $s->{dnsmasq} // '' ) {
        push @dns, $1 if $l =~ /\A\s*server=(\d+\.\d+\.\d+\.\d+)\s*\z/;
    }
    my %wan = (
        link       => $link,
        isp_status => $connected ? 'Connected' : 'Disconnected',
        ifname     => $wan,
        mac        => ( map { lc( $_->{address} // '' ) } grep { $_->{ifname} eq $wan } @$links )[0] // '',
        ip         => $has_ip ? $a4->{local} : '',
        netmask    => $has_ip ? _netmask( $a4->{prefixlen} ) : '',
        gateway    => $def ? ( $def->{gateway} // '' ) : '',
        dns        => \@dns,
        lease_secs => ( $a4 && $a4->{dynamic} && defined $a4->{valid_life_time} && $a4->{valid_life_time} < 4294967295 ) ? $a4->{valid_life_time} : '',
        protocol   => $def ? ( $def->{protocol} // '' ) : '',
        addressing => ( $a4 && $a4->{dynamic} ) ? 'DHCP' : 'Static',
    );

    # ---- hosts: reservations, leases, neighbours; merged by MAC
    my %h;
    for my $l ( split /\n/, $s->{dnsmasq} // '' ) {
        next unless $l =~ /\A\s*dhcp-host=(.+?)\s*\z/;
        my ( $mac, $ip, $name );
        for my $f ( split /,/, $1 ) {
            if    ( $f =~ /\A([0-9a-f]{2}(?::[0-9a-f]{2}){5})\z/i ) { $mac  = lc $1 }
            elsif ( $f =~ /\A(\d+\.\d+\.\d+\.\d+)\z/ )              { $ip   = $1 }
            elsif ( $f =~ /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/ && $f !~ /\A(?:infinite|ignore)\z/ ) { $name //= $f }
        }
        next unless $mac;
        $h{$mac} = { %{ $h{$mac} || {} }, mac => $mac, reserved => 1,
                     ( defined $ip ? ( ip => $ip ) : () ), ( defined $name ? ( rname => $name ) : () ) };
    }
    for my $l ( split /\n/, $s->{leases} // '' ) {
        my ( $exp, $mac, $ip, $name ) = split ' ', $l;
        next unless defined $ip && $mac =~ /:/;
        $mac = lc $mac;
        $h{$mac} = { %{ $h{$mac} || {} }, mac => $mac, ip => $ip, lease_expires => $exp + 0,
                     ( defined $name && $name ne '*' ? ( lname => $name ) : () ),
                     lease => 1 };
    }
    my %lan = map { $_ => 1 } @lan;
    for my $n ( @{ _json( $s->{neigh}, 'neighbours' ) } ) {
        next unless $lan{ $n->{dev} // '' };
        next unless $n->{lladdr} && $n->{dst} && $n->{dst} !~ /\A169\.254\./;
        my %st = map { $_ => 1 } @{ $n->{state} || [] };
        next if $st{FAILED} || $st{INCOMPLETE};
        my $mac = lc $n->{lladdr};
        my $e   = $h{$mac} ||= { mac => $mac, ip => $n->{dst} };
        $e->{seen} = 1;
        $e->{ip} = $n->{dst} unless $e->{lease} || defined $e->{ip};
    }
    my @hosts;
    for my $e ( values %h ) {
        next unless defined $e->{ip};
        push @hosts,
          {
            name          => $e->{rname} // $e->{lname} // '',
            ip            => $e->{ip},
            mac           => $e->{mac},
            medium        => 'Ethernet',
            addressing    => ( $e->{lease} || $e->{reserved} ) ? 'DHCP' : 'Static',
            active        => $e->{seen} ? 1 : 0,
            lease_expires => $e->{lease_expires},
            reserved      => $e->{reserved} ? 1 : 0,
          };
    }
    @hosts = sort { _ipnum( $a->{ip} ) <=> _ipnum( $b->{ip} ) } @hosts;

    return { hosts => \@hosts, wan => \%wan, device => \%dev, now => $now };
}

sub _line { my ($t) = @_; $t = '' unless defined $t; $t =~ s/\s+\z//; return $t }

sub _ipnum { my @o = split /\./, $_[0]; return ( ( $o[0] * 256 + $o[1] ) * 256 + $o[2] ) * 256 + $o[3] }

sub _netmask {
    my ($p) = @_;
    return '' unless defined $p && $p =~ /\A\d+\z/ && $p <= 32;
    my $m = $p ? ( 0xFFFFFFFF << ( 32 - $p ) ) & 0xFFFFFFFF : 0;
    return join '.', unpack( 'C4', pack( 'N', $m ) );
}

=head1 AUTHOR

Chris Pollitt. Part of the Misc repository.

=cut

1;
