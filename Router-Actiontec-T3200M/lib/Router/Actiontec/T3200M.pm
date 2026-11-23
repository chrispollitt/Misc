package Router::Actiontec::T3200M;

use strict;
use warnings;

our $VERSION = '0.01';

use Carp qw(croak);
use Math::BigInt;
use MIME::Base64 qw(encode_base64);

=head1 NAME

Router::Actiontec::T3200M - talk to the web UI of an Actiontec T3200M router

=head1 SYNOPSIS

    use Router::Actiontec::T3200M;

    # credentials from the LAN vault (`auth get https cmrouter --with-login`)
    my $r = Router::Actiontec::T3200M->new_from_vault(host => 'cmrouter');
    $r->login;

    for my $h ($r->hosts) {
        printf "%-20s %-15s %s\n", $h->{name}, $h->{ip}, $h->{mac};
    }
    my $wan = $r->wan;
    print "internet is ", ($r->internet_up ? "up" : "DOWN"), " ($wan->{ip})\n";

    $r->logout;

    # no login needed for the read-only status of the home page
    my $pub = Router::Actiontec::T3200M->new(host => 'cmrouter');
    my @clients = $pub->clients;            # [ip, mac, name] rows

=head1 DESCRIPTION

The T3200M (firmware 31.164L.22 tested) is the router Telus supplies. Its web UI
is small C<micro_httpd> pages that carry their data as JavaScript variables
(C<hostinfo>, C<wanEthStatus_*>, C<devinfo>). This module fetches those pages,
logs in the way the browser does, and parses the variables. It replaces the old
C<Router::Actiontec> that targeted an older Actiontec box.

