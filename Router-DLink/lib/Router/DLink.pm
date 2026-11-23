package Router::DLink;

use strict;
use warnings;

our $VERSION = '0.02';

use Carp qw(croak);
use Digest::MD5 qw(md5_hex);

=head1 NAME

Router::DLink - talk to the web UI of a D-Link DIR-655 style wireless router

=head1 SYNOPSIS

    use Router::DLink;

    # credentials from the LAN vault (`auth get https vr180 --with-login`)
    my $r = Router::DLink->new_from_vault(host => 'vr180');
    $r->login;

    my $wan = $r->wan;
    print "internet is ", ($r->internet_up ? "up" : "DOWN"), " ($wan->{ip})\n";
    printf "%-15s %-17s %s\n", @$_ for $r->clients;       # [ip, mac, name]

    $r->logout;

    # reboot (asks for nothing: the caller must say confirm => 1)
    $r->reboot(confirm => 1);
    $r->wait_until_up;

=head1 DESCRIPTION

Tested against the D-Link DIR-655 hardware A3, firmware 1.37 (web server
C<Ubicom/1.1>, page title "D-LINK SYSTEMS, INC. | WIRELESS ROUTER"). It
replaces the 2018 C<Router::DLink> of the same name; the package name and the
C<new>, C<login>, C<logout>, C<get_wan_data>, C<get_lan_data>, C<reboot> calls
still work, and the API now matches L<Router::Actiontec::T3200M> (C<wan>,
C<hosts>, C<clients>, C<internet_up>, C<reboot(confirm =E<gt> 1)>,
C<wait_until_up>, C<new_from_vault>) so the routers can share one command.

The login is the router's own scheme, done in its JavaScript: the login page
carries a C<salt>; the browser sends the salt followed by the MD5 of: the salt,
the secret padded to 16 bytes with \x01, all padded to 63 bytes with \x01, then
C<U> for the C<user> login or \x01 for C<admin>; the request is C</post_login.xml>.
The secret never travels in clear. Only core Perl plus LWP is needed.

If the router has "graphical authentication" (a picture code) switched on,
login croaks: a script cannot read the picture. Turn it off in the router.

The password is never put on a command line, in a file or in an error message.
C<new_from_vault> reads it from C<auth get https HOST --with-login> through a pipe.

=head1 CONSTRUCTORS

=head2 new(%args)

Arguments: C<host> (default C<vr180>), C<user> (C<admin> or C<user>, default
C<admin>), C<password>, C<scheme> (default C<http>), C<ua> (any object with
C<get($url)> returning L<HTTP::Response>; used by the tests), C<timeout>
(seconds, default 15). Old style C<< new($host, $password) >> also works.
Credentials are only needed for C<login>.

=head2 new_from_vault(%args)

Like C<new>, but C<user> and C<password> come from the vault. Extra argument
C<auth_cmd> (array ref, default C<['auth']>) lets tests substitute a fake.

=cut

sub new {
    my $class = shift;
    my %a = @_ == 2 && $_[0] !~ /^(?:host|user|password|scheme|ua|timeout)$/
      ? ( host => $_[0], password => $_[1] )    # 2018 style: new($ip, $passwd)
      : @_;
    my $self = bless {
        host      => defined $a{host} ? $a{host} : 'vr180',
        scheme    => $a{scheme} || 'http',
        user      => defined $a{user} ? lc $a{user} : 'admin',
        password  => $a{password},
        ua        => $a{ua},
        timeout   => $a{timeout} || 15,
        logged_in => 0,
    }, $class;
    $self->{ua} ||= $self->_default_ua;
    return $self;
}

sub new_from_vault {
    my ( $class, %a ) = @_;
    my $host = defined $a{host} ? $a{host} : 'vr180';
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
        agent      => "Router-DLink/$VERSION",
        cookie_jar => HTTP::Cookies->new,
        timeout    => $self->{timeout},
    );
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

Fetches the login page, computes the hash, requests C</post_login.xml> and
checks that the router now serves data pages. Croaks on a wrong password,
a session timeout, a graphical-code router or no credentials. Returns the
object.

=head2 logged_in

True after a successful C<login> until C<logout> or C<reboot>.

=head2 logout

