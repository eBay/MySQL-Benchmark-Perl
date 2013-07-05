package MySQL::Benchmark;

use 5.006;
use strict;
use warnings FATAL => 'all';

use Getopt::Long;
use MySQL::Benchmark::IPC::Server;
use MySQL::Benchmark::Worker;
use MySQL::Benchmark::Query;
use MySQL::Benchmark::Logger qw(log);
use Time::HiRes;
use POSIX qw(:sys_wait_h strftime ceil);
use YAML::XS ();
use Storable ();
use List::Util();
use Data::Dumper();

=head1 NAME

MySQL::Benchmark - Custom MySQL Benchmarks made easy.

=head1 VERSION

Version 1.03

=cut

our $VERSION = '1.03';

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
    $self->normalise_query_weights;
    $self->initialise_ipc;
    $self->fork_workers;
    $self->initialise_signal_handlers;
    $self->supervision_loop;
    $self->tear_down_ipc;
    $self->output_results;
}

=head2 evaluate_command_line_options

=cut

sub evaluate_command_line_options {
    my ($self) = @_;

    # Default configuration
    # FIXME: define workers in function of available processor cores?
    my $options = {
        workers              => 1,
        runtime              => 10,
        mysql                => { defaults_file => "$ENV{HOME}/.my.cnf" },
        flush_interval       => 3,
        max_query_array_size => 10,
        report               => 0,
    };

    my $result = GetOptions(
        'debug'     => \$$options{debug},
        'verbose'   => \$$options{verbose},
        'report'    => \$$options{report},
        'csv'       => \$$options{csv},
        'outfile=s' => \$$options{outfile},

        'queries=s'              => \$$options{queries},
        'workers=i'              => \$$options{workers},
        'max-query-array-size=i' => \$$options{max_query_array_size},
        'runtime=i'              => \$$options{runtime},
        'flush-interval=i'       => \$$options{flush_interval},

        'dbhost=s'     => \$$options{mysql}{host},
        'dbschema=s'   => \$$options{mysql}{schema},
        'dbuser=s'     => \$$options{mysql}{user},
        'dbpassword=s' => \$$options{mysql}{password},
        'dbdefaults=s' => \$$options{mysql}{defaults_file},
    );

    $$self{options} = $options;
}

=head2 load_queries_file

=cut

