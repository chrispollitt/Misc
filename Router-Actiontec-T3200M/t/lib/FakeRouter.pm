package FakeRouter;

# A fake LWP-like user agent that plays the router: serves t/data/home.tmpl,
# accepts login.cgi only for the right user and (RSA-decrypted) password, and
# records every request. No network, no real router.

use strict;
use warnings;
use HTTP::Response;
use MIME::Base64 qw(decode_base64);
use Math::BigInt;
use File::Basename qw(dirname);

my $DATA = dirname(__FILE__) . '/../data';

sub slurp { open( my $f, '<', $_[0] ) or die "$_[0]: $!"; local $/; my $s = <$f>; $s =~ s/\s+\z//; $s }
sub modulus { slurp("$DATA/testkey.n") }
sub privexp { slurp("$DATA/testkey.d") }

sub new {
    my ( $class, %a ) = @_;
    return bless {
        user     => 'admin',
        password => 'hunter2',
        link     => 'Up',
        isp      => 'Connected',
        locked   => 0,
        sessions => 0,
        log      => [],
        %a,
    }, $class;
}

sub log_of { @{ $_[0]{log} } }

sub page {
    my ($self) = @_;
    my $t = slurp("$DATA/home.tmpl");
    my %v = (
        LINK       => $self->{link},
        ISP        => $self->{isp},
        USER       => $self->{sessions} ? $self->{user} : '',
        LOCKED     => $self->{locked} ? 1 : 0,
        SESSIONKEY => $self->{sessions} ? '812345678' : '0',
        MODULUS    => modulus(),
    );
    $t =~ s/\@\@(\w+)\@\@/$v{$1}/g;
    return $t;
}

sub _ok { my ( $s, $body ) = @_; my $r = HTTP::Response->new( 200, 'OK' ); $r->content_type('text/html'); $r->content($body); $r }

sub get {
    my ( $self, $url ) = @_;
    push @{ $self->{log} }, "GET $url";
    return $self->_ok( $self->page )         if $url =~ m{^http://[^/]+/$};
    if ( $url =~ m{/logout\.cgi\?sessionKey=(\d+)$} ) {
        $self->{sessions} = 0;
        return $self->_ok('bye');
    }
    if ( $url =~ m{/rebootinfo\.html$} ) {
        return HTTP::Response->new( 403, 'Forbidden' ) unless $self->{sessions};
        $self->{rebooted}++;
        return $self->_ok('<html>rebooting</html>');
    }
    return HTTP::Response->new( 404, 'Not Found' );
}

sub post {
    my ( $self, $url, $form ) = @_;
    push @{ $self->{log} }, "POST $url";
    return HTTP::Response->new( 404, 'Not Found' ) unless $url =~ m{/login\.cgi$};
    $self->{last_form} = {%$form};

    my $cipher = decode_base64( $form->{inputPassword} // '' );
    my $c      = Math::BigInt->from_hex( '0x' . unpack( 'H*', $cipher ) );
    my $m      = $c->bmodpow( Math::BigInt->from_hex( '0x' . privexp() ), Math::BigInt->from_hex( '0x' . modulus() ) );
    my $hex    = substr( $m->as_hex, 2 );
    my $k      = length( modulus() ) / 2;
    $hex = ( '0' x ( 2 * $k - length $hex ) ) . $hex;
    my $em = pack( 'H*', $hex );
    my ($plain) = $em =~ /\A\x00\x02[^\x00]{8,}\x00(.*)\z/s;
    $self->{last_plain_len} = defined $plain ? length $plain : undef;

    if ( ( $form->{inputUserName} // '' ) eq $self->{user}
        && defined $plain && $plain eq $self->{password} )
    {
        $self->{sessions} = 1;
    }
    return $self->_ok('<html>redirecting</html>');
}

1;
