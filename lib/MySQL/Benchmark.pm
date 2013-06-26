package MySQL::Benchmark;

use 5.006;
use strict;
use warnings FATAL => 'all';

use Getopt::Long;
use MySQL::Benchmark::Query;
use YAML::XS qw();

=head1 NAME

MySQL::Benchmark - Custom MySQL Benchmarks made easy.

=head1 VERSION

Version 1.00

=cut

our $VERSION = '1.00';

=head1 SYNOPSIS

=head1 DESCRIPTION

This module tries to address a niche in MySQL benchmarking: there are little to
no good parallel tools to benchmark MySQL databases that are efficient and at
the same time allow customization.

=head1 METHODS

=head2 new

=cut

sub new {
    my ($class) = @_;
    my $self = bless {}, $class;

    $self->evaluate_command_line_options;
    $self->load_queries_file;
    $self->initialize_zeromq;
    $self->fork_workers;
    $self->initialise_signal_handlers;
    $self->supervision_loop;
    $self->tear_down_zeromq;
    $self->output_results;
}

=head2 evaluate_command_line_options

=cut

sub evaluate_command_line_options {
    my ($self) = @_;

    # Default configuration
    # FIXME: define workers in function of available processor cores?
    my $options = {
        workers        => 1,
        runtime        => 60,
        mysql          => { defaults_file => "$ENV{HOME}/.my.cnf" },
        flush_interval => 60,
    };

    my $result = GetOptions(
        'debug'            => \$$options{debug},
        'verbose'          => \$$options{verbose},
        'queries=s'        => \$$options{queries},
        'workers=i'        => \$$options{workers},
        'dbhost=s'         => \$$options{mysql}{host},
        'dbschema=s'       => \$$options{mysql}{schema},
        'dbuser=s'         => \$$options{mysql}{user},
        'dbpassword=s'     => \$$options{mysql}{password},
        'dbdefaults=s'     => \$$options{mysql}{defaults_file},
        'runtime=i'        => \$$options{runtime},
        'flush_interval=i' => \$$options{flush_interval},
    );

    $$self{options} = $options;
}

=head2 load_queries_file

=cut

sub load_queries_file {
    my ($self) = @_;

    die qq(File "$$self{options}{queries}" doesn't exist.)
        unless -f $$self{options}{queries};

    $$self{queries} = [ map { MySQL::Benchmark::Query->new($_) }
            @{ YAML::XS::LoadFile( $$self{options}{queries} ) } ];
}

=head2 initialise_zeromq

=cut 

sub initialize_zeromq { }

=head2 fork_workers

=cut 

sub fork_workers {
    my ($self) = @_;
    my $workers;
    while ( ++$workers <= $$self{options}{workers} ) {
        push @{ $$self{worker_pids} },
            MySQL::Benchmark::Worker->new(
            mysql          => $$self{options}{mysql},
            queries        => $$self{options}{queries},
            flush_interval => $$self{options}{flush_interval},
            );
    }
}

=head1 AUTHOR

Luis Motta Campos, C<< <lmc at cpan.org> >>

=head1 BUGS

The web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=mysql-benchmark>.  I will be
notified, and then you'll automatically be notified of progress on your bug as
I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc MySQL::Benchmark


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=mysql-benchmark>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/mysql-benchmark>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/mysql-benchmark>

=item * Search CPAN

L<http://search.cpan.org/dist/mysql-benchmark/>

=back


=head1 ACKNOWLEDGEMENTS


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

1;    # End of MySQL::Benchmark