The login is the router's own scheme: the password is encrypted with the RSA
public key embedded in the login page (PKCS#1 v1.5, e = 0x10001) and sent
base64-encoded in C<inputPassword> to C<login.cgi>. Only core Perl modules plus
LWP are needed (the RSA uses L<Math::BigInt>).

The password is never put on a command line, in a file, or in an error message.
C<new_from_vault> reads it from C<auth get https HOST --with-login> through a pipe.

=head1 CONSTRUCTORS

=head2 new(%args)

Arguments: C<host> (default C<cmrouter>), C<user>, C<password>, C<scheme>
(default C<http>), C<ua> (any object with C<get($url)> and C<post($url,\%form)>
returning L<HTTP::Response>; used by the tests), C<random> (code ref returning a
random byte 0..255, tests only), C<timeout> (seconds, default 15).
Credentials are only needed for C<login>.

=head2 new_from_vault(%args)

Like C<new>, but C<user> and C<password> come from the vault. Extra argument
C<auth_cmd> (array ref, default C<['auth']>) lets tests substitute a fake.

=cut

sub new {
    my ( $class, %a ) = @_;
    my $self = bless {
        host       => defined $a{host} ? $a{host} : 'cmrouter',
        scheme     => $a{scheme} || 'http',
        user       => $a{user},
        password   => $a{password},
        ua         => $a{ua},
        random     => $a{random},
        timeout    => $a{timeout} || 15,
        session_key => '0',
        logged_in  => 0,
    }, $class;
    $self->{ua} ||= $self->_default_ua;
    return $self;
}

sub new_from_vault {
    my ( $class, %a ) = @_;
    my $host = defined $a{host} ? $a{host} : 'cmrouter';
    my @cmd = @{ delete( $a{auth_cmd} ) || ['auth'] };
    my ( $user, $pass ) = _vault_login( $host, @cmd );
    return $class->new( %a, host => $host, user => $user, password => $pass );
}

# Run `auth get https HOST --with-login`; stdout is "LOGIN<TAB>SECRET".
# List-form open: no shell, nothing secret on any command line.
sub _vault_login {
    my ( $host, @cmd ) = @_;
    my $pid = open( my $fh, '-|' ) // croak "cannot fork: $!";
    if ( !$pid ) {
        open( STDERR, '>&', \*STDOUT ) or exit 127;
        exec( @cmd, 'get', 'https', $host, '--with-login' ) or exit 127;
    }
    my $line = <$fh>;
    my @rest = <$fh>;
    close($fh);
    my $status = $?;
    if ( $status != 0 ) {
        # on failure the output is auth's own message, not a secret
        my $msg = join( '', grep { defined } $line, @rest );
        $msg =~ s/\s+\z//;
        croak "vault lookup for https $host failed (exit " . ( $status >> 8 ) . "): $msg"
          . "\nadd it with: auth set https\@$host LOGIN";
    }
    # on success the output IS the secret: never quote it
    croak "vault lookup for https $host gave no LOGIN<TAB>SECRET line"
      if !defined $line || $line !~ /\t/;
    $line =~ s/\r?\n\z//;
    my ( $user, $secret ) = split( /\t/, $line, 2 );
    return ( $user, $secret );
}

sub _default_ua {
    my ($self) = @_;
    require LWP::UserAgent;
    require HTTP::Cookies;
    my $ua = LWP::UserAgent->new(
        agent      => "Router-Actiontec-T3200M/$VERSION",
        cookie_jar => HTTP::Cookies->new,
        timeout    => $self->{timeout},
        keep_alive => 1,
    );
    $ua->requests_redirectable( [qw(GET HEAD POST)] );
    return $ua;
}

sub _url {
    my ( $self, $path ) = @_;
    $path =~ s{^/+}{};
    return "$self->{scheme}://$self->{host}/$path";
}

# GET a page; croaks on HTTP failure. Returns the HTTP::Response.
sub _get {
    my ( $self, $path ) = @_;
    my $res = $self->{ua}->get( $self->_url($path) );
    croak "GET $path from $self->{host} failed: " . $res->status_line
      unless $res->is_success;
    return $res;
}

=head1 LOGIN

=head2 login

Fetches the login page, encrypts the password, posts C<login.cgi> and checks
that the router now reports a logged-in user. Croaks on failure (wrong
password, router locked out, no credentials). Returns the object.

=head2 logout

Ends the session (C<logout.cgi>). Harmless if not logged in. Called from
C<DESTROY> when logged in.

=cut

sub login {
    my ($self) = @_;
    croak "login needs user and password (use new_from_vault)"
      unless defined $self->{user} && defined $self->{password};

    my $page = $self->_get('/')->decoded_content;
    my $key  = parse_rsa_key($page)
      or croak "no RSA key on the login page of $self->{host}"
      . " (not a T3200M, or the firmware changed)";
    my $skey = _js_var( $page, 'sessionKey' );
    $self->{session_key} = defined $skey && length $skey ? $skey : '0';

    my $cipher = rsa_encrypt_pkcs1( @$key{qw(n e)}, $self->{password},
        $self->{random} );
    my $session_id = 1 + int( rand(799_999_999) );

    my $res = $self->{ua}->post(
        $self->_url('login.cgi'),
        {
            sessionKey    => $self->{session_key},
            inputUserName => $self->{user},
            inputPassword => encode_base64( $cipher, '' ),
            sessionId     => $session_id,
        }
    );
    croak "POST login.cgi to $self->{host} failed: " . $res->status_line
      unless $res->is_success;

    my $home = $self->_get('/')->decoded_content;
    my $who  = _js_var( $home, 'loginUserName' );
    if ( !defined $who || $who eq '' ) {
        my $locked = _js_var( $home, 'rootGuiLocked' );
        croak "login to $self->{host} refused"
          . ( $locked ? " (router reports the GUI is locked after failed logins)" : " (wrong login?)" );
    }
    my $k = _js_var( $home, 'sessionKey' );
    $self->{session_key} = $k if defined $k && length $k;
    $self->{logged_in}   = 1;
    $self->{login_user}  = $who;
    return $self;
}

sub logged_in { $_[0]{logged_in} ? 1 : 0 }

sub logout {
    my ($self) = @_;
    return $self unless $self->{logged_in};
    $self->{logged_in} = 0;
    eval { $self->{ua}->get( $self->_url("logout.cgi?sessionKey=$self->{session_key}") ) };
    return $self;
}

sub DESTROY {
    my ($self) = @_;
    local ( $@, $! );
    $self->logout if $self->{logged_in} && $self->{ua};
}

=head1 READ-ONLY STATUS

All of these read the home page (C</>), which the router serves with the data
embedded, logged in or not. Each call fetches fresh data.

=head2 home

Returns the parsed home page: a hash ref with keys C<hosts>, C<wan>, C<device>,
C<login_user>, C<session_key>. See C<parse_home> below.

=head2 hosts

List of hash refs, one per LAN client the router knows: C<name>, C<ip>, C<mac>
(lower case), C<medium> (C<Ethernet> or C<802.11>), C<addressing> (C<DHCP> or
C<Static>), C<active> (1 if connected now). Pass C<< active => 1 >> to drop
clients that are not connected.

=head2 clients

What C<GetHosts.pm> wants: C<[ip, mac, name]> array refs of the active clients.

=head2 wan

Hash ref: C<link> (Up/Down), C<isp_status> (Connected/...), C<mac>, C<ip>,
C<netmask>, C<gateway>, C<dns> (array ref), C<lease_secs>, C<protocol>,
C<addressing>.

=head2 internet_up

True when the WAN link is up, the ISP side is connected, and the router holds a
WAN address. It does not probe the Internet beyond the router.

=head2 device

Hash ref: C<model>, C<serial>, C<firmware>, C<uptime_secs>, C<hardware>.

=cut

sub home {
    my ($self) = @_;
    return parse_home( $self->_get('/')->decoded_content );
}

sub hosts {
    my ( $self, %o ) = @_;
    my @h = @{ $self->home->{hosts} };
    @h = grep { $_->{active} } @h if $o{active};
    return @h;
}

sub clients {
    my ($self) = @_;
    return map { [ @$_{qw(ip mac name)} ] } $self->hosts( active => 1 );
}

sub wan    { $_[0]->home->{wan} }
sub device { $_[0]->home->{device} }

sub internet_up {
    my ($self) = @_;
    my $w = $self->wan;
    return ( ( $w->{link} // '' ) eq 'Up'
          && ( $w->{isp_status} // '' ) eq 'Connected'
          && ( $w->{ip} // '' ) =~ /^\d+\.\d+\.\d+\.\d+$/ ) ? 1 : 0;
}

=head1 PARSING AND CRYPTO (usable without a router)

=head2 parse_home($html)

Parses a home page into C<{hosts, wan, device, login_user, session_key}>.
Croaks if the page has none of the expected variables.

=head2 parse_rsa_key($html)

Returns C<{n =E<gt> hex, e =E<gt> hex}> from C<new RSAKeyPair(...)> in the login
page, or undef.

=head2 rsa_encrypt_pkcs1($n_hex, $e_hex, $plaintext [, $random_cb])

RSA PKCS#1 v1.5 encryption (block type 2) as the router's JavaScript does it.
Returns the raw ciphertext bytes (as long as the modulus).

=cut

sub parse_home {
    my ($html) = @_;
    my $hostinfo = _js_var( $html, 'hostinfo' );
    my $devinfo  = _js_var( $html, 'devinfo' );
    my $link     = _js_var( $html, 'wanEthStatus_LinkStatus' );
    croak "page has no router status variables (login page only, or not a T3200M)"
      unless defined $hostinfo || defined $devinfo || defined $link;

    my @hosts;
    for my $e ( split /\|/, defined $hostinfo ? $hostinfo : '' ) {
        my ( $name, $ip, $mac, $medium, $addr, $active ) = split( m{/}, $e, -1 );
        next unless defined $ip && length $ip;
        push @hosts,
          {
            name       => $name,
            ip         => $ip,
            mac        => lc( $mac // '' ),
            medium     => $medium,
            addressing => $addr,
            active     => ( defined $active && $active eq '1' ) ? 1 : 0,
          };
    }

    my $v = sub { my $x = _js_var( $html, $_[0] ); defined $x ? $x : '' };
    my %wan = (
        link       => $v->('wanEthStatus_LinkStatus'),
        isp_status => $v->('wanEthStatus_ISPStatus'),
        mac        => lc $v->('wanEthStatus_MACAddress'),
        ip         => $v->('wanEthStatus_IPAddress'),
        netmask    => $v->('wanEthStatus_SubnetMask'),
        gateway    => $v->('wanEthStatus_DefaultGateway'),
        lease_secs => $v->('wanEthStatus_LeaseTimeRemaining'),
        dns        => [ grep { length } split( /\s*,\s*/, $v->('wanEthStatus_DNSServer') ) ],
        protocol   => $v->('wanEthStatus_Portocol'),    # sic (the router's spelling)
        addressing => $v->('wanEthStatus_AddressingType'),
    );

    my @d = split( /\|/, defined $devinfo ? $devinfo : '', -1 );
    my %dev = (
        model        => $d[0],
        serial       => $d[1],
        firmware     => $d[2],
        uptime_secs  => $d[3],
        hardware     => $d[4],
    );

    return {
        hosts       => \@hosts,
        wan         => \%wan,
        device      => \%dev,
        login_user  => $v->('loginUserName'),
        session_key => $v->('sessionKey'),
    };
}

sub parse_rsa_key {
    my ($html) = @_;
    return unless $html =~ /new\s+RSAKeyPair\(\s*"([0-9A-Fa-f]+)"\s*,\s*"[0-9A-Fa-f]+"\s*,\s*"([0-9A-Fa-f]+)"/;
    return { e => $1, n => $2 };
}

# The value of `var NAME = 'x'` / `htmlDecodeStr("x")` in the page JavaScript,
# HTML-decoded as the router's htmlDecodeStr does. undef if NAME is not there.
sub _js_var {
    my ( $html, $name ) = @_;
    return unless $html =~ /\bvar\s+\Q$name\E\s*=\s*(?:htmlDecodeStr\(\s*)?(['"])(.*?)\1/s;
    my $s = $2;
    $s =~ s/&#(\d{1,3});/chr($1)/ge;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&amp;/&/g;
    return $s;
}

sub rsa_encrypt_pkcs1 {
    my ( $n_hex, $e_hex, $plain, $rand ) = @_;
    $n_hex =~ s/^0+//;
    $n_hex = "0$n_hex" if length($n_hex) % 2;
    my $k = length($n_hex) / 2;    # modulus length in bytes
    croak "message too long for the RSA key" if length($plain) > $k - 11;
    croak "password must be bytes, not wide characters" if $plain =~ /[^\x00-\xff]/;

    $rand ||= sub { _random_byte() };
    my $ps = '';
    while ( length($ps) < $k - 3 - length($plain) ) {
        my $b = $rand->() & 0xff;
        $ps .= chr($b) if $b;
    }
    my $em = "\x00\x02" . $ps . "\x00" . $plain;

    my $m = Math::BigInt->from_hex( '0x' . unpack( 'H*', $em ) );
    my $c = $m->bmodpow( Math::BigInt->from_hex("0x$e_hex"), Math::BigInt->from_hex("0x$n_hex") );
    my $hex = substr( $c->as_hex, 2 );
    $hex = ( '0' x ( 2 * $k - length $hex ) ) . $hex;
    return pack( 'H*', $hex );
}

{
    my $fh;

    sub _random_byte {
        if ( !defined $fh ) {
            my $f;
            $fh = open( $f, '<:raw', '/dev/urandom' ) ? $f : 0;
        }
        if ($fh) {
            my $byte;
            return ord($byte) if read( $fh, $byte, 1 );
        }
        return int( rand(256) );
    }
}

=head1 REBOOT

=head2 reboot(confirm => 1)

Reboots the router. Refuses unless called with C<< confirm => 1 >> and logged
in. The router's own Reboot button (C<utilities_reboot.html>) does a plain
authenticated C<GET rebootinfo.html> after a JavaScript confirm; this does the
same. The router drops the connection while it goes down, so a transport error
after the request is treated as success; an HTTP 401/403 or a login page is an
error. The session is gone afterwards (C<logged_in> becomes false).

B<Not exercised against the real router>: the flow was read from the router's
own page, but nobody has rebooted the live box from this module yet.

=head2 wait_until_up(timeout =E<gt> 240, interval =E<gt> 5)

Polls the home page until the router answers again. True when it did, false on
timeout. Typical use: C<< $r->reboot(confirm => 1); sleep 20; $r->wait_until_up >>.

=cut

sub reboot {
    my ( $self, %o ) = @_;
    croak "reboot needs confirm => 1" unless defined $o{confirm} && $o{confirm} eq '1';
    croak "reboot needs a logged-in session (call login first)" unless $self->{logged_in};
    my $res = $self->{ua}->get( $self->_url('rebootinfo.html') );
    if ( $res->code == 401 || $res->code == 403
        || ( $res->is_success && $res->decoded_content =~ /name="inputPassword"/ ) )
    {
        croak "router $self->{host} refused the reboot request: " . $res->status_line;
    }
    $self->{logged_in} = 0;
    return 1;
}

sub wait_until_up {
    my ( $self, %o ) = @_;
    my $deadline = time + ( $o{timeout} || 240 );
    my $interval = $o{interval} || 5;
    while (1) {
        my $ok = eval { $self->home; 1 };
        return 1 if $ok;
        return 0 if time >= $deadline;
        sleep $interval;
    }
}

=head1 AUTHOR

Chris Pollitt. Part of the Misc repository.

=cut

1;
