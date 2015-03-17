
### Bio::Vega::Transform::XMLToRegion::Store

package Bio::Vega::Transform::XMLToRegion::Store;

use strict;
use warnings;

use NEXT;

use parent qw( Bio::Vega::Transform::XMLToRegion Bio::Otter::Log::WithContextMixin );

my (
    %dna_contig_coord_system,
    %vega_dba,
    %log_context,
    );

sub DESTROY {
    my ($self) = @_;

    delete $dna_contig_coord_system{$self};
    delete $vega_dba{$self};
    delete $log_context{$self};

    return $self->NEXT::DESTROY;
}

# FIXME: log_context setup

sub vega_dba {
    my ($self, @args) = @_;
    ($vega_dba{$self}) = @args if @args;
    my $vega_dba = $vega_dba{$self};
    return $vega_dba;
}

sub store {
    my ($self, $dna) = @_;

    my $vega_dba = $self->vega_dba;

    my $cs_a = $self->vega_dba->get_CoordSystemAdaptor;
    foreach my $cs_type ( qw( Chr Clone Contig DnaContig ) ) {
        my $get_set = "get_set_${cs_type}CoordSystem";
        my $coord_system = $self->$get_set;
        unless ($coord_system->is_stored($vega_dba)) {
            $cs_a->store($coord_system);
        }
    }

    my $region = $self->region;
    my $slice = $region->slice;

    # Take chromosome name from first CloneSequence
    my @clone_seqs = $region->sorted_clone_sequences;
    my $chromosome = $clone_seqs[0]->chromosome;

    my $db_slice = $self->slice_stored_if_needed($slice, $dna, $chromosome);

    my $reattach = ($db_slice != $slice);

    foreach my $cs ( @clone_seqs ) {
        $self->_store_clone_sequence($cs, $db_slice);
    }

    my $gene_a = $vega_dba->get_GeneAdaptor;
    foreach my $gene ( $region->genes ) {
        if ($reattach) {
            $self->_reattach_gene($gene, $db_slice);
        }
        $gene_a->store($gene);
    }

    my $sf_a = $vega_dba->get_SimpleFeatureAdaptor;
    foreach my $sf ( $region->seq_features ) {
        if ($reattach) {
            $sf->slice($db_slice);
        }
        $sf_a->store($sf);
    }

    return;
}

sub slice_stored_if_needed {
    my ($self, $region_slice, $dna, $chromosome) = @_;

    my $vega_dba = $self->vega_dba;
    my $slice_adaptor = $vega_dba->get_SliceAdaptor;

    my $db_seq_region = $slice_adaptor->fetch_by_region(
        $region_slice->coord_system->name,
        $region_slice->seq_region_name,
        );

    if ($db_seq_region) {
        $self->logger->debug('slice already in sqlite');
    } else {
        $self->logger->debug('creating and storing slice');

        # db_seq_region's coord_system needs to be the one already in the DB.
        my $cs_adaptor = $vega_dba->get_CoordSystemAdaptor;
        my $cs_chr    = $cs_adaptor->fetch_by_name($region_slice->coord_system->name,
                                                   $region_slice->coord_system->version);
        my $cs_dna_contig = $cs_adaptor->fetch_by_name('dna_contig', 'Otter');

        # db_seq_region must start from 1
        my $db_seq_region_parameters = {
            %$region_slice,
            coord_system      => $cs_chr,
            start             => 1,
            seq_region_length => $region_slice->end,
        };
        $db_seq_region = Bio::EnsEMBL::Slice->new_fast($db_seq_region_parameters);
        $slice_adaptor->store($db_seq_region);

        # Ensure EnsEMBL-style chromosome name is stored
        my $attrib_adaptor = $vega_dba->get_AttributeAdaptor;
        my $chr_name_attr = $self->make_Attribute('chr', $chromosome);
        $attrib_adaptor->store_on_Slice($db_seq_region, [ $chr_name_attr ] );

        # Replace $region_slice with one connected to the database
        $region_slice = $db_seq_region->sub_Slice($region_slice->start, $region_slice->end);

        # This is replicating the stuff from B:O:L:DB where we just needed a region contig to bung the sequence on
        # and may cause problems here...
        my $region_length = $region_slice->end - $region_slice->start + 1;
        my $contig_seq_region_parameters = {
            seq_region_name   => $region_slice->seq_region_name . ":contig",
            strand            => 1,
            start             => 1,
            end               => $region_length,
            seq_region_length => $region_length,
            coord_system      => $cs_dna_contig,
        };
        my $contig_seq_region = Bio::EnsEMBL::Slice->new_fast($contig_seq_region_parameters);
        $slice_adaptor->store($contig_seq_region, \$dna);

        $slice_adaptor->store_assembly($region_slice, $contig_seq_region);
    }

    return $region_slice;
}

