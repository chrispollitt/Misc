use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Router::Cpbee;

my $text = do { open( my $f, '<', "$Bin/data/snapshot.txt" ) or die $!; local $/; <$f> };
my $d = Router::Cpbee::parse_snapshot($text);
my %by = map { $_->{ip} => $_ } @{ $d->{hosts} };

is_deeply( [ map { $_->{ip} } @{ $d->{hosts} } ],
    [ qw(192.168.10.66 192.168.10.73 192.168.10.77 192.168.10.90 192.168.10.120 192.168.10.150) ],
    'hosts sorted by address; failed, link-local and wan0 neighbours left out' );

is_deeply( $by{'192.168.10.66'},
    { name => 'cmprinter', ip => '192.168.10.66', mac => '02:00:00:00:10:42', medium => 'Ethernet',
      addressing => 'DHCP', active => 1, lease_expires => 1795458325, reserved => 1 },
    'reservation + lease + neighbour merged by MAC' );
is( $by{'192.168.10.77'}{name},   'cmdesktop', 'reservation without a lease keeps its name' );
is( $by{'192.168.10.77'}{active}, 1,           'DELAY neighbour counts as active' );
is( $by{'192.168.10.77'}{lease_expires}, undef, 'no lease: no expiry' );
is( $by{'192.168.10.90'}{active}, 0, 'reservation never seen: inactive' );
is( $by{'192.168.10.90'}{name},   'spare', 'its name comes from dhcp-host' );
is( $by{'192.168.10.120'}{active}, 0, 'lease with no neighbour entry: inactive' );
is( $by{'192.168.10.120'}{name},   '', 'lease hostname * means no name' );
is( $by{'192.168.10.150'}{active}, 1, 'unnamed active lease' );
is( $by{'192.168.10.150'}{reserved}, 0, 'not reserved' );

my $w = $d->{wan};
is( $w->{link}, 'Up', 'wan link' );
is( $w->{isp_status}, 'Connected', 'wan connected' );
is( $w->{ip}, '192.0.2.68', 'wan ip' );
is( $w->{netmask}, '255.255.255.0', 'netmask from prefix length' );
is( $w->{gateway}, '192.0.2.254', 'default gateway' );
is_deeply( $w->{dns}, [ '1.1.1.1', '9.9.9.9' ], 'upstream resolvers from dnsmasq' );
is( $w->{addressing}, 'DHCP', 'dhcp address' );
is( $w->{lease_secs}, 1598694, 'lease seconds' );
is( $w->{mac}, '02:00:00:00:01:68', 'wan mac' );

my $dev = $d->{device};
is( $dev->{hostname}, 'cpbee', 'hostname' );
is( $dev->{kernel}, 'Linux 6.12.111+deb13-amd64', 'kernel' );
is( $dev->{uptime_secs}, 1046286, 'uptime' );
is( $dev->{load5}, '0.30', 'load' );

# variations
sub variant {
    my ($edit) = @_;
    my $t = $text;
    local $_ = $t;
    $edit->();
    return Router::Cpbee::parse_snapshot($_);
}
my $down = variant( sub { s/"operstate":"UP","address":"02:00:00:00:01:68"/"operstate":"DOWN","address":"02:00:00:00:01:68"/ } );
is( $down->{wan}{link}, 'Down', 'operstate DOWN -> link Down' );
is( $down->{wan}{isp_status}, 'Disconnected', '... and disconnected' );
my $nogw = variant( sub { s/=== route\n.*?\n=== neigh/=== route\n[]\n=== neigh/s } );
is( $nogw->{wan}{isp_status}, 'Disconnected', 'no default route -> disconnected' );
is( $nogw->{wan}{gateway}, '', 'no gateway' );
my $off = variant( sub { s/Online state: online/Online state: offline/ } );
is( $off->{wan}{isp_status}, 'Disconnected', 'networkd says offline -> disconnected' );
my $noleases = variant( sub { s/=== leases\n.*?=== dnsmasq/=== leases\n=== dnsmasq/s } );
is( scalar @{ $noleases->{hosts} }, 5, 'no lease file: still has reservations and neighbours' );

eval { Router::Cpbee::parse_snapshot("=== host\ncpbee\n") };
like( $@, qr/incomplete answer/, 'truncated output refused' );
eval { Router::Cpbee::parse_snapshot( ( $text =~ s/=== addr\n.*?\n=== route/=== addr\nnot json\n=== route/sr ) ) };
like( $@, qr/cannot read addresses/, 'bad json explained' );

is( Router::Cpbee::_netmask(16), '255.255.0.0', 'netmask /16' );
is( Router::Cpbee::_netmask(0),  '0.0.0.0',     'netmask /0' );

done_testing;
