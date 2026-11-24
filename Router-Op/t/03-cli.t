use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# the parts of router-op that need no router and no vault
my $op = "$^X $Bin/../bin/router-op";
$ENV{ROUTER_OP_CONF} = "$Bin/no-such-file";
$ENV{HOME} = $Bin;

my $out = `$op list 2>&1`;
like( $out, qr/cmrouter\s+Actiontec T3200M/, 'list: cmrouter' );
like( $out, qr/vr180\s+D-Link DIR-655/,       'list: vr180' );
like( $out, qr/cpbee\s+cpbee/,                'list: cpbee' );

$out = `$op capabilities 2>&1`;
like( $out, qr/^wifi\s+todo\s+todo\s+no/m,  'capabilities: wifi' );
like( $out, qr/^reboot\s+yes\s+yes\s+yes/m, 'capabilities: reboot' );
like( $out, qr/yes = works/, 'capabilities: the legend' );

$out = `$op vr180 wifi 2>&1`;
my $rc = $? >> 8;
like( $out, qr/ERROR: not supported: wifi on vr180/, 'an unsupported call says so' );
is( $rc, 1, 'and exits 1' );

$out = `$op all firewall 2>&1`;
like( $out, qr/^cmrouter: ERROR: not supported: firewall on cmrouter/m, 'all: one line per router' );
like( $out, qr/^cpbee: ERROR: not supported: firewall on cpbee/m,       'all: cpbee too' );

$out = `$op all reboot 2>&1 </dev/null`;
$rc  = $? >> 8;
like( $out, qr/reboot needs one named router, not all/, 'reboot all is refused' );
isnt( $rc, 0, 'with a non-zero status' );

$out = `$op nosuch hosts 2>&1`;
like( $out, qr/unknown router: nosuch/, 'an unknown router' );
$out = `$op vr180 frobnicate 2>&1`;
like( $out, qr/unknown command: frobnicate/, 'an unknown command' );

# reboot asks first: answering no stops before anything is built (and so before the vault)
$out = `echo n | $op cpbee reboot 2>&1`;
is( $? >> 8, 2, 'reboot answered no: status 2' );
like( $out, qr/Reboot cpbee .*\? \[y\/N\] not rebooting/, 'it asked, and did not reboot' );

done_testing;
