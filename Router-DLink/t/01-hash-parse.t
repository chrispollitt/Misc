use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Router::DLink;
use FakeDLink;

# Golden values: produced by running the router's own md5.js and send_login()
# logic in node (see t/lib/FakeDLink.pm), not by this module.
is( Router::DLink::login_hash( 'f18d5ff9', 'hunter2', 'admin' ), 'f18d5ff9efd9b84ce4e55896bb0abf719109a5c2', 'admin hash' );
is( Router::DLink::login_hash( 'f18d5ff9', 'hunter2', 'user' ),  'f18d5ff92be0a7ec2e59ab43503e6ef3bae4c55e', 'user login adds U' );
is( Router::DLink::login_hash( 'f18d5ff9', 'a-much-longer-pass-word', 'admin' ), 'f18d5ff9166aab7c895615c6c7540f80190dfffd', 'password cut at 16 like the page' );
is( Router::DLink::login_hash( '0a1b2c3d', '', 'admin' ), '0a1b2c3d1d77162b2be3f2f79f59844514199825', 'empty password' );
is( Router::DLink::login_hash( 'f18d5ff9', 'hunter2' ), Router::DLink::login_hash( 'f18d5ff9', 'hunter2', 'admin' ), 'admin is the default' );

my $page = FakeDLink::slurp("$Bin/data/login.html");
my $p = Router::DLink::parse_login_page($page);
is( $p->{salt},    'f18d5ff9', 'salt from the real login page' );
is( $p->{auth_id}, '17E71',    'auth_id from the real login page' );
is( $p->{graphic_auth}, 0, 'no graphical code' );
$page =~ s/var graphic_auth = "false";/var graphic_auth = "true";/;
is( Router::DLink::parse_login_page($page)->{graphic_auth}, 1, 'graphical code detected' );
is( Router::DLink::parse_login_page('<html>nothing</html>'), undef, 'no salt, no parse' );

ok( Router::DLink::is_login_page( FakeDLink::slurp("$Bin/data/redirect.html") ), 'redirect stub is the login page' );
ok( Router::DLink::is_login_page( FakeDLink::slurp("$Bin/data/login.html") ), 'login page is the login page' );
ok( !Router::DLink::is_login_page( FakeDLink::slurp("$Bin/data/wan.xml") ), 'data is not' );

is( Router::DLink::xml_value( '<a><login> index.html </login></a>', 'login' ), 'index.html', 'xml_value trims' );
is( Router::DLink::xml_value( '<a></a>', 'login' ), undef, 'xml_value absent' );

my $w = Router::DLink::parse_wan( FakeDLink::slurp("$Bin/data/wan.xml") );
is( $w->{ip},      '203.0.113.45', 'wan ip' );
is( $w->{gateway}, '203.0.113.1',  'wan gateway' );
is( $w->{netmask}, '255.255.254.0', 'wan netmask' );
is_deeply( $w->{dns}, [ '198.51.100.1', '198.51.100.2' ], 'dns list, primary first' );
is( $w->{connection_state}, 2, 'state number' );
is( $w->{state}, 'Connected', 'state name' );
is( $w->{up_secs}, 86400, 'up time' );
my $wd = Router::DLink::parse_wan( FakeDLink::slurp("$Bin/data/wan_down.xml") );
is( $wd->{state}, 'Disconnected', 'down state' );
is_deeply( $wd->{dns}, ['192.168.5.5'], 'duplicate dns collapsed' );
is_deeply( Router::DLink::parse_device( FakeDLink::slurp("$Bin/data/device_info.html") ),
    { model => 'DIR-655', hardware => 'A3', firmware => '1.37', uptime_secs => 1046314 }, 'device info parse' );
eval { Router::DLink::parse_device('<html>login</html>') };
like( $@, qr/no device information/, 'device parse refuses a non-device page' );

my @h = Router::DLink::parse_clients( FakeDLink::slurp("$Bin/data/dhcp.xml") );
is( scalar @h, 3, 'three clients' );
is( $h[0]{mac}, 'aa:bb:cc:00:00:01', 'mac lower-cased' );
is( $h[1]{name}, 'phone & tablet', 'entities decoded' );
is( $h[2]{name}, '', 'empty name kept' );
is( $h[2]{ip}, '192.168.0.103', 'ip' );
is( $h[1]{seconds_remaining}, 4294967295, 'reservation lease' );
is( $h[1]{is_reservation}, 1, 'reservation flag' );

done_testing;
