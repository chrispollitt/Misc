use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/../../Router-Actiontec-T3200M/lib", "$Bin/../../Router-Actiontec-T3200M/t/lib",
  "$Bin/../../Router-DLink/lib", "$Bin/../../Router-Cpbee/lib";
use Router::Op;
use Router::Actiontec::T3200M;
use Router::DLink;
use Router::Cpbee;
use FakeRouter;

sub slurp { my ($f) = @_; open( my $h, '<', $f ) or die "$f: $!"; local $/; return <$h> }

my @HOST = qw(name ip mac medium addressing active reserved lease_expires);
my @WAN  = qw(link isp_status mac ip netmask gateway dns lease_secs protocol addressing up_secs);
my @DEV  = qw(model serial firmware hardware hostname uptime_secs);

sub has_keys {
    my ( $h, $keys, $what ) = @_;
    my @missing = grep { !exists $h->{$_} } @$keys;
    ok( !@missing, "$what has every key" ) or diag "missing: @missing";
}

# ---- the three routers' own results, from the modules' fixtures
my $act = Router::Actiontec::T3200M::parse_home( FakeRouter->new->page );
my $dl_wan = Router::DLink::parse_wan( slurp("$Bin/../../Router-DLink/t/data/wan.xml") );
$dl_wan->{link} = 'Connected';
my @dl_hosts = Router::DLink::parse_clients( slurp("$Bin/../../Router-DLink/t/data/dhcp.xml") );
my $dl_dev = Router::DLink::parse_device( slurp("$Bin/../../Router-DLink/t/data/device_info.html") );
my $cp = Router::Cpbee::parse_snapshot( slurp("$Bin/../../Router-Cpbee/t/data/snapshot.txt") );

# ---- hosts
for my $case ( [ cmrouter => $act->{hosts} ], [ vr180 => \@dl_hosts ], [ cpbee => $cp->{hosts} ] ) {
    my ( $name, $in ) = @$case;
    my @h = Router::Op::normalize_hosts( $name, @$in );
    is( scalar @h, scalar @$in, "$name: no host lost" );
    has_keys( $_, \@HOST, "$name host" ) for @h;
    ok( !grep( { !defined $_->{name} } @h ), "$name: names are defined" );
}
my @d = Router::Op::normalize_hosts( vr180 => @dl_hosts );
is( $d[0]{active}, 1, 'vr180: a DHCP client is on the LAN' );
is( $d[0]{addressing}, 'DHCP', 'vr180: addressing DHCP' );
is( $d[0]{reserved}, 0, 'vr180: not reserved' );
is( $d[1]{reserved}, 1, 'vr180: reservation kept' );
is( $d[1]{name}, 'phone & tablet', 'vr180: xml entities decoded' );
ok( $d[0]{lease_expires} > time + 80000 && $d[0]{lease_expires} < time + 90000, 'vr180: lease expiry is an epoch time' );
is( $d[1]{lease_expires}, undef, 'vr180: a lease that never ends has no expiry' );
my @a = Router::Op::normalize_hosts( cmrouter => @{ $act->{hosts} } );
is( $a[1]{reserved}, 0, 'cmrouter: reserved is 0, not missing' );
is( $a[1]{lease_expires}, undef, 'cmrouter: no lease expiry' );
is( $a[1]{mac}, '02:00:00:00:00:0a', 'cmrouter: values pass through' );    # allowlist secret: a fixture MAC address

# ---- wan
for my $case ( [ cmrouter => $act->{wan} ], [ vr180 => $dl_wan ], [ cpbee => $cp->{wan} ] ) {
    my ( $name, $in ) = @$case;
    my $w = Router::Op::normalize_wan( $name, $in );
    has_keys( $w, \@WAN, "$name wan" );
    is( ref $w->{dns}, 'ARRAY', "$name: dns is a list" );
    like( $w->{ip}, qr/\A\d+\.\d+\.\d+\.\d+\z/, "$name: has the address" );
    is( $w->{link}, 'Up', "$name: link is Up" );
    is( $w->{isp_status}, 'Connected', "$name: connected" );
}
my $w = Router::Op::normalize_wan( vr180 => $dl_wan );
is( $w->{up_secs}, 86400, 'vr180: up_secs from the router' );
is( $w->{lease_secs}, '', 'vr180: lease_secs is empty, not missing' );
is( Router::Op::normalize_wan( vr180 => { %$dl_wan, link => 'Disconnected', state => 'Disconnected' } )->{link}, 'Down', 'vr180: a down link is Down' );
is( Router::Op::normalize_wan( cpbee => { %{ $cp->{wan} } } )->{up_secs}, '', 'cpbee: up_secs empty' );

# ---- device
for my $case ( [ cmrouter => $act->{device} ], [ vr180 => $dl_dev ], [ cpbee => $cp->{device} ] ) {
    my ( $name, $in ) = @$case;
    my $dv = Router::Op::normalize_device( $name, $in );
    has_keys( $dv, \@DEV, "$name device" );
    like( $dv->{uptime_secs}, qr/\A\d+\z/, "$name: uptime is seconds" );
    ok( length $dv->{model}, "$name: has a model" );
}
is( Router::Op::normalize_device( cpbee => $cp->{device} )->{hostname}, 'cpbee', 'cpbee keeps its hostname' );

# ---- the capability table covers every router for every call
my $caps = Router::Op->capabilities;
for my $call ( keys %$caps ) {
    for my $n ( Router::Op->names ) {
        like( $caps->{$call}{$n} // '', qr/\A(?:yes|no|todo)\z/, "capability $call/$n is yes, no or todo" );
    }
}
done_testing;
