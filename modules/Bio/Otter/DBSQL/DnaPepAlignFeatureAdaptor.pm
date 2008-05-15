
### Bio::Otter::DBSQL::DnaPepAlignFeatureAdaptor

package Bio::Otter::DBSQL::DnaPepAlignFeatureAdaptor;

use strict;
use warnings;

use Bio::Otter::DnaPepAlignFeature;
use base 'Bio::EnsEMBL::DBSQL::ProteinAlignFeatureAdaptor';


sub _objs_from_sth {
    my $self = shift;
    
    my $hd_aptr = $self->db->get_HitDescriptionAdaptor;
    
    my $features = $self->SUPER::_objs_from_sth(@_);
    
    my $hit_hash = {map {$_->hseqname, undef} @$features};
    $hd_aptr->fetch_HitDescriptions_into_hash($hit_hash);
    foreach my $feat (@$features) {
        if (my $desc = $hit_hash->{$feat->hseqname}) {
            bless $feat, 'Bio::Otter::DnaPepAlignFeature';
            $feat->{'_hit_description'} = $desc;
        } else {
            warn sprintf "No HitDescription for '%s'", $feat->hseqname;
        }
    }
    return $features;
}


1;

__END__

=head1 NAME - Bio::Otter::DBSQL::DnaPepAlignFeatureAdaptor

=head1 DESCRIPTION

Extends its Bio::Otter::DnaPepAlignFeature
baseclass to add Bio::Otter::HitDescription
objects to the features it fetches, which become
Bio::Otter::DnaPepAlignFeatures.

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