Ends the session (C</logout.cgi>). Harmless if not logged in. Called from
C<DESTROY> when logged in.

=cut

sub login {
    my ($self) = @_;
    croak "login needs user and password (use new_from_vault)"
      unless defined $self->{user} && defined $self->{password};
    croak "the D-Link logins are 'admin' and 'user', not '$self->{user}'"
      unless $self->{user} =~ /^(?:admin|user)$/;

    my $page = $self->_get('/')->decoded_content;
    my $p    = parse_login_page($page)
      or croak "no salt on the login page of $self->{host}"
      . " (already logged in from this address, or not a D-Link DIR-655 / firmware changed)";
    croak "router $self->{host} wants a graphical authentication code;"
      . " switch that off in the router (Tools > Admin) so scripts can log in"
      if $p->{graphic_auth};

    my $hash = login_hash( $p->{salt}, $self->{password}, $self->{user} );
    my $res  = $self->_get( "post_login.xml?hash=$hash&auth_code=&auth_id=$p->{auth_id}" );
    my $st   = xml_value( $res->decoded_content, 'login' );

    if ( defined $st ) {
        croak "login to $self->{host} refused: wrong login or password" if $st eq 'error';
        croak "login to $self->{host}: the login page timed out, try again" if $st eq 'timeout';
        croak "login to $self->{host} wants the graphical authentication code" if $st eq 'auth_error';
    }
    $self->{login_target} = $st;

    # prove it: a data page must now be served, not the login/redirect page
    my $probe = $self->_get('wan_connection_status.xml')->decoded_content;
    croak "login to $self->{host} did not give access (the router still shows its login page)"
      if is_login_page($probe);
    $self->{logged_in} = 1;
    return $self;
}

sub logged_in { $_[0]{logged_in} ? 1 : 0 }

sub logout {
    my ( $self, $skip ) = @_;
    return $self unless $self->{logged_in};
    $self->{logged_in} = 0;
    eval { $self->{ua}->get( $self->_url('logout.cgi') ) } unless $skip;
    return $self;
}

sub DESTROY {
    my ($self) = @_;
    local ( $@, $! );
    $self->logout if $self->{logged_in} && $self->{ua};
}

=head1 PARSING AND HASHING (usable without a router)

=head2 login_hash($salt, $password, $user)

The string the login page's C<send_login()> builds: the salt followed by the
MD5 of the padded input. C<$user> is C<admin> (default) or C<user>.

=head2 parse_login_page($html)

Returns C<{salt, auth_id, graphic_auth}> from the login page, or undef when
the page has no salt (a data page, or not a D-Link).

=head2 is_login_page($html)

True for the router's login page or its "You will now be redirected to the
login page" stub, which it serves for every page while you are not logged in.

=head2 xml_value($xml, $tag)

The text of the first C<E<lt>tagE<gt>> or undef.

=head2 parse_wan($xml), parse_clients($xml)

See C<wan> and C<hosts>.

=cut

sub login_hash {
    my ( $salt, $password, $user ) = @_;
    $user = 'admin' unless defined $user;
    $password = substr( $password, 0, 16 );
    $password .= "\x01" x ( 16 - length $password );
    my $in = $salt . $password;
    $in .= "\x01" x ( 63 - length $in ) if length $in < 63;
    $in .= $user eq 'user' ? 'U' : "\x01";
    return $salt . md5_hex($in);
}

sub parse_login_page {
    my ($html) = @_;
    return unless $html =~ /\bvar\s+salt\s*=\s*"([0-9A-Za-z]+)"/;
    my $salt = $1;
    my ($id) = $html =~ /auth_id=([0-9A-Za-z]+)/;
    my ($ga) = $html =~ /\bvar\s+graphic_auth\s*=\s*"(\w+)"/;
    return {
        salt         => $salt,
        auth_id      => defined $id ? $id : '',
        graphic_auth => ( defined $ga && $ga eq 'true' ) ? 1 : 0,
    };
}

sub is_login_page {
    my ($html) = @_;
    return 1 if $html =~ /redirected to the login page/i;
    return 1 if $html =~ /\bvar\s+salt\s*=\s*"/ && $html =~ /post_login\.xml/;
    return 0;
}

