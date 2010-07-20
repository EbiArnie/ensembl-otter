
package Bio::Vega::CloneFinder;

#
# A module used by server script 'find_clones' to find things on clones
# (new API version)
#

use strict;
use warnings;
use Bio::Otter::Lace::Locator;

use base ('Bio::Otter::MFetcher');

my $component = 'clone'; # this is the type of components we want the found matches mapped on
my $DEBUG=0; # do not show all SQL statements

sub new {
    my ($class, $otter_dba, $qnames, $unhide) = @_;

    my $self = $class->SUPER::new(
        '_odba'         => $otter_dba,
        '_ql'           => ($qnames ? {map {(uc($_) => [])} @$qnames } : {}),
        '_unhide'       => ($unhide ? 1 : 0),
    );

    return $self;
}

sub qnames_locators {
#
# This is a HoL
# {query_name}[locators*]
#
    my $self = shift @_;

    return $self->{_ql};
}

sub in_quoted_list {
    my $self = shift @_;

    return $self->{_in_quoted_list} ||= 'in ('. join(', ', map {"'$_'"} keys %{$self->qnames_locators()} ) .' ) ';
}

sub find_containing_chromosomes {
    my ($self, $slice) = @_;

        # EnsEMBL as of rel46 cannot perform ambigous clone|subregion->contig->chromosome mapping correctly.
        # So we prefer to do it using direct SQL:
        
    my $sa = $slice->adaptor();

        # map the original slice onto contig_ids
    my $seq_level_slice_ids = [ $slice->coord_system->is_sequence_level()
        ? $sa->get_seq_region_id($slice)
        : map { $sa->get_seq_region_id($_->to_Slice()) } @{$slice->project('seqlevel')}
    ];

        # now map those contig_ids back onto a chromosome
    my $sql = qq{
        SELECT  chr.name,
                group_concat(distinct a.cmp_seq_region_id) as joined_cmps
        FROM    assembly a,
                seq_region chr,
                coord_system cs
        WHERE   cs.name='chromosome'
        AND     cs.version='Otter'
        AND     cs.coord_system_id=chr.coord_system_id
        AND     chr.seq_region_id=a.asm_seq_region_id
        AND     a.cmp_seq_region_id IN (
    }.join(', ', @$seq_level_slice_ids).qq{
                )
     GROUP BY chr.name
    };

    my $sth = $sa->dbc()->prepare($sql);
    $sth->execute();

    my @chr_slices = ();
    while( my ($atype, $joined_cmps) = $sth->fetchrow() ) {

        my @cmps = split(/,/, $joined_cmps);

        if(scalar(@cmps) == scalar(@$seq_level_slice_ids)) {
                    # let's hope the default coord_system_version is set correctly:
            my $chr_slice = $sa->fetch_by_region('chromosome', $atype);
            push @chr_slices, $chr_slice;
        }
    }

    return \@chr_slices;
}

sub register_slices {
    my ($self, $qname, $qtype, $feature_slices) = @_;

    my $odba     = $self->otter_dba();
    my $pdba;
    my $local_sa;

    foreach my $feature_slice (@$feature_slices) {
        my $fdba = $feature_slice->adaptor->db();

        if($fdba == $odba) {
            $self->register_slice($qname, $qtype, $feature_slice);
        } elsif($fdba == ($pdba ||= $self->satellite_dba(''))) {
            $local_sa ||= $odba->get_SliceAdaptor();
            my $local_slice = $local_sa->fetch_by_region(
                $feature_slice->coord_system_name(),
                $feature_slice->seq_region_name(),
                $feature_slice->start(),
                $feature_slice->end(),
                $feature_slice->strand(),
                $feature_slice->coord_system()->version(),
            );

            $self->register_slice($qname, $qtype, $local_slice);
        } else {
            my $mapped_slices = $self->map_remote_slice_back($feature_slice);
            foreach my $mapped_slice (@$mapped_slices) {
                $self->register_slice($qname, $qtype, $mapped_slice);
            }
        }
    }
}

