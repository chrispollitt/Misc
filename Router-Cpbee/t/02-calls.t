use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Router::Cpbee;

my $fake = [ $^X, "$Bin/lib/fake_ssh.pl" ];
sub router { Router::Cpbee->new( ssh => $fake, @_ ) }
sub mode   { $ENV{FAKE_SSH_MODE} = shift; $ENV{FAKE_PING} = shift // 'yes' }

mode('normal');
my $r = router();

# through the real open2 plumbing
is( scalar( () = $r->hosts ), 6, 'hosts over the pipe' );
is( scalar( () = $r->hosts( active => 1 ) ), 4, 'active hosts' );
is_deeply( [ map { $_->[2] } $r->clients ], [ qw(cmprinter cmlaptop cmdesktop) , '' ], 'clients rows: ip, mac, name' );
is( ( $r->clients )[0][0], '192.168.10.66', 'client ip first' );
is( $r->wan->{gateway}, '192.0.2.254', 'wan' );
is( $r->device->{model}, 'cpbee', 'device' );
ok( $r->internet_up, 'internet up' );
ok( $r->internet_up( probe => '1.1.1.1' ), 'probe answered' );
ok( $r->internet_up( probe => 'example.com:80' ), 'probe with host:port' );
mode( 'normal', 'no' );
ok( !$r->internet_up( probe => '1.1.1.1' ), 'probe unanswered: down' );
ok( $r->internet_up, 'without probe the link state decides' );
eval { $r->internet_up( probe => '1.1.1.1; rm -rf /' ) };
like( $@, qr/bad probe/, 'probe target is validated, not passed to a shell' );
ok( $r->login, 'login = reachability check' );

# the script sent is read-only and fixed
my @sent;
my $spy = Router::Cpbee->new( runner => sub { push @sent, $_[0]; open( my $f, '<', "$Bin/data/snapshot.txt" ); local $/; <$f> } );
$spy->hosts;
is( scalar @sent, 1, 'one round trip per call' );
( my $plain = $sent[0] ) =~ s{2>/dev/null}{}g;
unlike( $plain, qr/\b(?:rm|mv|tee|sudo|systemctl|reboot|dd)\b|>/, 'snapshot script has no write, redirect or privileged commands' );
like( $sent[0], qr/networkctl status wan0 /, 'wan interface name in the script' );

# bad construction
eval { Router::Cpbee->new( wan => 'wan0; reboot' ) };
like( $@, qr/bad interface name/, 'interface names validated' );
eval { Router::Cpbee->new( host => 'cpbee;id' ) };
like( $@, qr/bad host name/, 'host validated' );

# ssh down / silent
mode('down');
eval { router()->hosts };
like( $@, qr/no output from cpbee/, 'unreachable box explained' );
eval { router( ssh => [ $^X, '-e', 'sleep 5' ], timeout => 1 )->hosts };
like( $@, qr/no answer in 1s/, 'timeout' );

# reboot
mode('normal');
eval { $r->reboot };
like( $@, qr/confirm => 1/, 'reboot refused without confirm' );
eval { $r->reboot( confirm => 'yes' ) };
like( $@, qr/confirm => 1/, 'only confirm => 1' );
mode('nosudo');
eval { router()->reboot( confirm => 1 ) };
like( $@, qr/refused the reboot \(sudo: a password is required\)/, 'sudo wanting a password is an error' );
mode('reboot_ok');
ok( router()->reboot( confirm => 1 ), 'connection dropping during reboot = success' );
mode('normal');
ok( router()->reboot( confirm => 1 ), 'rc=0 = success' );
mode('down');
eval { router()->reboot( confirm => 1 ) };
like( $@, qr/no output from cpbee/, 'unreachable box: reboot does NOT report success' );

mode('normal');
ok( router()->wait_until_up( timeout => 3, interval => 1 ), 'wait_until_up when it answers' );
mode('down');
ok( !router()->wait_until_up( timeout => 1, interval => 1 ), 'wait_until_up gives up' );

done_testing;