sub xml_value {
    my ( $xml, $tag ) = @_;
    return unless defined $xml && $xml =~ m{<\Q$tag\E>\s*([^<]*?)\s*</\Q$tag\E>};
    return _unxml($1);
}

sub _unxml {
    my ($s) = @_;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&amp;/&/g;
    return $s;
}

=head1 READ-ONLY STATUS

These need a login; the router answers every data page with its login page
otherwise. Each call fetches fresh data.

=head2 wan

Hash ref from C</wan_connection_status.xml> and C</wan_lan_status.xml>:
C<ip>, C<netmask>, C<gateway>, C<dns> (array ref, primary first, no
C<0.0.0.0>), C<connection_state> (0 disconnected, 1 connecting, 2 connected,
3 disconnecting) and C<state> (its name), C<up_secs>, C<link> (the physical
WAN port, C<Connected> or C<Disconnected>), C<lan_ip>, C<lan_netmask>.
Croaks if the router reports no WAN address field at all.

Note: a router with nothing plugged into its WAN port (an access point or
switch behind another router) still reports placeholder addresses; look at
C<state> / C<link>, not just C<ip>.

=head2 internet_up

True when the router's WAN connection state is "connected" (2) and it holds a
WAN address. It does not probe the Internet beyond the router; any failure
makes it false rather than croak.

=head2 device

Hash ref from the Device Info page: C<model> (C<DIR-655>), C<hardware>
(C<A3>), C<firmware> (C<1.37>), C<uptime_secs>.

=head2 hosts

List of hash refs, one per DHCP client the router lists
(C</dhcp_clients.xml>): C<name>, C<ip>, C<mac> (lower case), C<seconds_remaining>
(lease; 4294967295 means for ever), C<is_reservation>, C<learned_by>. Static
and wireless-only clients are not in this list; it is the DHCP lease table.

=head2 clients

What C<GetHosts.pm> wants: C<[ip, mac, name]> array refs.

=head2 get_wan_data, get_lan_data

2018 API kept for old callers: C<{IP, GWAY, DNS}> and C<{CLIENTS =E<gt> [[ip, mac, name], ...]}>.

=cut

sub _data {
    my ( $self, $path ) = @_;
    croak "not logged in (call login first)" unless $self->{logged_in};
    my $x = $self->_get($path)->decoded_content;
    croak "router $self->{host} sent its login page for $path (session lost?)"
      if is_login_page($x);
    return $x;
}

sub wan {
    my ($self) = @_;
    my $w = parse_wan( $self->_data('wan_connection_status.xml') );
    croak "unable to get wan data (no WAN address reported)" unless defined $w->{ip};
    my $l = $self->_data('wan_lan_status.xml');
    $w->{link}        = xml_value( $l, 'wan_physical_state' );
    $w->{lan_ip}      = xml_value( $l, 'lan_ip_address' );
    $w->{lan_netmask} = xml_value( $l, 'lan_subnet' );
    return $w;
}