sub register_slice {
    my ($self, $qname, $qtype, $feature_slice) = @_;

    my $cs_name = $feature_slice->coord_system_name();

    my $component_names = [ ($cs_name eq $component)
        ? $feature_slice->seq_region_name
        : map { $_->to_Slice()->seq_region_name() }
                    # NOTE: order of projection segments WAS strand-dependent
                sort { ($a->from_start() <=> $b->from_start())*$feature_slice->strand() }
                    @{ $feature_slice->project($component) } ];

    my $found_chromosome_slices = ($cs_name eq 'chromosome')
        ? [ $feature_slice ]
        : $self->find_containing_chromosomes($feature_slice);

    my $unhide = $self->{_unhide};

    foreach my $chr_slice (@$found_chromosome_slices) {

        unless($unhide) {
            my ($hidden) = ((map {$_->value()} @{$chr_slice->get_all_Attributes('hidden')}), 1);

            next if $hidden;
        }

        my $loc = Bio::Otter::Lace::Locator->new($qname, $qtype);

        $loc->assembly( $chr_slice->seq_region_name() );
        $loc->component_names( $component_names );

        push @{ $self->qnames_locators()->{uc($qname)} }, $loc;
    }
}

sub find_by_stable_ids {
    my ($self, $qtype_prefix, $metakey) = @_;

    my $satellite_dba = $self->satellite_dba($metakey, 1) || return;

    my $meta_con   = bless $satellite_dba->get_MetaContainer(), 'Bio::Vega::DBSQL::MetaContainer';

    my $prefix_primary = $meta_con->get_primary_prefix() || 'ENS';

    my $prefix_species = $meta_con->get_species_prefix() || '\w{0,6}';

    my $gene_adaptor           = $satellite_dba->get_GeneAdaptor();
    my $transcript_adaptor     = $satellite_dba->get_TranscriptAdaptor();
    my $exon_adaptor           = $satellite_dba->get_ExonAdaptor();

    my @slices = ();

    foreach my $qname (keys %{$self->qnames_locators()}) {
        if(uc($qname) =~ /^$prefix_primary$prefix_species([TPGE])\d+/i){ # try stable_ids
            my $typeletter = $1;
            my $qtype;
            my $feature;

            eval {
                if($typeletter eq 'G') {
                    $qtype = 'gene_stable_id';
                    $feature = $gene_adaptor->fetch_by_stable_id($qname);
                } elsif($typeletter eq 'T') {
                    $qtype = 'transcript_stable_id';
                    $feature = $transcript_adaptor->fetch_by_stable_id($qname);
                } elsif($typeletter eq 'P') {
                    $qtype = 'translation_stable_id';
                    $feature = $transcript_adaptor->fetch_by_translation_stable_id($qname);
                } elsif($typeletter eq 'E') {
                    $qtype = 'exon_stable_id';
                    $feature = $exon_adaptor->fetch_by_stable_id($qname);
                }
            };

                # Just imagine: they raise an EXCEPTION to indicate nothing was found. Terrific!
            if($@) {
                # warn "'$qname' looks like a stable id, but wasn't found.";
                # warn ($@) if $DEBUG;
            } elsif($feature) { # however watch out, sometimes we just silently get nothing!
                my $feature_slice  = $feature->feature_Slice();
                my $analysis_logic = $feature->analysis->logic_name(); 

                warn "find_stable_ids: Trying to register slices ($qname, $qtype_prefix.$qtype)";
                $self->register_slices($qname, $qtype_prefix.$analysis_logic.":".$qtype, [$feature_slice]);
            }
        }
    } # foreach $qname
}

sub find_by_feature_attributes {
    my ($self, $condition, $qtype, $table, $id_field, $code, $adaptor_call) = @_;

    my $sql = qq{
        SELECT $id_field, value
        FROM $table
        WHERE attrib_type_id = (SELECT attrib_type_id from attrib_type where code='$code')
          AND value $condition
    };

    my $dbc      = $self->otter_dba()->dbc();
    my $sth = $dbc->prepare($sql);
    $sth->execute();

    my $adaptor;
    while( my ($feature_id, $qname) = $sth->fetchrow() ) {
        $adaptor ||= $self->otter_dba()->$adaptor_call; # only do it if we found something

        my $feature = $adaptor->fetch_by_dbID($feature_id);

        if($feature->is_current()) {
            $self->register_slice($qname, $qtype, $feature->feature_Slice());
        }
    }
}

