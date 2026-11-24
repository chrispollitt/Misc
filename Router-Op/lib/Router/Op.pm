package Router::Op;

use strict;
use warnings;

our $VERSION = '0.01';

use Carp qw(croak);
use File::Spec ();

# the three router modules live in sibling directories of the Misc repo; find them, so a caller needs one `use lib` only
BEGIN {
    my ( $vol, $dir ) = File::Spec->splitpath( File::Spec->rel2abs(__FILE__) );
    my @d = File::Spec->splitdir($dir);
    pop @d while @d && !length $d[-1];
    splice @d, -2;                                  # .../Router-Op/lib/Router -> .../Router-Op
    my $misc = File::Spec->catpath( $vol, File::Spec->catdir( @d[ 0 .. $#d - 1 ] ), '' );
    for my $m (qw(Router-Actiontec-T3200M Router-DLink Router-Cpbee)) {
        my $lib = File::Spec->catdir( $misc, $m, 'lib' );
        push @INC, $lib if -d $lib && !grep { $_ eq $lib } @INC;
    }
}

=head1 NAME

Router::Op - one way to ask any of the home routers (cmrouter, vr180, cpbee) the same questions

=head1 SYNOPSIS

    use Router::Op;

    my $r = Router::Op->connect('vr180');          # by name; the logins come from the vault
    printf "%-20s %-15s %s\n", @$_{qw(name ip mac)} for $r->hosts;
    print "internet is ", ( $r->internet_up ? "up" : "DOWN" ), "\n";
    my $wan = $r->wan;                             # the same keys whichever router it is
    eval { $r->port_forwards } or print "not available: $@";

    for my $name ( Router::Op->names ) { ... }     # all of them

=head1 DESCRIPTION

Three routers have a module each: L<Router::Actiontec::T3200M> (C<cmrouter>), L<Router::DLink> (C<vr180>) and
L<Router::Cpbee> (C<cpbee>). They share a core API but return slightly different keys. This module puts one shape on
top of them, says in one place what each can do (L</CAPABILITIES>), and makes anything a router cannot do fail the
same way in all three.

The logins live in the vault only (C<auth get https HOST --with-login>, read by the modules); nothing is taken on a
command line or put in a file here.

=head1 THE ONE SHAPE

Every key is always present (an empty string, or C<undef> for the two time stamps, when the router does not know it).
The router's own extra keys are kept as well.

=over 4

=item hosts

C<name ip mac medium addressing active reserved lease_expires>. C<active> is 1 when the device is on the LAN now
(for the D-Link, which only lists DHCP clients, every client). C<lease_expires> is an epoch time, or C<undef>
(unknown, or a lease that never ends).

=item wan

C<link> (C<Up> or C<Down>), C<isp_status> (C<Connected>, C<Disconnected>, ...), C<mac ip netmask gateway>,
C<dns> (array ref), C<lease_secs protocol addressing up_secs>.

=item device

C<model serial firmware hardware hostname uptime_secs>.

=back

=head1 CAPABILITIES

C<yes> = works, C<no> = the router cannot, C<todo> = the router could, nobody has written it yet. A call that is not
C<yes> croaks C<< not supported: CALL on ROUTER (WHY) >> in all three, so a caller can C<eval> it or ask
C<< $r->supports('CALL') >> first.

    call            cmrouter   vr180   cpbee
    hosts           yes        yes     yes
    wan             yes        yes     yes
    device          yes        yes     yes
    uptime          yes        yes     yes
    internet_up     yes        yes     yes
    reboot          yes        yes     yes     (cpbee: never run live; takes the whole LAN down)
    wan.up_secs     no         yes     no
    wan.lease_secs  yes        no      yes
    hosts.reserved  no         yes     yes
    hosts.lease     no         yes     yes
    port_forwards   todo       todo    todo
    wifi            todo       todo    no      (cpbee has no radio)
    firewall        todo       todo    todo

=cut

# name => how to build and use it.  login: always (every read needs it), write (only reboot), none.
our %ROUTERS = (
    cmrouter => { class => 'Router::Actiontec::T3200M', host => 'cmrouter', login => 'write', vault => 1,
                  model => 'Actiontec T3200M' },
    vr180    => { class => 'Router::DLink',             host => 'vr180',    login => 'always', vault => 1,
                  model => 'D-Link DIR-655' },
    cpbee    => { class => 'Router::Cpbee',             host => 'cpbee',    login => 'none',   vault => 0,
                  model => 'cpbee (Debian gateway)' },
);

our %CAPS = (
    hosts           => { cmrouter => 'yes',  vr180 => 'yes',  cpbee => 'yes' },
    wan             => { cmrouter => 'yes',  vr180 => 'yes',  cpbee => 'yes' },
    device          => { cmrouter => 'yes',  vr180 => 'yes',  cpbee => 'yes' },
    uptime          => { cmrouter => 'yes',  vr180 => 'yes',  cpbee => 'yes' },
    internet_up     => { cmrouter => 'yes',  vr180 => 'yes',  cpbee => 'yes' },
    reboot          => { cmrouter => 'yes',  vr180 => 'yes',  cpbee => 'yes' },
    port_forwards   => { cmrouter => 'todo', vr180 => 'todo', cpbee => 'todo' },
    wifi            => { cmrouter => 'todo', vr180 => 'todo', cpbee => 'no' },
    firewall        => { cmrouter => 'todo', vr180 => 'todo', cpbee => 'todo' },
);

our %WHY = (
    todo => 'the router could, but it has not been written yet',
    no   => 'this router cannot',
);

# facts about single keys (not calls), for the table in the docs and `router-op capabilities`
our %KEYS = (
    'wan.up_secs'    => { cmrouter => 'no',  vr180 => 'yes', cpbee => 'no' },
    'wan.lease_secs' => { cmrouter => 'yes', vr180 => 'no',  cpbee => 'yes' },
    'hosts.reserved' => { cmrouter => 'no',  vr180 => 'yes', cpbee => 'yes' },
    'hosts.lease'    => { cmrouter => 'no',  vr180 => 'yes', cpbee => 'yes' },
);

=head1 CLASS METHODS

=head2 names

The router names, in the order C<cmrouter vr180 cpbee> (plus any in the config file).

=head2 load_config($file)

Adds routers from a file: lines C<NAME CLASS [HOST]>, C<#> comments. C<CLASS> is one of the three modules and the
login rules follow the class. The default file is C<$ROUTER_OP_CONF> or C<~/.config/router-op>; none is needed.
It holds names only, never a login.

=cut

my @ORDER = qw(cmrouter vr180 cpbee);
my %BY_CLASS = map { $ROUTERS{$_}{class} => $_ } @ORDER;

sub names { return ( @ORDER, grep { my $n = $_; !grep { $_ eq $n } @ORDER } sort keys %ROUTERS ) }

sub load_config {
    my ( $class, $file ) = @_;
    $file //= $ENV{ROUTER_OP_CONF} // File::Spec->catfile( $ENV{HOME} // '', '.config', 'router-op' );
    open( my $fh, '<', $file ) or return 0;
    my $n = 0;
    while ( my $l = <$fh> ) {
        $l =~ s/#.*//;
        my ( $name, $cls, $host ) = split ' ', $l;
        next unless defined $cls;
        croak "$file: bad router name '$name'" unless $name =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/;
        my $proto = $BY_CLASS{$cls} or croak "$file: unknown module '$cls' (one of " . join( ', ', sort keys %BY_CLASS ) . ")";
        $ROUTERS{$name} = { %{ $ROUTERS{$proto} }, host => $host // $name };
        $CAPS{$_}{$name} = $CAPS{$_}{$proto} for keys %CAPS;
        $KEYS{$_}{$name} = $KEYS{$_}{$proto} for keys %KEYS;
        $n++;
    }
    return $n;
}

=head2 connect($name, %args)

Returns a handle for the named router. C<host> overrides the name's host; C<native> gives an object to use instead of
building the module's (for tests); C<probe> is passed to C<internet_up> on cpbee (C<host:port>).

=cut

sub connect {
    my ( $class, $name, %o ) = @_;
    my $spec = $ROUTERS{$name} or croak "unknown router '$name' (one of " . join( ', ', $class->names ) . ")";
    return bless { name => $name, spec => $spec, native => $o{native}, host => $o{host}, probe => $o{probe}, in => 0 }, 'Router::Op::Handle';
}

=head2 capabilities

Hash ref C<< { call => { router => 'yes|no|todo' } } >>, the calls and the single keys together.

=cut

sub capabilities { return { %CAPS, %KEYS } }

# ---- normalisers (usable without a router) --------------------------------------------------

=head2 normalize_hosts($router_class, @hosts), normalize_wan($router_class, $wan), normalize_device($router_class, $dev)

Put the one shape on what a module returned. C<$router_class> is the module name (or a router name).

=cut

sub _name_of { my $c = shift; return exists $ROUTERS{$c} ? $ROUTERS{$c}{class} : $c }

sub normalize_hosts {
    my ( $c, @h ) = @_;
    my $n = _name_of($c);
    my $now = time;
    my @out;
    for my $e (@h) {
        my %h = %$e;
        $h{$_} = '' for grep { !defined $h{$_} } qw(name ip mac medium addressing);
        if ( $n eq 'Router::DLink' ) {                         # DHCP clients only: every one is on the LAN
            $h{active}     //= 1;
            $h{addressing} = 'DHCP' unless length $h{addressing};
            $h{reserved}   //= ( ( $e->{is_reservation} // 0 ) ? 1 : 0 );
            my $s = $e->{seconds_remaining};
            $h{lease_expires} //= ( defined $s && $s =~ /\A\d+\z/ && $s < 4294967295 ) ? $now + $s : undef;
        }
        $h{active}        = $h{active} ? 1 : 0;
        $h{reserved}      = $h{reserved} ? 1 : 0;
        $h{lease_expires} = undef unless exists $h{lease_expires};
        push @out, \%h;
    }
    return @out;
}

sub normalize_wan {
    my ( $c, $w ) = @_;
    my $n = _name_of($c);
    my %w = %{ $w || {} };
    if ( $n eq 'Router::DLink' ) {
        my $st = $w{state} // '';
        $w{isp_status} //= $st;
        $w{link}       = ( ( $w{link} // '' ) =~ /\A(?:Connected|Up)\z/i ) ? 'Up' : ( length( $w{link} // '' ) ? 'Down' : '' );
        $w{up_secs}  //= '';
    }
    $w{$_} = '' for grep { !defined $w{$_} } qw(link isp_status mac ip netmask gateway lease_secs protocol addressing up_secs);
    $w{dns} = [] unless ref $w{dns} eq 'ARRAY';
    return \%w;
}

sub normalize_device {
    my ( $c, $d ) = @_;
    my %d = %{ $d || {} };
    $d{$_} = '' for grep { !defined $d{$_} } qw(model serial firmware hardware hostname uptime_secs);
    $d{uptime_secs} = int( $d{uptime_secs} ) if $d{uptime_secs} =~ /\A\d+(?:\.\d+)?\z/;    # the Actiontec says 1045207.50
    return \%d;
}

# ----------------------------------------------------------------------------------------------

package Router::Op::Handle;

use strict;
use warnings;
use Carp qw(croak);

=head1 THE HANDLE

C<name host model supports(CALL) login logout hosts(active=>1) clients wan device uptime internet_up reboot(confirm=>1)
wait_until_up port_forwards wifi firewall native>.

C<login> is lazy: a call that needs one logs in by itself (the Actiontec's home page is public, so only C<reboot> logs
in there). C<reboot> still wants C<< confirm => 1 >> and is never called by anything but a person's command.

=cut

sub name  { $_[0]{name} }
sub host  { $_[0]{host} // $_[0]{spec}{host} }
sub model { $_[0]{spec}{model} }
sub native {
    my ($self) = @_;
    return $self->{native} //= do {              # built on first use, so a call that is not supported never touches the vault
        my $spec = $self->{spec};
        ( my $file = $spec->{class} ) =~ s{::}{/}g;
        require "$file.pm";
        my %a = ( host => $self->{host} // $spec->{host} );
        $spec->{vault} ? $spec->{class}->new_from_vault(%a) : $spec->{class}->new(%a);
    };
}

sub supports {
    my ( $self, $call ) = @_;
    my $v = ( $Router::Op::CAPS{$call} || $Router::Op::KEYS{$call} || {} )->{ $self->{name} } // 'no';
    return $v eq 'yes' ? 1 : 0;
}

sub _need {
    my ( $self, $call ) = @_;
    my $v = ( $Router::Op::CAPS{$call} || {} )->{ $self->{name} } // 'no';
    return 1 if $v eq 'yes';
    croak "not supported: $call on $self->{name} (" . ( $Router::Op::WHY{$v} // 'unknown' ) . ")";
}

sub login {
    my ($self) = @_;
    return $self if $self->{in};
    $self->native->login;
    $self->{in} = 1;
    return $self;
}

sub _read_login { my $s = shift; $s->login if $s->{spec}{login} eq 'always' }

sub logout {
    my ($self) = @_;
    $self->native->logout if $self->{in};
    $self->{in} = 0;
    return $self;
}

sub hosts {
    my ( $self, %o ) = @_;
    $self->_need('hosts');
    $self->_read_login;
    my @h = Router::Op::normalize_hosts( $self->{spec}{class}, $self->native->hosts );
    @h = grep { $_->{active} } @h if $o{active};
    return @h;
}

sub clients { return map { [ @$_{qw(ip mac name)} ] } $_[0]->hosts( active => 1 ) }

sub wan {
    my ($self) = @_;
    $self->_need('wan');
    $self->_read_login;
    return Router::Op::normalize_wan( $self->{spec}{class}, $self->native->wan );
}

sub device {
    my ($self) = @_;
    $self->_need('device');
    $self->_read_login;
    return Router::Op::normalize_device( $self->{spec}{class}, $self->native->device );
}

sub uptime {
    my ($self) = @_;
    $self->_need('uptime');
    my $u = $self->device->{uptime_secs};
    return ( defined $u && $u =~ /\A\d+\z/ ) ? $u + 0 : undef;
}

sub internet_up {
    my ( $self, %o ) = @_;
    $self->_need('internet_up');
    $self->_read_login;
    my $probe = $o{probe} // $self->{probe};
    return $self->native->internet_up( $self->{spec}{class} eq 'Router::Cpbee' && defined $probe ? ( probe => $probe ) : () ) ? 1 : 0;
}

sub reboot {
    my ( $self, %o ) = @_;
    croak "reboot needs confirm => 1" unless defined $o{confirm} && $o{confirm} eq '1';
    $self->_need('reboot');
    $self->login;
    $self->native->reboot( confirm => 1 );
    $self->{in} = 0;
    return 1;
}

sub wait_until_up {
    my ( $self, %o ) = @_;
    return $self->native->wait_until_up(%o);
}

sub port_forwards { $_[0]->_need('port_forwards') }
sub wifi          { $_[0]->_need('wifi') }
sub firewall      { $_[0]->_need('firewall') }

sub DESTROY { my $s = shift; local $@; eval { $s->logout } if $s->{in} }

1;

=head1 AUTHOR

Chris Pollitt. Part of the Misc repository.

=cut
