package Bio::Otter::LocalServer;

use strict;
use warnings;

use base 'Bio::Otter::Server';

sub new {
    my ($pkg, %options) = @_;

    my $self = $pkg->SUPER::new();

    # Sensible either-or left to instantiator to enforce
    $self->dataset_name($options{dataset}) if $options{dataset};
    $self->otter_dba($options{otter_dba})  if $options{otter_dba};

    return $self;
}

### Methods



### Accessors

sub dataset_name {
    my ($self, @args) = @_;
    ($self->{_dataset_name}) = @args if @args;
    return $self->{_dataset_name};
}

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

1;
