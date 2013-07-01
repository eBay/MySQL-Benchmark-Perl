package MySQL::Benchmark::Logger;

use 5.006;
use warnings FATAL => 'all';
use strict;

use Time::HiRes ();
use FileHandle;
use base qw( Exporter );
our @EXPORT_OK = qw( log );

BEGIN { $_->autoflush(1) for \*STDOUT, \*STDERR }

=head1 NAME

MySQL::Benchmark::Logger - Logging facility wrapper for MySQL::Benchmark

=head1 SYNOPSYS

    use MySQL::Benchmark::Logger qw( log );

=head1 DESCRIPTION

This module provides one single add-on method to be imported by any class
willing to implement C<log()>.

=head1 METHODS

=head2 log

=cut

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

=head1 AUTHOR

Luis Motta Campos, C<< <lmc at bitbistro.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 Luis Motta Campos.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; version 2 dated June, 1991 or at your option any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

A copy of the GNU General Public License is available in the source tree; if
not, write to the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
Boston, MA 02111-1307, USA.

=cut

1;    # End of MySQL::Benchmark::Logger