sub internet_up {
    my ($self) = @_;
    my $w = eval { $self->wan };
    return ( $w && ( $w->{connection_state} // -1 ) == 2
          && ( $w->{ip} // '' ) =~ /^\d+\.\d+\.\d+\.\d+$/ && $w->{ip} ne '0.0.0.0' ) ? 1 : 0;
}

sub device {
    my ($self) = @_;
    return parse_device( $self->_data('Status/Device_Info.shtml') );
}

# the Device Info page: model, hardware, firmware, uptime
sub parse_device {
    my ($html) = @_;
    my %d;
    ( $d{model} )    = $html =~ m{Product Page:\s*<a[^>]*>\s*([^<]+?)\s*</a>};
    ( $d{hardware} ) = $html =~ m{Hardware Version:\s*(\S+)\s*</div>};
    my ($minor) = $html =~ /global_fw_minor_version\s*=\s*"(\d+)"/;
    my ($ext)   = $html =~ /fw_extend_ver\s*=\s*"(\w+)"/;
    $d{firmware} = '1.' . sprintf( '%02d', $minor ) . ( defined $ext && $ext ne 'NA' ? $ext : '' ) if defined $minor;
    ( $d{uptime_secs} ) = $html =~ /system_uptime_secs\s*=\s*"(\d+)"/;
    croak "page has no device information (not logged in, or not a D-Link DIR-655)"
      unless defined $d{model} || defined $d{firmware} || defined $d{uptime_secs};
    return \%d;
}

sub hosts {
    my ($self) = @_;
    return parse_clients( $self->_data('dhcp_clients.xml') );
}

sub clients {
    my ($self) = @_;
    return map { [ @$_{qw(ip mac name)} ] } $self->hosts;
}

sub get_wan_data {
    my ($self) = @_;
    my $w = $self->wan;
    return { IP => $w->{ip}, GWAY => $w->{gateway}, DNS => $w->{dns}[0] };
}

sub get_lan_data {
    my ($self) = @_;
    my @c = $self->clients;
    croak "unable to get lan data" unless @c;
    return { CLIENTS => \@c };
}

# <wan_ip_address_0>1.2.3.4</wan_ip_address_0> ... -> {ip, gateway, dns[], ...}
sub parse_wan {
    my ($xml) = @_;
    my %w;
    while ( $xml =~ m{<(\w+?)_0>\s*([^<]*?)\s*</\1_0>}g ) {
        my ( $k, $v ) = ( $1, _unxml($2) );
        $k =~ s/^wan_//;
        $w{$k} = $v;
    }
    my %alias = (
        ip_address    => 'ip',
        primary_dns   => 'dns1',
        secondary_dns => 'dns2',
        subnet        => 'netmask',
    );
    my %o = %w;
    for my $k ( keys %alias ) {
        $o{ $alias{$k} } = delete $o{$k} if exists $o{$k};
    }
    my %seen;
    $o{dns} = [ grep { defined && length && $_ ne '0.0.0.0' && !$seen{$_}++ } delete @o{qw(dns1 dns2)} ];
    $o{up_secs} = delete $o{interface_up_time} if exists $o{interface_up_time};
    if ( defined $o{connection_state} ) {
        $o{state} = { -1 => 'N/A', 0 => 'Disconnected', 1 => 'Connecting', 2 => 'Connected', 3 => 'Disconnecting' }
          ->{ $o{connection_state} } // 'unknown';
    }
    return \%o;
}

sub parse_clients {
    my ($xml) = @_;
    my @out;
    while ( $xml =~ m{<client>(.*?)</client>}gs ) {
        my $body = $1;
        my %f;
        $f{$1} = _unxml($2) while $body =~ m{<(\w+)>\s*([^<]*?)\s*</\1>}g;
        my %h = (
            name => $f{host_name} // '',
            ip   => $f{ip_address} // '',
            mac  => lc( $f{mac} // '' ),
        );
        for my $k ( grep { !/^(?:host_name|ip_address|mac)$/ } keys %f ) { $h{$k} = $f{$k} }
        push @out, \%h;
    }
    return @out;
}

=head1 REBOOT

=head2 reboot(confirm => 1)

Reboots the router. Refuses unless called with C<< confirm => 1 >> and logged
in. It does what the router's own "Reboot Now" button does: a GET of
C</reboot.cgi?reset=false> (C<reset=false> keeps the settings). The router
drops the connection while it goes down, so a transport error after the
request counts as success; a login page is an error. The session is gone
afterwards (C<logged_in> becomes false).

Tested live on a DIR-655 (fw 1.37): it came back in about 40 seconds.

=head2 wait_until_up(timeout =E<gt> 240, interval =E<gt> 5)

Polls the login page until the router answers again. True when it did, false
on timeout. Typical use: C<< $r->reboot(confirm => 1); sleep 15; $r->wait_until_up >>.

=cut

sub reboot {
    my ( $self, %o ) = @_;
    croak "reboot needs confirm => 1" unless defined $o{confirm} && $o{confirm} eq '1';
    croak "reboot needs a logged-in session (call login first)" unless $self->{logged_in};
    my $res = $self->{ua}->get( $self->_url('reboot.cgi?reset=false') );
    if ( $res->code == 401 || $res->code == 403
        || ( $res->is_success && is_login_page( $res->decoded_content ) ) )
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
        my $ok = eval { parse_login_page( $self->_get('/')->decoded_content ) ? 1 : 0 };
        return 1 if $ok;
        return 0 if time >= $deadline;
        sleep $interval;
    }
}

=head1 AUTHOR

Chris Pollitt. Part of the Misc repository.

=cut

1;
