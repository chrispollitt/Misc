use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Math::BigInt;
use Router::Actiontec::T3200M;
use FakeRouter;

my ( $n, $d ) = ( FakeRouter::modulus(), FakeRouter::privexp() );
my $k = length($n) / 2;

sub decrypt {
    my ($c) = @_;
    my $m = Math::BigInt->from_hex( '0x' . unpack( 'H*', $c ) )
      ->bmodpow( Math::BigInt->from_hex("0x$d"), Math::BigInt->from_hex("0x$n") );
    my $hex = substr( $m->as_hex, 2 );
    return pack( 'H*', ( '0' x ( 2 * $k - length $hex ) ) . $hex );
}

my $c = Router::Actiontec::T3200M::rsa_encrypt_pkcs1( $n, '10001', 'Pa55 w0rd!' );
is( length $c, $k, 'ciphertext as long as the modulus' );

my $em = decrypt($c);
like( $em, qr/\A\x00\x02[^\x00]{8,}\x00Pa55 w0rd!\z/s, 'PKCS#1 v1.5 type 2 block with the message at the end' );

my $c2 = Router::Actiontec::T3200M::rsa_encrypt_pkcs1( $n, '10001', 'Pa55 w0rd!' );
isnt( $c, $c2, 'random padding: two encryptions differ' );

my $fixed = sub { 7 };
my $c3 = Router::Actiontec::T3200M::rsa_encrypt_pkcs1( $n, '10001', 'x', $fixed );
my $c4 = Router::Actiontec::T3200M::rsa_encrypt_pkcs1( $n, '10001', 'x', $fixed );
is( $c3, $c4, 'injected random source makes it deterministic' );

my $seq = do { my @q = ( 0, 0, 5 ); sub { @q ? shift @q : 6 } };
my $c5 = Router::Actiontec::T3200M::rsa_encrypt_pkcs1( $n, '10001', 'x', $seq );
like( decrypt($c5), qr/\A\x00\x02\x05\x06+\x00x\z/, 'zero random bytes are skipped (PS has no zeros)' );

eval { Router::Actiontec::T3200M::rsa_encrypt_pkcs1( $n, '10001', 'x' x ( $k - 10 ) ) };
like( $@, qr/too long/, 'message longer than k-11 refused' );
my $ok = eval { Router::Actiontec::T3200M::rsa_encrypt_pkcs1( $n, '10001', 'x' x ( $k - 11 ) ) };
ok( $ok, 'message of exactly k-11 bytes accepted' );

eval { Router::Actiontec::T3200M::rsa_encrypt_pkcs1( $n, '10001', "pw\x{263a}" ) };
like( $@, qr/wide characters/, 'wide characters refused' );

done_testing;