sub find_by_seqregion_names {
    my ($self, $condition) = @_;

    my $dbc      = $self->otter_dba()->dbc();
    my $adaptor;

    my $sql = qq{
        SELECT cs.name, sr.name
        FROM seq_region sr, coord_system cs
        WHERE sr.coord_system_id=cs.coord_system_id
          AND cs.name <> 'chromosome'
          AND sr.name $condition
    };

    my $sth = $dbc->prepare($sql);
    $sth->execute();
    while( my ($cs_name, $sr_name) = $sth->fetchrow() ) {
        $adaptor ||= $self->otter_dba()->get_SliceAdaptor();

        my $slice = $adaptor->fetch_by_region($cs_name, $sr_name);

        $self->register_slice($sr_name, $cs_name.'_name', $slice);
    }
}

sub find_by_seqregion_attributes {
    my ($self, $condition, $qtype, $cs_name, $code) = @_;

    my $sql = qq{
        SELECT sr.name, sra.value
        FROM seq_region sr, coord_system cs, seq_region_attrib sra
        WHERE cs.name='$cs_name'
          AND sr.coord_system_id=cs.coord_system_id
          AND sr.seq_region_id=sra.seq_region_id
          AND sra.attrib_type_id = (SELECT attrib_type_id from attrib_type where code='$code')
          AND sra.value $condition
    };

    my $dbc      = $self->otter_dba()->dbc();
    my $sth = $dbc->prepare($sql);
    $sth->execute();

    my $adaptor;
    while( my ($sr_name, $qname) = $sth->fetchrow() ) {
        $adaptor ||= $self->otter_dba()->get_SliceAdaptor();

        my $slice = $adaptor->fetch_by_region($cs_name, $sr_name);

        $self->register_slice($qname, $qtype, $slice);
    }
}

sub find_by_xref {
    my ($self, $qtype_prefix, $metakey, $condition) = @_;

    my $satellite_dba = $self->satellite_dba($metakey, 1) || return;

    my $sql = qq{
        SELECT DISTINCT edb.db_name, x.dbprimary_acc,
                        sr.name, cs.name, cs.version,
                        (CASE ox.ensembl_object_type
                         WHEN 'Gene' THEN g.seq_region_start
                         WHEN 'Transcript' THEN t.seq_region_start
                         WHEN 'Translation' THEN t2p.seq_region_start END),
                        (CASE ox.ensembl_object_type
                         WHEN 'Gene' THEN g.seq_region_end
                         WHEN 'Transcript' THEN t.seq_region_end
                         WHEN 'Translation' THEN t2p.seq_region_end END)
                  FROM external_db edb, xref x, object_xref ox
             LEFT JOIN gene g ON g.gene_id=ox.ensembl_id
             LEFT JOIN transcript t ON t.transcript_id=ox.ensembl_id
             LEFT JOIN translation p ON p.translation_id=ox.ensembl_id
             LEFT JOIN transcript t2p ON p.transcript_id=t2p.transcript_id
             LEFT JOIN seq_region sr ON sr.seq_region_id=
                        (CASE ox.ensembl_object_type
                         WHEN 'Gene' THEN g.seq_region_id
                         WHEN 'Transcript' THEN t.seq_region_id
                         WHEN 'Translation' THEN t2p.seq_region_id END)
             LEFT JOIN coord_system cs ON cs.coord_system_id=sr.coord_system_id
                 WHERE edb.external_db_id=x.external_db_id
                   AND x.xref_id=ox.xref_id
                   AND x.dbprimary_acc $condition
    };

    my $dbc = $satellite_dba->dbc();
    my $sth = $dbc->prepare($sql);
    $sth->execute();

    my $adaptor;
    while( my ($qtype, $qname, $sr_name, $cs_name, $cs_version, $start, $end) = $sth->fetchrow() ) {
        $adaptor ||= $satellite_dba->get_SliceAdaptor();

        my $slice = $adaptor->fetch_by_region($cs_name, $sr_name, $start, $end, 1, $cs_version);

        $self->register_slices($qname, $qtype_prefix.$qtype.":", [ $slice ]);
    }
}

