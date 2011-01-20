
### Bio::Vega::DnaDnaAlignFeature

package Bio::Vega::DnaDnaAlignFeature;

use strict;
use warnings;
use base 'Bio::EnsEMBL::DnaDnaAlignFeature';

sub get_HitDescription {
    my( $self ) = @_;
    
    return $self->{'_hit_description'};
}

1;

__END__

=head1 NAME - Bio::Vega::DnaDnaAlignFeature

=head1 DESCRIPTION

Extends its Bio::EnsEMBL::DnaDnaAlignFeature
baseclass to add the method:

=head1 get_HitDescription

Returns the Bio::Vega::HitDescription object
attached to the feature.

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

