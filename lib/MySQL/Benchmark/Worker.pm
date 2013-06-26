package MySQL::Benchmark::Worker;

use 5.006;
use strict;
use warnings FATAL => 'all';

use Time::HiRes;
use DBI;
use Storable;
use MySQL::Benchmark::Query;

use constant { DBOPTIONS =>
        { RaiseError => 1, PrintError => 0, AutoCommit => 0, PrintWarn => 0 },
};

=head1 NAME

MySQL::Benchmark::Worker - a process abstraction for MySQL::Benchmark.

=head1 SYNOPSIS

    my $pid = MySQL::Benchmark::Worker->new(
        mysql   => $mysql_config_hashref,
        queries => $mysql_benchmark_query_arrayref
    );

=head1 DESCRIPTION

This object abstracts a worker process away.

The process approach is a sound strategy for benchmarking MySQL. Benchmark usually involves placing a lot of requests to a server and lots of waiting time, so a single control process can easily manage dozens of worker processes (which will most of the time be waiting for I/O either to or from the database server).

Apart from running queries against the database server, this process is also responsible for parameter generation (with the help of L<MySQL::Benchmark::Query>) and for accounting and sending query statistics back to the L<Controller Process|MySQL::Benchmark>.

=head1 METHODS 

=head2 new 

Constructor. Returns the process ID of the newly created worker.

Won't fork if the environment variable C<MYSQL_BENCHMARK_FORKLESS_WORKER> contains a true value (in the perl sense of true).

=cut

sub new {
    unless ( $ENV{MYSQL_BENCHMARK_FORKLESS_WORKER} ) {
        die qq{Cannot fork: $!.\n} unless defined( my $child = fork );

        # If I'm the parent process, we're done here.
        return $child if $child > 0;
    }

    # If I'm the child process, initialise the Worker object.
    my ( $class, %self ) = @_;
    my $self = bless \%self, $class;

    # TODO: sanity-check parameters passed in to this Worker.
    $self->initialise_zeromq;
    $self->initialise_signal_handlers;
    $self->initialise_database_connection;
    $self->benchmark_loop;
    $self->tear_down_database_conncetion;
    $self->tear_down_zeromq;
    exit;
}

=head2 stop

=cut

sub stop {
    my ($self) = @_;
    $$self{__STOP} = 1;
}

=head2 is_stopped

=cut 

sub is_stopped { ${ $_[0] }{__STOP} }

=head2 initialise_zeromq

=cut

sub initialise_zeromq { }

=head2 handle_sigterm

=cut 

sub handle_sigterm {
    my ($self) = @_;
    $self->stop_benchmark;
}

=head2 initialise_signal_handlers

=cut

sub initialise_signal_handlers {
    my ($self) = @_;
    $SIG{TERM} = $SIG{INT} = sub { $self->handle_sigterm };
}

=head2 __dsn

=cut

sub __dsn {
    my ($self) = @_;
    my $dsn = 'DBI:mysql:'
        . (
        defined $$self{mysql}{schema} ? ';database=' . $$self{mysql}{schema}
        : ''
        )
        . (
        defined $$self{mysql}{defaults_file}
        ? ';mysql_read_default_file=' . $$self{mysql}{defaults_file}
        : ''
        );
    return $dsn;
}

=head2 initialise_database_connection

=cut

sub initialise_database_connection {
    my ($self) = @_;
    $$self{dbh} = DBI->connect(
        $self->__dsn,
        $$self{mysql}{user},
        $$self{mysql}{password}, DBOPTIONS
    );
    die DBI::errstr unless $$self{dbh};
}

=head2 flush_partial

=cut

sub flush_partial {
    my ( $self, $timestamp ) = @_;
    my $message = Storable::freeze(
        {   timestamp  => $timestamp,
            pid        => $$,
            statistics => $$self{partial},
        }
    );

    # Send ZMQ Message
    # TODO: implement this.

    # Remove partial stats
    delete $$self{partial};
}

=head2 benchmark_loop

=cut

sub benchmark_loop {
    my ($self) = @_;
    my $last_flush = [Time::HiRes::gettimeofday];

BENCHMARK_LOOP:
    while ( !$self->is_stopped ) {
        foreach my $query ( @{ $$self{queries} } ) {

            next BENCHMARK_LOOP if $self->is_stopped;

            my $ini_stat   = $self->session_status;
            my $time_start = [Time::HiRes::gettimeofday];
            my $resultset  = $query->run( $$self{dbh} );
            my $time_end   = [Time::HiRes::gettimeofday];
            my $end_stat   = $self->session_status;

            $$self{partial}{ $query->id }{runs}++;
            $$self{partial}{ $query->id }{run_time}
                += Time::HiRes::tv_interval( $time_start, $time_end );
            foreach my $key ( keys %$ini_stat ) {
                $$self{partial}{ $query->id }{session}{$key}
                    += $$end_stat{$key} - $$ini_stat{$key};
            }

        }

    }
    continue {
        if ( Time::HiRes::tv_interval($last_flush) >= $$self{flush_interval} )
        {
            $self->flush_partial($last_flush);
            $last_flush = [Time::HiRes::gettimeofday];
        }
    }

}

=head2 tear_down_database_conncetion

=cut

sub tear_down_database_conncetion {
    my ($self) = @_;
    $$self{dbh}->disconnect if ref $$self{dbh};
    delete $$self{dbh};
}

=head2 tear_down_zeromq

=cut

sub tear_down_zeromq { }

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

1;    # End of MySQL::Benchmark::Worker.