# FIXME - dup with B:O:ServerAction::Region->_write_region_exclusive
sub _reattach_gene {
    my ($self, $gene, $db_slice) = @_;

    $gene->slice($db_slice);

    foreach my $tran (@{ $gene->get_all_Transcripts }) {
        $tran->slice($db_slice);
    }

    foreach my $exon (@{ $gene->get_all_Exons }) {
        $exon->slice($db_slice);
    }

    return $gene;
}

sub _store_clone_sequence {
    my ($self, $cs, $db_slice) = @_;
    my $vega_dba = $self->vega_dba;

    my $slice_adaptor = $vega_dba->get_SliceAdaptor;
    my $clone_coord_sys = $self->get_CloneCoordSystem;

    my $clone = $slice_adaptor->fetch_by_region(
        $clone_coord_sys->name,
        $cs->accession_dot_sv,
        );

    unless ($clone) {
        $clone = Bio::EnsEMBL::Slice->new_fast({
            seq_region_name   => $cs->accession_dot_sv,
            strand            => 1,
            start             => 1,
            end               => $cs->length,
            seq_region_length => $cs->length,
            coord_system      => $clone_coord_sys,
                                               });
        $slice_adaptor->store($clone);

        my $attrib_adaptor = $vega_dba->get_AttributeAdaptor;
        my @cln_attribs = map { @{ $cs->ContigInfo->get_all_Attributes($_) } }
                              qw( embl_acc embl_version intl_clone_name );
        $attrib_adaptor->store_on_Slice($clone, \@cln_attribs);
    }

    my $contig_coord_sys = $self->get_ContigCoordSystem;

    my $db_contig = $slice_adaptor->fetch_by_region(
        $contig_coord_sys->name,
        $cs->contig_name,
        );

    unless ($db_contig) {
        $db_contig = Bio::EnsEMBL::Slice->new_fast({
            seq_region_name   => $cs->contig_name,
            strand            => 1,
            start             => 1,
            end               => $cs->length,
            seq_region_length => $cs->length,
            coord_system      => $contig_coord_sys,
                                                   });
        $slice_adaptor->store($db_contig);
        $slice_adaptor->store_assembly($clone, $db_contig);
    }

    my $chr_map_slice = $db_slice->seq_region_Slice->sub_Slice($cs->chr_start,    $cs->chr_end,    1);
    my $ctg_map_slice = $db_contig->sub_Slice(                 $cs->contig_start, $cs->contig_end, $cs->contig_strand);
    $slice_adaptor->store_assembly($chr_map_slice, $ctg_map_slice);

    if (my $ci = $cs->ContigInfo) {
        my $contig_info_adaptor = $vega_dba->get_ContigInfoAdaptor;
        $ci->slice($ctg_map_slice);
        $ci->author(Bio::Vega::Author->new(-name => 'dummy', -email => 'dummy')); # FIXME - what to use here?
        $contig_info_adaptor->store($ci);
    }

    return;
}

# Overrides parent to check DB first
#
sub get_set_CoordSystem {
    my ($self, $cs_type) = @_;

    my $get    = "get_${cs_type}CoordSystem";

    my $coord_system = $self->$get;
    return $coord_system if $coord_system;

    my $create = "create_${cs_type}CoordSystem";
    my $set    = "set_${cs_type}CoordSystem";

    my $template_cs = $self->$create;

    # First check we don't already have it
    my $cs_a = $self->vega_dba->get_CoordSystemAdaptor;
    $coord_system = $cs_a->fetch_by_name($template_cs->name, $template_cs->version);

    # If not, return the template - it'll get stored later if needed
    $coord_system = $template_cs unless $coord_system;

    return $self->$set($coord_system);
}

sub get_DnaContigCoordSystem {
    my ($self) = @_;

    return $dna_contig_coord_system{$self};
}

sub set_DnaContigCoordSystem {
    my ($self, $dna_contig_coord_system) = @_;

    return $dna_contig_coord_system{$self} = $dna_contig_coord_system;
}

sub create_DnaContigCoordSystem {
    my ($self) = @_;
    return Bio::EnsEMBL::CoordSystem->new(
        -name           => 'dna_contig',
        -version        => 'Otter',
        -rank           => 6,
        -sequence_level => 1,
        -default        => 1,
        );
}

sub get_set_DnaContigCoordSystem {
    my ($self) = @_;

    return $self->get_set_CoordSystem('DnaContig');
}

# Required by Bio::Otter::Log::WithContextMixin
# (default version is not inside-out compatible!)
# FIXME: dup with B:O:L:DB

sub log_context {
    my ($self, $arg) = @_;

    if ($arg) {
        $log_context{$self} = $arg;
    }

    return $log_context{$self} if $log_context{$self};
    return '-B-V-Transform-Otter-Store unnamed-';
}

1;

__END__

=head1 NAME - Bio::Vega::Transform::XMLToRegion::Store

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk
