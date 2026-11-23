use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Router::DLink;
use FakeDLink;

my $f = FakeDLink->new;
my $r = Router::DLink->new( host => 'vr180', password => 'hunter2', ua => $f );

eval { $r->reboot( confirm => 1 ) };
like( $@, qr/logged-in session/, 'reboot needs a login' );
$r->login;

eval { $r->reboot };
like( $@, qr/confirm => 1/, 'reboot refuses without confirm' );
eval { $r->reboot( confirm => 0 ) };
like( $@, qr/confirm => 1/, 'and with confirm => 0' );
ok( !$f->{rebooted}, 'nothing was rebooted so far' );
ok( ( !grep { /reboot/ } $f->log_of ), 'no reboot request even sent' );

ok( $r->reboot( confirm => 1 ), 'reboot with confirm' );
is( $f->{rebooted}, 1, 'the router got exactly one reboot request' );
ok( ( grep { m{/reboot\.cgi\?reset=false$} } $f->log_of ), 'it was reboot.cgi?reset=false (keeps settings)' );
ok( !$r->logged_in, 'session is gone afterwards' );

# a router that shows the login page instead of rebooting is an error
my $f2 = FakeDLink->new;
my $r2 = Router::DLink->new( host => 'vr180', password => 'hunter2', ua => $f2 );
$r2->login;
$f2->{session} = 0;    # session lost behind our back
eval { $r2->reboot( confirm => 1 ) };
like( $@, qr/refused the reboot/, 'login page instead of reboot is reported' );

done_testing;
