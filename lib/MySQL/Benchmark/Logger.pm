package MySQL::Benchmark::Logger;

use 5.006;
use warnings FATAL => 'all';
use strict;

use Time::HiRes ();
use FileHandle;
use base qw( Exporter );
our @EXPORT_OK = qw( log );

BEGIN { $_->autoflush(1) for \*STDOUT, \*STDERR }

sub log {
    my ( $self, @messages ) = @_;
    my ( $package, $filename, $line, $subroutine ) = caller 1;
    $package = ( split qr{::}, $package )[-1];
    my ( $s, $ms ) = Time::HiRes::gettimeofday;
    my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime($s);
    $year += 1900;
    print STDERR map {
        sprintf( '%04d-%02d-%02d %02d:%02d:%02d.%06.0f ',
            $year, $mon, $mday, $hour, $min, $sec, $ms )
            . $package . '['
            . $$ . ']: ' . '('
            . $subroutine . ':'
            . $line . ') '
            . $_ . "\n"
    } @messages;
}

1;    # End of MySQL::Benchmark::Logger
