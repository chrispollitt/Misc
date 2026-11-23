use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Router::DLink;
use FakeDLink;

sub mk { my %a = @_; my $f = FakeDLink->new( %{ delete $a{fake} || {} } ); ( Router::DLink->new( host => 'vr180', user => 'admin', password => 'hunter2', ua => $f, %a ), $f ) }

# good login
my ( $r, $f ) = mk();
ok( !$r->logged_in, 'not logged in yet' );
eval { $r->wan };
like( $@, qr/not logged in/, 'data needs a login' );
ok( $r->login->logged_in, 'login works' );
is( $f->{last_hash}, $FakeDLink::GOLDEN{admin}, 'the router saw the right hash' );
is( $f->{last_auth_id}, '17E71', 'and the auth_id' );
unlike( join( "\n", $f->log_of ), qr/hunter2/, 'password never in a request' );

# data
my $w = $r->wan;
is( $w->{ip}, '203.0.113.45', 'wan ip' );
is( $w->{state}, 'Connected', 'wan state' );
is( $w->{link}, 'Connected', 'physical link' );
is( $w->{lan_ip}, '192.168.0.1', 'lan ip' );
ok( $r->internet_up, 'internet up' );
is_deeply( $r->device, { model => 'DIR-655', hardware => 'A3', firmware => '1.37', uptime_secs => 1046314 }, 'device info' );
$f->{wan_down} = 1;
ok( !$r->internet_up, 'WAN port unplugged: placeholder address, but internet is down' );
is( $r->wan->{state}, 'Disconnected', 'state says so' );
is( $r->wan->{link}, 'Disconnected', 'and the link' );
$f->{wan_down} = 0;
my @c = $r->clients;
is_deeply( $c[0], [ '192.168.0.101', 'aa:bb:cc:00:00:01', 'laptop' ], 'clients rows [ip, mac, name]' );
is( scalar( $r->hosts ), 3, 'hosts' );
is_deeply( $r->get_wan_data, { IP => '203.0.113.45', GWAY => '203.0.113.1', DNS => '198.51.100.1' }, '2018 get_wan_data shape' );
is( scalar @{ $r->get_lan_data->{CLIENTS} }, 3, '2018 get_lan_data shape' );

# logout
$r->logout;
ok( !$r->logged_in && !$f->{session}, 'logout ends the session' );

# user login
my ( $u, $uf ) = mk( user => 'user', fake => { user => 'user' } );
ok( $u->login->logged_in, "'user' login adds the U" );

# wrong password / login name
my ( $bad ) = mk( password => 'wrong' );
eval { $bad->login };
like( $@, qr/wrong login or password/, 'bad credentials refused' );
unlike( $@, qr/wrong\b.*\bhunter2/, 'no secret in the error' );
ok( !$bad->logged_in, 'still logged out' );
my ($odd) = mk( user => 'root' );
eval { $odd->login };
like( $@, qr/'admin' and 'user'/, 'unknown login name refused before sending anything' );

# timeout answer, graphical code
my ($t) = mk( fake => { post_login => 'timeout' } );
eval { $t->login };
like( $@, qr/timed out/, 'timeout reported' );
my ($g) = mk( fake => { graphic => 1 } );
eval { $g->login };
like( $@, qr/graphical/, 'graphical router refused' );
ok( !$g->{ua}{last_hash}, 'before any hash was sent' );

# router says OK but still shows the login page (session not accepted)
{
    package FakeNoSession;
    our @ISA = ('FakeDLink');
    sub get { my ( $s, $u ) = @_; my $r = $s->SUPER::get($u); $s->{session} = 0 if $u =~ /post_login/; $r }
}
my $ns = Router::DLink->new( host => 'vr180', password => 'hunter2', ua => FakeNoSession->new );
eval { $ns->login };
like( $@, qr/did not give access/, 'accepted hash but no access is caught' );

# old two-argument constructor
my $old = Router::DLink->new( 'vr180', 'hunter2' );
is( $old->{host}, 'vr180', '2018 new(host, password)' );
is( $old->{password}, 'hunter2', 'with the password' );

# wait_until_up
my ( $wr ) = mk();
ok( $wr->wait_until_up( timeout => 1, interval => 1 ), 'wait_until_up sees the login page' );

done_testing;