sub load_queries_file {
    my ($self) = @_;

    unless ( -f $$self{options}{queries} ) {
        $self->log(qq(File "$$self{options}{queries}" doesn't exist.));
        exit;
    }

    $$self{queries} = [ map { MySQL::Benchmark::Query->new($_) }
            @{ YAML::XS::LoadFile( $$self{options}{queries} ) } ];

    if ( $$self{options}{debug} ) {
        $self->log( q(Loaded )
                . ( $$self{queries} ? scalar @{ $$self{queries} } : 0 )
                . qq( queries from file "$$self{options}{queries}".) );
    }

    return;
}

=head2 normalise_query_weights

Assigns proper weights for every query loaded from the Query Descriptor File.

=cut

sub normalise_query_weights {
    my ($self) = @_;

    # Calculate Total Weight from the Query Definition File
    my $total_weight = 0;
    foreach my $query ( @{ $$self{queries} } ) {
        $total_weight += $query->weight;
    }
    $self->log("Total Query Weight is $total_weight.")
        if $$self{options}{debug};

    # Normalise the weight of all queries to the requested array size
    my @new_queries = ();
    foreach my $query ( @{ $$self{queries} } ) {
        my $new_weight
            = ceil( $$self{options}{max_query_array_size}
                * $query->weight
                / $total_weight );
        $new_weight = $new_weight > 1 ? $new_weight : 1;
        $query->weight($new_weight);
        $self->log(
            qq(Query @{[$query->id]} has normalised weight of @{[$query->weight]}.)
        ) if $$self{options}{debug};

        # Reflect the change on the new Query Array.
        push @new_queries, $query for 1 .. $new_weight;
    }

    $$self{queries} = [@new_queries];

    return;
}

=head2 initialise_ipc

=cut 

sub initialise_ipc {
    my ($self) = @_;
    my $server = eval { MySQL::Benchmark::IPC::Server->new };
    if ($@) {
        $self->log(qq{Cannot initalise IPC communications: $@});
        exit;
    }
    $$self{ipc_server} = $server;
}

=head2 ipc_server_socket

Accessor. Returns the socket currently in use by the underlying
MySQL::Benchmark::IPC::Server.

=cut

sub ipc_server_socket {
    my ($self) = @_;
    return $$self{ipc_server}->socket_file;
}

=head2 fork_workers

=cut 

sub fork_workers {
    my ($self) = @_;
    my $workers;
    $$self{worker_pids} = [];
    while ( ++$workers <= $$self{options}{workers} ) {
        push @{ $$self{worker_pids} },
            MySQL::Benchmark::Worker->new(
            mysql          => $$self{options}{mysql},
            queries        => [ List::Util::shuffle( @{ $$self{queries} } ) ],
            flush_interval => $$self{options}{flush_interval},
            socket_file    => $self->ipc_server_socket,
            options        => {
                debug   => $$self{options}{debug},
                verbose => $$self{options}{verbose}
            },
            );
    }
    $self->log("Forked workers: @{ $$self{worker_pids} }.")
        if $$self{options}{debug};
}

=head2 tear_down_workers

=cut

sub tear_down_workers {
    my ($self) = @_;
    my $stopped_count;
    if ( $$self{options}{debug} ) {
        local $" = ', ';
        $self->log("Signalling workers: @{ $$self{worker_pids} }.");
    }
    foreach my $worker ( @{ $$self{worker_pids} } ) {
        if ( my $count = kill 'TERM', $worker ) {
            $stopped_count += $count;
        }
    }
    $self->log("Signalled $stopped_count workers.") if $$self{options}{debug};
}

=head2 stop_benchmark

=cut 

sub stop_benchmark {
    my ($self) = @_;
    return if $self->is_stopped;
    $self->log('Stopping benchmark') if $$self{options}{debug};
    $$self{STOP} = 1;
    $self->tear_down_workers;
}

=head2 is_stopped

=cut

sub is_stopped { ${ $_[0] }{STOP} }

=head2 handle_sigchild

=cut

sub handle_sigchild {
    my ($self) = @_;
    while ( ( my $kid = waitpid( -1, WNOHANG ) ) > 0 ) {
        @{ $$self{worker_pids} }
            = grep { $_ != $kid } @{ $$self{worker_pids} };
    }
}

=head2 handle_sigterm

=cut

sub handle_sigterm {
    my ($self) = @_;
    $self->log('    Interrupted by user. Stopping benchmark.');
    $self->stop_benchmark;
}

=head2 initialise_signal_handlers

=cut

sub initialise_signal_handlers {
    my ($self) = @_;
    $SIG{CHLD} = sub { $self->handle_sigchild };
    $SIG{TERM} = $SIG{INT} = sub { $self->handle_sigterm };
}

=head2 is_time_to_stop

=cut

sub is_time_to_stop {
    my ($self) = @_;

    if ( $self->is_stopped ) {
        return 1;
    }
    else {
        return Time::HiRes::tv_interval( $$self{start_time} )
            - $$self{options}{runtime} > 0;
    }
}

=head2 receive_message

=cut

sub receive_message {
    my ($self) = @_;
    my $frozen = $$self{ipc_server}->receive;

    # Ignore malformed messages without further ado.
    my $message = eval { Storable::thaw($frozen) };
    return $message;
}

=head2 process_message

=cut 

sub process_message {
    my ( $self, $message ) = @_;
    return
        unless UNIVERSAL::isa( $message, 'HASH' )
        && UNIVERSAL::isa( $$message{statistics}, 'HASH' );

    # The idea here is to maintain global totals and per-minute partials.
    foreach my $query ( keys %{ $$message{statistics} } ) {

        # Global Total
        $$self{global_stats}{totals}{runs}
            += $$message{statistics}{$query}{runs};
        $$self{global_stats}{totals}{run_time}
            += $$message{statistics}{$query}{run_time};
        $$self{global_stats}{totals}{bytes_sent}
            += $$message{statistics}{$query}{session}{bytes_sent};
        $$self{global_stats}{totals}{bytes_received}
            += $$message{statistics}{$query}{session}{bytes_received};

        # Per Query Totals
        $$self{global_stats}{per_query}{$query}{runs}
            += $$message{statistics}{$query}{runs};
        $$self{global_stats}{per_query}{$query}{run_time}
            += $$message{statistics}{$query}{run_time};
        $$self{global_stats}{per_query}{$query}{bytes_sent}
            += $$message{statistics}{$query}{session}{bytes_sent};
        $$self{global_stats}{per_query}{$query}{bytes_received}
            += $$message{statistics}{$query}{session}{bytes_received};
    }

}

=head2 supervision_loop

=cut

sub supervision_loop {
    my ($self) = @_;
    $$self{start_time} = [Time::HiRes::gettimeofday];

SUPERVISION_LOOP:
    while ( scalar @{ $$self{worker_pids} } > 0 ) {

        my $message = $self->receive_message;
        $self->process_message($message);

    }
    continue {
        if ( $self->is_time_to_stop && !$self->is_stopped ) {
            $self->stop_benchmark;
        }
    }

    $$self{end_time} = [Time::HiRes::gettimeofday];

}

=head2 tear_down_ipc

=cut

sub tear_down_ipc { }

=head2 __format_times

=cut

sub __format_times {
    my ($self)     = @_;
    my @start_time = @{ $$self{start_time} };
    my @end_time   = @{ $$self{end_time} };
    my $start_time
        = strftime( '%Y-%m-%d %H:%M:%S.', localtime( $start_time[0] ) )
        . $start_time[1];
    my $end_time = strftime( '%Y-%m-%d %H:%M:%S.', localtime( $end_time[0] ) )
        . $end_time[1];

    my $real_clock_run_time = Time::HiRes::tv_interval( $$self{start_time} );

    @{ $$self{formatted} }{qw(start end real)}
        = ( $start_time, $end_time, $real_clock_run_time );
    return;
}

=head2 output_results

=cut

sub output_results {
    my ($self) = @_;

    $self->__format_times;

    # Either open the right file or redirect the output
    my $outfile;
    if ( $$self{options}{outfile} ) {
        open $outfile, '>', $$self{options}{outfile} or die $!;
    }
    else { $outfile = \*STDOUT; }

    if ( $$self{options}{report} ) {
        print $outfile $self->output_report;
    }

    if ( $$self{options}{csv} ) {
        print $outfile $self->output_csv;
    }

    if ( $$self{options}{outfile} ) { close $$self{outfile} or die $!; }
}

=head2 output_csv

=cut

sub output_csv {
    my ($self) = @_;
    my $result = join( ',',
        'Start Time',
        'End Time',
        'Real Elapsed Time',
        'Workers',
        'Run Time',
        'Runs',
        'Bytes Sent',
        'Bytes Received' )
        . "\n";
    $result .= join( ',',
        "'$$self{formatted}{start}'",
        "'$$self{formatted}{end}'",
        $$self{formatted}{real},
        $$self{options}{workers},
        @{ $$self{global_stats}{totals} }
            {qw( run_time runs bytes_sent bytes_received )} )
        . "\n";
    $result .= "\n";
    $result .= join(
        "\n",
        join( ',',
            'Query ID',
            'Run Time',
            'Runs',
            'Bytes Sent',
            'Bytes Received' ),
        map {
            join( ',',
                "'$_'",
                @{ $$self{global_stats}{per_query}{$_} }
                    {qw( run_time runs bytes_sent bytes_received )} )
            }
            keys %{ $$self{global_stats}{per_query} }
    ) . "\n";
    return $result;
}

=head2 output_report

=cut

sub output_report {
    my ($self) = @_;

    my $result
        = qq(\nBenchmark Complete.)
        . qq(\n\n\tStart Time: $$self{formatted}{start})
        . qq(\n\tEnd Time: $$self{formatted}{end})
        . qq(\n\tReal Clock Elapsed Time: $$self{formatted}{real} seconds.)
        . qq(\n\tUsed $$self{options}{workers} worker processes.\n)
        . qq(\n\tPER QUERY STATISTICS:)
        . join(
        "\n",
        map {
                  qq(\n\t\tQuery ID: $_)
                . qq(\n\t\t\tRun Time: $$self{global_stats}{per_query}{$_}{run_time})
                . qq(\n\t\t\tRuns: $$self{global_stats}{per_query}{$_}{runs})
                . qq(\n\t\t\tBytes Sent: $$self{global_stats}{per_query}{$_}{bytes_sent})
                . qq(\n\t\t\tBytes Received: $$self{global_stats}{per_query}{$_}{bytes_received})
            }
            keys %{ $$self{global_stats}{per_query} }
        )
        . qq(\n\n\tGLOBAL STATISTICS:)
        . qq(\n\t\tRun Time: $$self{global_stats}{totals}{run_time})
        . qq(\n\t\tRuns: $$self{global_stats}{totals}{runs})
        . qq(\n\t\tBytes Sent: $$self{global_stats}{totals}{bytes_sent})
        . qq(\n\t\tBytes Received: $$self{global_stats}{totals}{bytes_received})
        . qq{\n\n\n};

    return $result;
}

=head1 AUTHOR

Luis Motta Campos, C << <lmc at cpan.org> >>

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
