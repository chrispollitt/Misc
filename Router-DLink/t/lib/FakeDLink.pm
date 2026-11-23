package FakeDLink;

# A fake LWP-like user agent that plays the D-Link: serves t/data/login.html,
# accepts post_login.xml only for the right login hash (golden values made by
# the router's own md5.js, not by our code), serves data pages only while
# logged in, and records every request. No network, no real router.

use strict;
use warnings;
use HTTP::Response;
use File::Basename qw(dirname);

my $DATA = dirname(__FILE__) . '/../data';

# salt f18d5ff9 + the test secret hunter2, produced by running the router's md5.js
our %GOLDEN = (
    admin => 'f18d5ff9efd9b84ce4e55896bb0abf719109a5c2',
    user  => 'f18d5ff92be0a7ec2e59ab43503e6ef3bae4c55e',
);

sub slurp { open( my $f, '<', $_[0] ) or die "$_[0]: $!"; local $/; <$f> }

sub new {
    my ( $class, %a ) = @_;
    return bless {
        user     => 'admin',
        graphic  => 0,
        session  => 0,
        log      => [],
        post_login => undef,    # override the <login> answer (error, timeout, ...)
        %a,
    }, $class;
}

sub log_of { @{ $_[0]{log} } }

sub _ok {
    my ( $s, $body, $type ) = @_;
    my $r = HTTP::Response->new( 200, 'OK' );
    $r->content_type( $type || 'text/html' );
    $r->content($body);
    return $r;
}

sub login_page {
    my ($self) = @_;
    my $t = slurp("$DATA/login.html");
    $t =~ s/var graphic_auth = "false";/var graphic_auth = "true";/ if $self->{graphic};
    return $t;
}

sub get {
    my ( $self, $url ) = @_;
    push @{ $self->{log} }, "GET $url";
    $url =~ m{^http://[^/]+/(.*)$} or return HTTP::Response->new( 400, 'Bad' );
    my $path = $1;

    return $self->_ok( $self->login_page ) if $path eq '';

    if ( $path =~ m{^post_login\.xml\?hash=([0-9a-f]+)&auth_code=([^&]*)&auth_id=(\w*)$} ) {
        $self->{last_hash} = $1;
        $self->{last_auth_id} = $3;
        my $answer = $self->{post_login};
        if ( !defined $answer ) {
            $answer = ( $1 eq $GOLDEN{ $self->{user} } ) ? 'st_device.html' : 'error';
        }
        $self->{session} = 1 if $answer !~ /^(?:error|timeout|auth_error)$/;
        return $self->_ok( "<?xml version=\"1.0\"?><root><login>$answer</login></root>", 'text/xml' );
    }
    if ( $path eq 'logout.cgi' ) {
        $self->{session} = 0;
        return $self->_ok('bye');
    }
    if ( $path eq 'reboot.cgi?reset=false' ) {
        return $self->_ok( slurp("$DATA/redirect.html") ) unless $self->{session};
        $self->{rebooted}++;
        $self->{session} = 0;
        return $self->_ok('<html>rebooting</html>');
    }
    my $dn = $self->{wan_down} ? '_down' : '';
    my %page = (
        'wan_connection_status.xml'  => "wan$dn.xml",
        'wan_lan_status.xml'         => "lan_status$dn.xml",
        'dhcp_clients.xml'           => 'dhcp.xml',
        'Status/Device_Info.shtml'   => 'device_info.html',
    );
    if ( my $f = $page{$path} ) {
        return $self->_ok( slurp("$DATA/redirect.html") ) unless $self->{session};
        return $self->_ok( slurp("$DATA/$f"), 'text/xml' );
    }
    return HTTP::Response->new( 404, 'Not Found' );
}

1;
