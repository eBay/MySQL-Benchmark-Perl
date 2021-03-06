package MySQL::Benchmark::Worker;

use 5.006;
use strict;
use warnings FATAL => 'all';

use Time::HiRes;
use DBI;
use Storable;
use MySQL::Benchmark::IPC::Client;
use MySQL::Benchmark::Query;
use MySQL::Benchmark::Logger qw( log );
use POSIX qw(:errno_h);
use Storable ();

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

The process approach is a sound strategy for benchmarking MySQL. Benchmark
usually involves placing a lot of requests to a server and lots of waiting
time, so a single control process can easily manage dozens of worker processes
(which will most of the time be waiting for I/O either to or from the database
server).

Apart from running queries against the database server, this process is also
responsible for parameter generation (with the help of
L<MySQL::Benchmark::Query>) and for accounting and sending query statistics
back to the L<Controller Process|MySQL::Benchmark>.

=head1 METHODS 

=head2 new 

Constructor. Returns the process ID of the newly created worker.

Won't fork if the environment variable C<MYSQL_BENCHMARK_FORKLESS_WORKER>
contains a true value (in the perl sense of true).

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
    $self->initialise_ipc;
    $self->initialise_signal_handlers;
    $self->initialise_database_connection;
    $self->benchmark_loop;
    $self->tear_down_database_conncetion;
    $self->tear_down_ipc;
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

=head2 initialise_ipc

=cut

sub initialise_ipc {
    my ($self) = @_;
    my $client = eval {
        MySQL::Benchmark::IPC::Client->new(
            socket_file => $$self{socket_file} );
    };
    if ($@) {
        $self->log(qq{Cannot Initialise IPC Client: "$!".});
        exit;
    }
    $$self{ipc_client} = $client;
}

=head2 handle_sigterm

=cut 

sub handle_sigterm {
    my ($self) = @_;
    $self->stop;
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
        defined $$self{mysql}{host} ? ';host=' . $$self{mysql}{host}
        : ''
        )
        . (
        defined $$self{mysql}{schema} ? ';database=' . $$self{mysql}{schema}
        : ''
        )
        . (
        defined $$self{mysql}{defaults_file}
        ? ';mysql_read_default_file=' . $$self{mysql}{defaults_file}
        : ''
        );

    $self->log(qq{DSN: "$dsn".}) if $$self{options}{debug};

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
    unless ( $$self{dbh} ) {
        $self->log(qq{DBI::connect: "$DBI::errstr".});
        exit;
    }
}

=head2 dbh

Accessor to DBI object with basic conncetivity check

FIXME: DBI behaves weird with interrupted system calls. It complains "MySQL
Server went away", stop answering to C<ping()> calls, but the DBI object is
still present and will complain about being garbage collected without first
having it's C<disconnect()> method called.

=cut

sub dbh {
    my ($self) = @_;
    unless ( UNIVERSAL::can( $$self{dbh}, 'ping' ) && $$self{dbh}->ping ) {
        if ( UNIVERSAL::can( $$self{dbh}, 'disconnect' ) ) {
            $$self{dbh}->disconnect;
            sleep 1;
        }
        $self->initialise_database_connection;
    }
    return $$self{dbh};
}

=head2 run_benchmark_query

=cut

sub run_benchmark_query {
    my ( $self, $query ) = @_;
    my $result;
RUN_QUERY: {
        eval {
            $result
                = $self->dbh->selectall_arrayref( $query->sql,
                { Slice => {} },
                $query->parameters );
        };
        if ( defined($@) && defined($!) && $! == EINTR ) {
            $@ = $! = undef;
            redo RUN_QUERY; # FIXME: reimplement as do-while for readability?
        }
    }
    $self->log(qq{Benchmark Query Error: $@.}) if $@;
    return $result;
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

    # Send IPC Message
    # FIXME: add loop breaker!
    while ( !defined( $$self{ipc_client}->send($message) ) ) {
        $self->log('Message sending operation failed. Retrying.');
        sleep 1;
    }

    # Remove partial stats
    delete $$self{partial};
}

=head2 session_status

=cut 

sub session_status {
    my ($self) = @_;
    my $result;
RUN_QUERY: {
        eval {
            my $sth = $self->dbh->prepare('SHOW SESSION STATUS');
            $sth->execute;
            $result
                = { map { lc $$_[0] => $$_[1] }
                    @{ $sth->fetchall_arrayref } };
            $sth->finish;
        };
        if ( defined($@) && defined($!) && $! == EINTR ) {
            $@ = $! = undef;
            redo RUN_QUERY;
        }
    }
    if( $@ ) {
            $self->log( qq{Session Information Data Collection Failed: "$@".} );
            $self->stop;
    }

    return $result;
}

=head2 benchmark_loop

=cut

sub benchmark_loop {
    my ($self) = @_;

    # TODO: make the actual flushing time be a function of the flush-interval
    # and the number of workers, so we distribute the flushing load uniformly
    # over time.
    my $last_flush = [Time::HiRes::gettimeofday];

BENCHMARK_LOOP:
    while ( !$self->is_stopped ) {
        foreach my $query ( @{ $$self{queries} } ) {

            next BENCHMARK_LOOP if $self->is_stopped;

            my $ini_stat   = $self->session_status;
            my $time_start = [Time::HiRes::gettimeofday];
            my $resultset  = $self->run_benchmark_query($query);
            my $time_end   = [Time::HiRes::gettimeofday];
            my $end_stat   = $self->session_status;

           # Only account for rounds where you have all measurements.
           # Also, don't account for rounds where the bytes sent are negative.
            if (   defined($ini_stat)
                && defined($end_stat)
                && $$end_stat{bytes_sent} >= $$ini_stat{bytes_sent}
                && $$end_stat{bytes_received} >= $$ini_stat{bytes_received} )
            {
                $$self{partial}{ $query->id }{runs}++;
                $$self{partial}{ $query->id }{run_time}
                    += Time::HiRes::tv_interval( $time_start, $time_end );
                foreach my $key (qw( bytes_sent bytes_received )) {
                    $$self{partial}{ $query->id }{session}{$key}
                        += $$end_stat{$key} - $$ini_stat{$key};
                }
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
    $self->dbh->disconnect if UNIVERSAL::can( $$self{dbh}, 'disconnect' );
    delete $$self{dbh};
}

=head2 tear_down_ipc

Method call to tear down IPC communication client. Theoretically, if I don't do
anything here when the IPC client socket object goes out of context it will be
properly flushed and closed.

=cut

sub tear_down_ipc { }

=head1 AUTHOR

Luis Motta Campos, C<< <lucampos at ebay.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2013-2014 eBay Software Foundation

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

=cut

1;    # End of MySQL::Benchmark::Worker.
