#!/usr/bin/perl
# Stands in for `ssh cpbee sh -s`: reads the script on stdin, answers like cpbee.
# Env FAKE_SSH_MODE: normal (default) | nosudo | down | reboot_ok | silent
use strict;
use warnings;
use File::Basename qw(dirname);

my $script = do { local $/; <STDIN> };
my $mode   = $ENV{FAKE_SSH_MODE} || 'normal';
exit 255 if $mode eq 'down';

if ( $script =~ /=== end/ ) {
    open( my $f, '<', dirname(__FILE__) . '/../data/snapshot.txt' ) or die $!;
    local $/;
    print scalar <$f>;
}
elsif ( $script =~ /systemctl reboot/ ) {
    if    ( $mode eq 'nosudo' ) { print "sudo: a password is required\nrc=1\n" }
    elsif ( $mode eq 'reboot_ok' ) { }    # ssh drops: no output at all
    else                          { print "rc=0\n" }
}
elsif ( $script =~ m{/dev/tcp/} ) {
    print( ( $ENV{FAKE_PING} || 'yes' ) . "\n" );
}
else { print "cpbee\n" }
