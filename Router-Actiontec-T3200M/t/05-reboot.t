use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Router::Actiontec::T3200M;
use FakeRouter;

sub router {
    my ($fake) = @_;
    return Router::Actiontec::T3200M->new( host => 'cmrouter', ua => $fake, user => 'admin', password => 'hunter2' );
}

# never reboots without confirm, or without a login
{
    my $fake = FakeRouter->new;
    my $r = router($fake)->login;
    eval { $r->reboot };
    like( $@, qr/confirm => 1/, 'no confirm: refused' );
    eval { $r->reboot( confirm => 0 ) };
    like( $@, qr/confirm => 1/, 'confirm => 0: refused' );
    eval { $r->reboot( confirm => 'yes' ) };
    like( $@, qr/confirm => 1/, "confirm => 'yes': refused (only 1)" );
    ok( !$fake->{rebooted}, 'router untouched by refused calls' );
    ok( !( grep { /rebootinfo/ } $fake->log_of ), 'no request for the reboot page was even made' );
}
{
    my $fake = FakeRouter->new;
    my $r = router($fake);
    eval { $r->reboot( confirm => 1 ) };
    like( $@, qr/logged-in session/, 'not logged in: refused' );
    ok( !$fake->{rebooted}, 'router untouched' );
}

# the real call
{
    my $fake = FakeRouter->new;
    my $r = router($fake)->login;
    ok( $r->reboot( confirm => 1 ), 'reboot accepted' );
    is( $fake->{rebooted}, 1, 'router got exactly one reboot request' );
    ok( !$r->logged_in, 'session considered gone afterwards' );
}

# a session the router rejects is an error, not a silent success
{
    my $fake = FakeRouter->new;
    my $r = router($fake)->login;
    $fake->{sessions} = 0;    # router forgot us
    eval { $r->reboot( confirm => 1 ) };
    like( $@, qr/refused the reboot/, '403 from the router is an error' );
    ok( !$fake->{rebooted}, 'no reboot happened' );
}

# wait_until_up
{
    my $fake = FakeRouter->new;
    my $r = router($fake);
    ok( $r->wait_until_up( timeout => 5, interval => 1 ), 'router answering: true at once' );

    package DownUA;
    sub new { bless { n => 0 }, shift }
    sub get { die "connection refused\n" }
    package main;
    my $down = router( DownUA->new );
    ok( !$down->wait_until_up( timeout => 1, interval => 1 ), 'router never answers: false after timeout' );
}

done_testing;
