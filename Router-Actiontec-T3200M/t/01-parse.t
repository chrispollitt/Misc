use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Router::Actiontec::T3200M;
use FakeRouter;

my $fake = FakeRouter->new;
my $html = $fake->page;
my $d = Router::Actiontec::T3200M::parse_home($html);

is( scalar @{ $d->{hosts} }, 3, 'three hosts' );
is_deeply(
    $d->{hosts}[1],
    { name => 'phone', ip => '192.168.1.70', mac => '02:00:00:00:00:0a',
      medium => '802.11', addressing => 'DHCP', active => 1 },
    'host fields, &#58; decoded, mac lower-cased'
);
is( $d->{hosts}[0]{active}, 0, 'inactive host flagged' );
is( $d->{hosts}[2]{addressing}, 'Static', 'static address' );

is( $d->{wan}{ip},      '203.0.113.33', 'wan ip' );
is( $d->{wan}{gateway}, '203.0.113.1',  'wan gateway' );
is( $d->{wan}{mac},     '02:00:00:aa:bb:01', 'wan mac decoded' );
is_deeply( $d->{wan}{dns}, [ '198.51.100.68', '198.51.100.124' ], 'dns list split on decoded comma' );
is( $d->{wan}{link},       'Up',        'link' );
is( $d->{wan}{isp_status}, 'Connected', 'isp status' );

is( $d->{device}{model},    'T3200M',     'model' );
is( $d->{device}{firmware}, '31.164L.22', 'firmware' );
is( $d->{login_user},  '', 'logged out: no user' );
is( $d->{session_key}, '0', 'logged out: session key 0' );

my $key = Router::Actiontec::T3200M::parse_rsa_key($html);
is( $key->{e}, '10001', 'rsa exponent' );
is( lc $key->{n}, lc FakeRouter::modulus(), 'rsa modulus' );
is( Router::Actiontec::T3200M::parse_rsa_key('<html>nothing</html>'), undef, 'no key -> undef' );

eval { Router::Actiontec::T3200M::parse_home('<html>some other page</html>') };
like( $@, qr/no router status variables/, 'non-router page rejected' );

my $empty = $html;
$empty =~ s/var hostinfo = '[^']*'/var hostinfo = ''/;
is( scalar @{ Router::Actiontec::T3200M::parse_home($empty)->{hosts} }, 0, 'empty hostinfo -> no hosts' );

done_testing;
