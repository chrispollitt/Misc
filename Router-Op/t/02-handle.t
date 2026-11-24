use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Router::Op;

# a stand-in for a module that records every call; nothing here can reach a router or the vault
{
    package FakeNative;
    sub new { my ( $c, %a ) = @_; return bless { calls => [], %a }, $c }
    sub _rec { my ( $s, $n ) = @_; push @{ $s->{calls} }, $n; return }
    sub login       { $_[0]->_rec('login'); $_[0] }
    sub logout      { $_[0]->_rec('logout'); $_[0] }
    sub hosts       { $_[0]->_rec('hosts'); @{ $_[0]{hosts} || [] } }
    sub wan         { $_[0]->_rec('wan'); $_[0]{wan} || {} }
    sub device      { $_[0]->_rec('device'); $_[0]{device} || {} }
    sub internet_up { my $s = shift; $s->_rec('internet_up'); $s->{args} = [@_]; $s->{up} }
    sub reboot      { my ( $s, %o ) = @_; $s->_rec('reboot'); die "no confirm\n" unless $o{confirm}; 1 }
    sub wait_until_up { $_[0]->_rec('wait'); 1 }
}

sub handle {
    my ( $name, %a ) = @_;
    my $n = FakeNative->new(%a);
    return ( Router::Op->connect( $name, native => $n ), $n );
}

# ---- unknown name
eval { Router::Op->connect('nosuch') };
like( $@, qr/unknown router 'nosuch' \(one of cmrouter, vr180, cpbee\)/, 'an unknown name is refused, with the names' );

# ---- unsupported calls fail the same way everywhere, and never touch the router
for my $name (qw(cmrouter vr180 cpbee)) {
    my ( $r, $n ) = handle($name);
    for my $call (qw(port_forwards wifi firewall)) {
        eval { $r->$call };
        like( $@, qr/\Anot supported: $call on $name \(/, "$name $call: not supported, in one wording" );
    }
    is_deeply( $n->{calls}, [], "$name: an unsupported call does not log in or ask the router" );
}
{
    my ($cp) = handle('cpbee');
    eval { $cp->wifi };
    like( $@, qr/this router cannot/, 'cpbee has no radio: says "cannot"' );
    my ($v) = handle('vr180');
    eval { $v->wifi };
    like( $@, qr/not been written yet/, 'vr180 wifi: says "not written yet"' );
    ok( $v->supports('hosts'), 'supports(hosts)' );
    ok( !$v->supports('wifi'), 'does not support wifi' );
    ok( $v->supports('wan.up_secs'), 'vr180 has up_secs' );
    my ($c) = handle('cmrouter');
    ok( !$c->supports('wan.up_secs'), 'cmrouter has no up_secs' );
}

# ---- login rules: vr180 always, cmrouter only for reboot, cpbee none
{
    my ( $r, $n ) = handle( vr180 => hosts => [ { name => 'a', ip => '1.2.3.4', mac => 'aa:bb:cc:00:00:01' } ] );
    my @h = $r->hosts;
    is( $n->{calls}[0], 'login', 'vr180 logs in before a read' );
    is( scalar @h, 1, 'one host' );
    is( $h[0]{active}, 1, 'normalised' );
    $r->wan;
    is( scalar( grep { $_ eq 'login' } @{ $n->{calls} } ), 1, 'it logs in once per handle' );
}
{
    my ( $r, $n ) = handle( cmrouter => wan => { ip => '1.1.1.1', link => 'Up', isp_status => 'Connected' } );
    $r->wan;
    ok( !grep( { $_ eq 'login' } @{ $n->{calls} } ), 'cmrouter reads without logging in (the home page is public)' );
    $r->reboot( confirm => 1 );
    my @c = @{ $n->{calls} };
    is( $c[-1], 'reboot', 'reboot reached the module' );
    is( $c[-2], 'login',  'and it logged in first' );
}
{
    my ( $r, $n ) = handle( cpbee => wan => { ip => '2.2.2.2' } );
    $r->wan;
    ok( !grep( { $_ eq 'login' } @{ $n->{calls} } ), 'cpbee never logs in' );
}

# ---- reboot is never done without confirm => 1
for my $name (qw(cmrouter vr180 cpbee)) {
    my ( $r, $n ) = handle($name);
    eval { $r->reboot };
    like( $@, qr/needs confirm => 1/, "$name: reboot without confirm refused" );
    eval { $r->reboot( confirm => 0 ) };
    like( $@, qr/needs confirm => 1/, "$name: confirm => 0 refused" );
    ok( !grep( { $_ eq 'reboot' } @{ $n->{calls} } ), "$name: the module was never asked to reboot" );
}

# ---- internet_up, uptime, clients
{
    my ( $r, $n ) = handle( cpbee => up => 1 );
    is( $r->internet_up, 1, 'internet_up' );
    $r->internet_up( probe => '1.1.1.1:443' );
    is_deeply( $n->{args}, [ probe => '1.1.1.1:443' ], 'the probe goes to cpbee' );
    my ( $v, $nv ) = handle( vr180 => up => 1 );
    $v->internet_up( probe => '1.1.1.1:443' );
    is_deeply( $nv->{args}, [], 'but not to a router that cannot use it' );
}
{
    my ($r) = handle( cmrouter => device => { uptime_secs => '90061.40' } );
    is( $r->uptime, 90061, 'uptime is whole seconds' );
    my ($u) = handle( cmrouter => device => {} );
    is( $u->uptime, undef, 'unknown uptime is undef' );
}
{
    my ($r) = handle(
        cpbee => hosts => [ { name => 'x', ip => '10.0.0.1', mac => 'aa:aa:aa:aa:aa:01', active => 1 },
                            { name => 'y', ip => '10.0.0.2', mac => 'aa:aa:aa:aa:aa:02', active => 0 } ] );
    is_deeply( [ $r->clients ], [ [ '10.0.0.1', 'aa:aa:aa:aa:aa:01', 'x' ] ], 'clients: active ones, [ip, mac, name]' );
    is( scalar( () = $r->hosts ), 2, 'hosts: all' );
    is( scalar( () = $r->hosts( active => 1 ) ), 1, 'hosts(active => 1)' );
}

# ---- a config file adds names; a login never goes in it
{
    my $f = "$Bin/router-op.conf.tmp";
    open( my $fh, '>', $f ) or die $!;
    print $fh "# my routers\nlab Router::DLink labdlink\nspare Router::Cpbee\n";
    close $fh;
    my $n = Router::Op->load_config($f);
    unlink $f;
    is( $n, 2, 'two routers added' );
    my ($r) = Router::Op->connect( lab => native => FakeNative->new );
    is( $r->host, 'labdlink', 'the host from the file' );
    ok( $r->supports('hosts') && !$r->supports('wifi'), 'it follows its class' );
    ok( ( grep { $_ eq 'lab' } Router::Op->names ), 'listed in names' );
    open( $fh, '>', $f ) or die $!;
    print $fh "bad nosuchclass\n";
    close $fh;
    eval { Router::Op->load_config($f) };
    unlink $f;
    like( $@, qr/unknown module 'nosuchclass'/, 'an unknown module in the file is refused' );
}
done_testing;
