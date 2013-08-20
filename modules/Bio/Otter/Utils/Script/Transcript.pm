package Bio::Otter::Utils::Script::Transcript;

## Moose provides these, but webpublish doesn't know that!
##
use strict;
use warnings;
##

use namespace::autoclean;

use Moose;

extends 'Bio::Otter::Utils::Script::Object';

has 'transcript_id' => ( is => 'ro', isa => 'Int', required => 1 );

# Sort this out properly later
# has 'gene' => (
#     is       => 'ro',
#     isa      => 'Bio::Otter::Utils::Script::Gene',
#     weak_ref => 1,
#     );

has 'gene_id'        => ( is => 'ro', isa => 'Int' );
has 'gene_stable_id' => ( is => 'ro', isa => 'Str' );
has 'gene_name'      => ( is => 'ro', isa => 'Str' );

around BUILDARGS => sub {
    my ($orig ,$class, %args) = @_;

    $args{stable_id} = delete $args{transcript_stable_id};
    $args{name}      = delete $args{transcript_name};

    # This is hokey as we need a dataset list of genes
    # if (my $gene_id = delete $args{gene_id}) {
    #     my %gene_spec = (
    #         gene_id   => $gene_id,
    #         stable_id => delete $args{gene_stable_id),
    #         name      => delete $args{gene_name),
    #         );
    #     $args{gene} = Bio::Otter::Utils::Script::Gene->new(%gene_spec);
    # }

    return $class->$orig(%args);
};

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