sub find_by_hit_name {
    my ($self, $qtype_prefix, $metakey, $kind, $condition) = @_;

    ## kind = 'dna'|'protein'
    #
    my $table_name = $kind.'_align_feature';

    # NB: $condition only can be equality, otherwise you'll annoy the users!

    my $satellite_dba = $self->satellite_dba($metakey, 1) || return;

    my $sql = qq{
        SELECT af.hit_name, sr.name, cs.name, cs.version, af.seq_region_start, af.seq_region_end, af.seq_region_strand
             , a.logic_name
             , SUM(af.score) score_sum
          FROM $table_name af
             , seq_region sr
             , coord_system cs
             , analysis a
         WHERE af.seq_region_id = sr.seq_region_id
           AND cs.coord_system_id = sr.coord_system_id
           AND a.analysis_id = af.analysis_id
           AND af.hit_name $condition
         GROUP BY af.hit_name, af.seq_region_id
         ORDER BY score_sum DESC
         LIMIT 10
    };

    my $dbc = $satellite_dba->dbc();
    my $sth = $dbc->prepare($sql);
    $sth->execute();

    my $adaptor;
    while( my ($qname, $sr_name, $cs_name, $cs_version, $start, $end, $strand, $analysis_name, $score) = $sth->fetchrow() ) {
        $adaptor ||= $satellite_dba->get_SliceAdaptor();

        my $slice = $adaptor->fetch_by_region($cs_name, $sr_name, $start, $end, $strand, $cs_version);

        $self->register_slices($qname, "${qtype_prefix}${analysis_name}(score=$score)", [ $slice ]);
    }
}

sub find {
    my $self = shift @_;

    $self->find_by_stable_ids('', '.');

    $self->find_by_stable_ids('EnsEMBL:','ensembl_core_db_head');

    $self->find_by_stable_ids('EnsEMBL_EST:','ensembl_estgene_db_head');

    my $in_quoted_list = $self->in_quoted_list();

    $self->find_by_hit_name('Pipeline_dna_hit:', '', 'dna', $in_quoted_list);
    $self->find_by_hit_name('Pipeline_protein_hit:', '', 'protein', $in_quoted_list);

    $self->find_by_xref('CCDS_db:','ens_livemirror_ccds_db', $in_quoted_list);

    $self->find_by_seqregion_names($in_quoted_list);

    $self->find_by_feature_attributes($in_quoted_list, 'gene_name',
        'gene_attrib', 'gene_id', 'name', 'get_GeneAdaptor');

    $self->find_by_feature_attributes($in_quoted_list, 'gene_synonym',
        'gene_attrib', 'gene_id', 'synonym', 'get_GeneAdaptor');

    $self->find_by_feature_attributes($in_quoted_list, 'transcript_name',
        'transcript_attrib', 'transcript_id', 'name', 'get_TranscriptAdaptor');

    foreach my $qname (keys %{$self->qnames_locators()}) {

        my $like_prefixed_qname = "like '%:$qname'";

        $self->find_by_feature_attributes($like_prefixed_qname, 'prefixed_gene_name',
            'gene_attrib', 'gene_id', 'name', 'get_GeneAdaptor');

        $self->find_by_feature_attributes($like_prefixed_qname, 'prefixed_transcript_name',
            'transcript_attrib', 'transcript_id', 'name', 'get_TranscriptAdaptor');
    }

    $self->find_by_seqregion_attributes($in_quoted_list, 'international_clone_name', 'clone', 'intl_clone_name');

    $self->find_by_seqregion_attributes($in_quoted_list, 'clone_accession', 'clone', 'embl_acc');
}

sub generate_output {
    my ($self, $filter_atype) = @_;

    my $output_string = '';

    for my $qname (sort keys %{$self->qnames_locators()}) {
        my $count = 0;
        for my $loc (sort {$a->assembly cmp $b->assembly}
                        @{ $self->qnames_locators()->{$qname} }) {
            my $asm = $loc->assembly();
            if(!$filter_atype || ($filter_atype eq $asm)) {
                $output_string .= join("\t",
                    $loc->qname(), # take it from $loc to avoid case confusion
                    $loc->qtype(),
                    join(',', @{$loc->component_names()}),
                    $loc->assembly())."\n";
                $count++;
            }
        }
        if(!$count) {
            $output_string .= "$qname\n"; # no matches for this qname
        }
    }

    return $output_string;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

