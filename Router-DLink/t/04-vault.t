use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Router::DLink;
use FakeDLink;

my $dir = tempdir( CLEANUP => 1 );

sub fake_auth {
    my ( $name, $body ) = @_;
    my $f = "$dir/$name";
    open( my $o, '>', $f ) or die $!;
    print $o $body;
    close $o;
    return [ $^X, $f ];
}

# success: prints LOGIN<TAB>SECRET, and we check the exact arguments
my $good = fake_auth( 'good', <<'PL' );
die "bad args: @ARGV" unless "@ARGV" eq 'get https vr180 --with-login';
print "admin\thunter2\n";
PL
my $r = Router::DLink->new_from_vault( host => 'vr180', auth_cmd => $good, ua => FakeDLink->new );
is( $r->{user}, 'admin', 'login name from vault' );
is( $r->{password}, 'hunter2', 'secret from vault' );
ok( $r->login->logged_in, 'vault credentials log in to the fake router' );

# the default host is vr180
my $d = Router::DLink->new_from_vault( auth_cmd => $good, ua => FakeDLink->new );
is( $d->{host}, 'vr180', 'default host' );

# missing record: auth says so and exits non-zero
my $missing = fake_auth( 'missing', <<'PL' );
print STDERR "auth: no record for https vr180\n";
exit 3;
PL
eval { Router::DLink->new_from_vault( host => 'vr180', auth_cmd => $missing ) };
like( $@, qr/vault lookup for https vr180 failed \(exit 3\): auth: no record/, 'missing record explained' );
like( $@, qr/auth set https\@vr180 LOGIN/, 'error says how to add it' );

# locked vault
my $locked = fake_auth( 'locked', "print qq{vault is locked\\n}; exit 4;\n" );
eval { Router::DLink->new_from_vault( host => 'vr180', auth_cmd => $locked ) };
like( $@, qr/exit 4.*locked/s, 'locked vault reported' );

# garbage on success must never be echoed (it could be a secret)
my $garbage = fake_auth( 'garbage', "print qq{TOPSECRETNOTAB\\n};\n" );
eval { Router::DLink->new_from_vault( host => 'vr180', auth_cmd => $garbage ) };
like( $@, qr/no LOGIN<TAB>SECRET/, 'malformed output rejected' );
unlike( $@, qr/TOPSECRETNOTAB/, 'and not quoted in the error' );

# auth not installed
eval { Router::DLink->new_from_vault( host => 'vr180', auth_cmd => ['/nonexistent/auth'] ) };
like( $@, qr/failed|vault/, 'missing auth program is an error' );

done_testing;
