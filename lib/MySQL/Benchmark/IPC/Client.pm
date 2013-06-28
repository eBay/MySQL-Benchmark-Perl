package MySQL::Benchmark::IPC::Client;

use 5.006;
use strict;
use warnings FATAL => 'all';

use IO::Socket;

=head1 NAME

=head1 VERSION

=head1 SYNOPSYS

=head1 DESCRIPTION

=head1 METHODS

=head2 new 

Constructor.

=cut

sub new {
    my ( $class, %self ) = @_;

    die 'Cannot communicate without a named pipe!' unless $self{socket_file};
    $self{timeout} ||= 5;

    my $self = bless \%self, $class;

    $self->initialise_socket;
    return $self;
}

=head2 initialise_socket 

=cut

sub initialise_socket {
    my ($self) = @_;
    $$self{SOCKET} = IO::Socket::UNIX->new(
        Peer    => $$self{socket_file},
        Type    => SOCK_DGRAM,
        Timeout => $$self{timeout}
    );
    die qq{Cannot initialise IPC communication socket: $!.}
        unless defined $$self{SOCKET};
}

=head2 send

Send a message.

=cut

sub send {
    my ( $self, $message ) = @_;
    $$self{SOCKET}->send($message);
}

=head2 DESTROY

Destructor. Ensures we shut down the socket before garbage collection.

=cut 

sub DESTROY {
    my ($self) = @_;
    if ( defined $$self{SOCKET} ) { $$self{SOCKET}->shutdown; }
    delete $$self{SOCKET};
}

1;    # End of MySQL::Benchmark::IPC::Server
