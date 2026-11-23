use strict;
use warnings;
use Test::More;
use HTTP::Response;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Router::Actiontec::T3200M;
use FakeRouter;

sub router {
    my ( $fake, %o ) = @_;
    return Router::Actiontec::T3200M->new( host => 'cmrouter', ua => $fake, %o );
}

# --- no login needed for status
{
    my $fake = FakeRouter->new;
    my $r    = router($fake);
    ok( !$r->logged_in, 'not logged in at first' );
    is( scalar( () = $r->hosts ), 3, 'hosts without login' );
    is( scalar( () = $r->hosts( active => 1 ) ), 2, 'active only' );
    is_deeply( [ $r->clients ],
        [ [ '192.168.1.70', '02:00:00:00:00:0a', 'phone' ],
          [ '192.168.1.68', '02:00:00:00:00:ff', 'NAS-Box' ] ],
        'clients: [ip, mac, name] for active hosts' );
    is( $r->wan->{ip}, '203.0.113.33', 'wan' );
    is( $r->device->{model}, 'T3200M', 'device' );
    ok( $r->internet_up, 'internet up' );
    is_deeply( [ grep { /POST/ } $fake->log_of ], [], 'status made no POST' );
}

# --- internet down variants
for my $case ( [ Down => 'Connected' ], [ Up => 'Disconnected' ], [ Up => 'Initializing' ] ) {
    my $r = router( FakeRouter->new( link => $case->[0], isp => $case->[1] ) );
    ok( !$r->internet_up, "internet down when link=$case->[0] isp=$case->[1]" );
}

# --- login
{
    my $fake = FakeRouter->new;
    my $r = router( $fake, user => 'admin', password => 'hunter2' );
    isa_ok( $r->login, 'Router::Actiontec::T3200M', 'login returns the object' );
    ok( $r->logged_in, 'logged in' );
    my $f = $fake->{last_form};
    is( $f->{inputUserName}, 'admin', 'username posted' );
    unlike( $f->{inputPassword}, qr/hunter2/, 'password not sent in clear' );
    like( $f->{inputPassword}, qr{\A[A-Za-z0-9+/]+=*\z}, 'password is base64' );
    ok( $f->{sessionId} >= 1 && $f->{sessionId} <= 799_999_999, 'sessionId in the browser range' );
    is( $fake->{last_plain_len}, length('hunter2'), 'router side decrypts to the password' );
    is( $r->{session_key}, '812345678', 'session key picked up after login' );
    is( $r->home->{login_user}, 'admin', 'router reports the user' );
    undef $r;
    ok( ( grep { m{logout\.cgi\?sessionKey=812345678} } $fake->log_of ), 'DESTROY logs out' );
}

# --- explicit logout, only once
{
    my $fake = FakeRouter->new;
    my $r = router( $fake, user => 'admin', password => 'hunter2' )->login;
    $r->logout;
    $r->logout;
    undef $r;
    is( scalar( grep { /logout\.cgi/ } $fake->log_of ), 1, 'logout sent exactly once' );
}

# --- bad login: refused, and the error does not leak the secret
{
    my $fake = FakeRouter->new;
    my $r = router( $fake, user => 'admin', password => 'WRONG-pw-123' );
    eval { $r->login };
    like( $@, qr/refused/, 'bad login refused' );
    unlike( $@, qr/WRONG-pw-123/, 'password not in the error' );
    ok( !$r->logged_in, 'not logged in' );
}

# --- lockout is reported
{
    my $r = router( FakeRouter->new( locked => 1 ), user => 'admin', password => 'nope' );
    eval { $r->login };
    like( $@, qr/locked/, 'lockout mentioned' );
}

# --- no credentials
{
    my $r = router( FakeRouter->new );
    eval { $r->login };
    like( $@, qr/needs user and password/, 'login without credentials croaks' );
}

# --- not a router
{
    package NotARouter;
    sub new { bless {}, shift }
    sub get { my $r = HTTP::Response->new( 200, 'OK' ); $r->content('<html>hello</html>'); $r }
    package main;
    my $r = router( NotARouter->new, user => 'a', password => 'b' );
    eval { $r->login };
    like( $@, qr/no RSA key/, 'non-T3200M page refused at login' );
}

done_testing;
