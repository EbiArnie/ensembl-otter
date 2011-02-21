### Bio::Vega::Utils::EnsEMBL2GFF

package Bio::Vega::Utils::EnsEMBL2GFF;

use strict;
use warnings;

use Bio::Vega::Utils::GFF;

# This module allows conversion of ensembl/otter objects to GFF by inserting
# to_gff (and supporting _gff_hash) methods into the necessary feature classes

## no critic(Modules::ProhibitMultiplePackages)

{

    package Bio::EnsEMBL::Slice;

    use Bio::EnsEMBL::Utils::Exception qw(verbose);

    sub gff_header {
        my ($self, %args) = @_;

        my $include_dna = $args{include_dna};
        my $rebase      = $args{rebase};
        my $seqname     = $args{gff_seqname} || $self->seq_region_name;

        my $name  = $rebase ? $seqname . '_' . $self->start . '-' . $self->end : $seqname;
        my $start = $rebase ? 1                                                : $self->start;
        my $end   = $rebase ? $self->length                                    : $self->end;

        return Bio::Vega::Utils::GFF::gff_header($name, $start, $end, ($include_dna ? $self->seq : undef),);
    }

    sub to_gff {

        # convert an entire slice to GFF, pass in the analyses and feature types
        # you're interested in, e.g.:
        #
        # print $slice->to_gff(
        #     analyses       => ['RepeatMasker', 'vertrna'],
        #     feature_types  => ['RepeatFeatures', 'DnaAlignFeatures', 'SimpleFeatures'],
        # );

        my ($self, %args) = @_;

        my $analyses = $args{analyses} || ['']; # if we're not given any analyses, search for features from all analyses
        my $feature_types  = $args{feature_types};
        my $verbose        = $args{verbose};
        my $target_slice   = $args{target_slice} || $self;
        my $common_slice   = $args{common_slice};
        my $rebase         = $args{rebase};
        my $gff_source     = $args{gff_source};
        my $gff_seqname    = $args{gff_seqname};

        my $sources_to_types = $args{sources_to_types};

        my $gff = '';

        # grab features of each type we're interested in

        for my $feature_type (@$feature_types) {

            my $method = 'get_all_' . $feature_type;

            unless ($self->can($method)) {
                warn "There is no method to retrieve $feature_type from a slice";
                next;
            }

            for my $analysis (@$analyses) {

                my $features = $self->$method($analysis);

                if ($verbose && scalar(@$features)) {
                    print "Found " . scalar(@$features) . " $feature_type from $analysis\n";
                }

                for my $feature (@$features) {

                    if ($feature->can('to_gff')) {

                        if ($common_slice) {

                            # if we're passed a common slice we need to give it to each feature
                            # and then transfer from this slice to the target slice

                            $feature->slice($common_slice);

                            my $id = $feature->display_id;

                            my $old_verbose_level = verbose();
                            verbose(0);

                            $feature = $feature->transfer($target_slice);

                            verbose($old_verbose_level);

                            unless ($feature) {
                                print "Failed to transform feature: $id\n" if $verbose;
                                next;
                            }
                        }

                        if ($feature->isa('Bio::EnsEMBL::Gene')) {
                            foreach my $transcript (@{ $feature->get_all_Transcripts }) {
                                my $truncated = $_->truncate_to_Slice($target_slice);
                                print "Truncated transcript: " . $_->display_id . "\n" if $truncated && $verbose;
                            }
                        }
                        elsif ($feature->isa('Bio::EnsEMBL::Transcript')) {
                            my $truncated = $feature->truncate_to_Slice($target_slice);
                            print "Truncated transcript: " . $feature->display_id . "\n" if $truncated && $verbose;
                        }

                        $gff .=
                            $feature->to_gff(rebase => $rebase,
                                             gff_source => $gff_source,
                                             gff_seqname => $gff_seqname);

                        if ($sources_to_types) {

                            # If we are passed a sources_to_types hashref, then as we identify the types of
                            # features each analysis can create, fill in the hash for the caller. This is
                            # required by enzembl, but other users can just ignore this parameter.

                            my $source = $feature->_gff_hash->{source};

                            if ($sources_to_types->{$source}) {
                                unless ($sources_to_types->{$source} eq $feature_type) {
                                    die "Can't have multiple gff sources from one analysis:\n"
                                      . "('$analysis' seems to have both '"
                                      . $sources_to_types->{$source}
                                      . "' and '$feature_type')\n";
                                }
                            }
                            else {
                                $sources_to_types->{$source} = $feature_type;
                            }
                        }
                    }
                    else {
                        warn "no to_gff method in $feature_type";
                    }
                }
            }
        }

        # remove any empty lines resulting from truncated transcripts etc.
        $gff =~ s/\n\s*\n/\n/g;

        return $gff;
    }
}

{

    package Bio::EnsEMBL::Feature;

    sub to_gff {

        my ($self, %args) = @_;

        # This parameter is assumed to be a hashref which includes extra attributes you'd
        # like to have appended onto the gff line for the feature
        my $extra_attrs = $args{extra_attrs};

        my $gff = $self->_gff_hash(%args);

        $gff->{score}  = '.' unless defined $gff->{score};
        $gff->{strand} = '.' unless defined $gff->{strand};
        $gff->{frame}  = '.' unless defined $gff->{frame};

        # order as per GFF spec: http://www.sanger.ac.uk/Software/formats/GFF/GFF_Spec.shtml

        my $gff_str = join("\t",
            $gff->{seqname}, $gff->{source}, $gff->{feature}, $gff->{start},
            $gff->{end},     $gff->{score},  $gff->{strand},  $gff->{frame},
        );

        if ($extra_attrs) {

            # combine the extra attributes with any existing ones (duplicate keys will get squashed!)
            $gff->{attributes} = {} unless defined $gff->{attributes};
            @{ $gff->{attributes} }{ keys %$extra_attrs } = values %$extra_attrs;
        }

        if ($gff->{attributes}) {

            my @attrs = map { $_ . ' ' . $gff->{attributes}->{$_} } keys %{ $gff->{attributes} };

            $gff_str .= "\t" . join(' ; ', @attrs);
        }
        $gff_str .= "\n";

        return $gff_str;
    }

    sub _gff_hash {
        my ($self, %args) = @_;

        my $rebase      = $args{rebase};
        my $gff_seqname = $args{gff_seqname} || $self->slice->seq_region_name;
        my $gff_source  = $args{gff_source} || $self->_gff_source;

        my $seqname = $rebase ? $gff_seqname . '_' . $self->slice->start . '-' . $self->slice->end : $gff_seqname;
        my $start = $rebase ? $self->start : $self->seq_region_start;
        my $end   = $rebase ? $self->end   : $self->seq_region_end;

        my $gff = {
            seqname => $seqname,
            source  => $gff_source,
            feature => $self->_gff_feature,
            start   => $start,
            end     => $end,
            strand  => ($self->strand == 1 ? '+' : ($self->strand == -1 ? '-' : '.'))
        };

        return $gff;
    }

    sub _gff_source {
        my ($self) = @_;

        if ($self->analysis) {
            return $self->analysis->gff_source
              || $self->analysis->logic_name;
        }
        else {
            return ref($self);
        }
    }

    sub _gff_feature {
        my ($self) = @_;

        return ($self->analysis && $self->analysis->gff_feature)
          || 'misc_feature';
    }
}

{

    package Bio::EnsEMBL::SimpleFeature;

    sub _gff_hash {
        my ($self, @args) = @_;

        my $gff = $self->SUPER::_gff_hash(@args);

        $gff->{score}   = $self->score;
        $gff->{feature} = 'misc_feature';

        if ($self->display_label) {
            $gff->{attributes}->{Name} = '"' . $self->display_label . '"';
        }

        return $gff;
    }
}

{

    package Bio::EnsEMBL::FeaturePair;

    sub _gff_hash {
        my ($self, %args) = @_;

        my $rebase = $args{rebase};

        my $gap_string = '';

        my @fps = $self->ungapped_features;

        if (@fps > 1) {
            my @gaps =
              map {
                join(' ',
                    ($rebase ? $_->start : $_->seq_region_start),
                    ($rebase ? $_->end   : $_->seq_region_end),
                    $_->hstart, $_->hend)
              } @fps;
            $gap_string = join(',', @gaps);
        }

        my $gff = $self->SUPER::_gff_hash(%args);

        $gff->{score} = $self->score;
        $gff->{feature} = ($self->analysis && $self->analysis->gff_feature) || 'similarity';

        my $name = $self->hseqname;

        $gff->{'attributes'}{'Class'}     = qq("Sequence");
        $gff->{'attributes'}{'Name'}      = qq{"$name"};
        $gff->{'attributes'}{'Align'}     = $self->hstart . ' ' . $self->hend . ' ' . ($self->hstrand == -1 ? '-' : '+');
        $gff->{'attributes'}{'percentID'} = $self->percent_id;

        if ($gap_string) {
            $gff->{'attributes'}->{'Gaps'} = qq("$gap_string");
        }

        return $gff;
    }
}

{

    package Bio::EnsEMBL::DnaPepAlignFeature;

    sub _gff_hash {
        my ($self, @args) = @_;

        my $gff = $self->SUPER::_gff_hash(@args);
        $gff->{attributes}->{Class} = qq("Protein");
        return $gff;
    }
}

{

    package Bio::EnsEMBL::Gene;

    # sub _gff_hash {
    #     my ($self, %args) = @_;
    #     
    #     my $gff = $self->SUPER::_gff_hash(%args);
    #     $gff->{'feature'} = 'Locus';
    #     $gff->{'attributes'}{'Class'} = qq{"Locus"};
    #     if (my $stable = $self->stable_id) {
    #         $gff->{'attributes'}{'Stable_ID'} = qq{"$stable"};
    #     }
    #     return $gff;
    # }

    sub to_gff {
        my ($self, %args) = @_;

        # Get URL parameter
        # Choose ensembl or Pfam style naming and URL filling

        my $allowed_transcript_analyses_hash =
          $args{'transcript_analyses'}
          ? { map { $_ => 1 } split(/,/, $args{'transcript_analyses'}) }
          : '';
        my $allowed_translation_xref_db_hash =
          $args{'translation_xref_dbs'}
          ? { map { $_ => 1 } split(/,/, $args{'translation_xref_dbs'}) }
          : '';

        # filter the transcripts according to the transcript_analyses & translation_xref_db params

        my @tsct_for_gff;
        for my $tsct (@{ $self->get_all_Transcripts }) {

            if (  !$allowed_transcript_analyses_hash
                || $allowed_transcript_analyses_hash->{ $tsct->analysis->logic_name })
            {

                my $allowed = !$allowed_translation_xref_db_hash;

                unless ($allowed) {
                    if (my $trl = $tsct->translation) {
                        foreach my $xr (@{ $trl->get_all_DBEntries }) {
                            if ($allowed_translation_xref_db_hash->{ $xr->dbname }) {
                                $allowed = 1;
                                last;
                            }
                        }
                    }
                }

                if ($allowed) {
                    push(@tsct_for_gff, $tsct);
                }
            }
        }

        # my $gff_string = $self->SUPER::to_gff(%args);
        my $gff_string = '';
        if (@tsct_for_gff) {
            my $extra_attrs = $self->make_extra_attributes(%args);
            if (my $sgn = delete( $extra_attrs->{'synthetic_gene_name'} )) {
                $args{'gene_name'} = $sgn;
            }
            foreach my $tsct (@tsct_for_gff) {
                $gff_string .= $tsct->to_gff(%args, extra_attrs => $extra_attrs);
            }
        }
        return $gff_string;
    }
    
    my $gene_count = 0;
    sub make_extra_attributes {
        my ($self, %args) = @_;
        
        my $gene_numeric_id = $self->dbID || ++$gene_count;
        
        my $extra_attrs = {};
        
        if (my $stable = $self->stable_id) {
            $extra_attrs->{'Locus_Stable_ID'} = qq{"$stable"};
        }
        
        if (my $url_fmt = $args{'url_string'}) {
            if ($url_fmt =~ /pfam\.sanger\.ac\.uk/) {
                foreach my $xr (@{$self->get_all_DBEntries}) {
                    if ($xr->dbname() eq 'PFAM') {
                        $extra_attrs->{'synthetic_gene_name'} = $xr->display_id;
                        my $name = sprintf "%s.%d", $xr->display_id, $gene_numeric_id;
                        my $url = sprintf $url_fmt, $xr->primary_id;
                        $extra_attrs->{'Locus'} = qq{"$name"};
                        $extra_attrs->{'URL'}   = qq{"$url"};
                    }
                }
                unless (keys %$extra_attrs) {
                    die "Couldn't find PFAM XRef";
                }
            }
            else {
                # Assume it is an ensembl gene
                my $url = sprintf $url_fmt, $self->stable_id;
                $extra_attrs->{'URL'} = qq{"$url"};
            }
        }
        
        unless ($extra_attrs->{'Locus'}) {
            if (my $xr = $self->display_xref) {
                $extra_attrs->{'synthetic_gene_name'} = $xr->display_id;
                my $name = sprintf "%s.%d", $xr->display_id, $gene_numeric_id;
                $extra_attrs->{'Locus'} = qq{"$name"};
            }
            elsif (my $stable = $self->stable_id) {
                $extra_attrs->{'Locus'} = qq{"$stable"};
            }
            else {
                my $disp = $self->display_id;
                $extra_attrs->{'Locus'} = qq{"$disp"};
            }
        }
        
        return $extra_attrs;
    }
}

{

    package Bio::EnsEMBL::Transcript;

    my $tsct_count = 0;
    sub _gff_hash {
        my ($self, %args) = @_;

        my $gff = $self->SUPER::_gff_hash(%args);

        $gff->{'feature'} = 'Sequence';
        $gff->{'attributes'}{'Class'} = qq{"Sequence"};
        if (my $stable = $self->stable_id) {
            $gff->{'attributes'}{'Stable_ID'} = qq{"$stable"};
        }
        
        my $tsct_numeric_id = $self->dbID || ++$tsct_count;
        # Each transcript must have a (unique) name for GFF grouping purposes
        my $name;
        if (my $gene_name = $args{'gene_name'}) {
            $name = "$gene_name.$tsct_numeric_id";
        }
        elsif (my $xr = $self->display_xref) {
            $name = $xr->display_id;
        }
        elsif (my $stable = $self->stable_id) {
            $name = $stable;
        }
        elsif (my $ana = $self->analysis) {
            $name = sprintf "%s.%d", $ana->logic_name, $tsct_numeric_id;
        }
        $gff->{attributes}->{Name} = qq{"$name"};
        return $gff;
    }

    my %ens_phase_to_gff_frame = (
        0  => 0,
        1  => 2,
        2  => 1,
        -1 => 0,    # Start phase is (always?) -1 for first coding exon
    );

    sub to_gff {
        my ($self, %args) = @_;

        my $rebase = $args{rebase};
        

        return '' unless $self->get_all_Exons && @{ $self->get_all_Exons };

        ### hack to help differentiate the various otter transcripts
        if ($self->analysis && $self->analysis->logic_name eq 'Otter') {
            $self->analysis->gff_source('Otter_' . $self->biotype);
        }

        my $gff = $self->SUPER::to_gff(%args);
        my $gff_hash = $self->_gff_hash(%args);
        
        # $name is already double-quoted
        my $name = $gff_hash->{'attributes'}{'Name'};

        # add gff lines for each of the introns and exons
        # (adding lines for both seems a bit redundant to me, but zmap seems to like it!)
        foreach my $feat (@{ $self->get_all_Exons }, @{ $self->get_all_Introns }) {

            # exons and introns don't have analyses attached, so temporarily give them the transcript's one
            $feat->analysis($self->analysis);

            # and add the feature's gff line to our string, including the sequence name information as an attribute
            $gff .= $feat->to_gff(%args, extra_attrs => { Name => $name });

            # to be on the safe side, get rid of the analysis we temporarily attached
            # (someone might rely on there not being one later)
            $feat->analysis(undef);
        }

        if (my $tsl = $self->translation) {

            # build up the CDS line - it's not really worth creating a Translation->to_gff method, as most
            # of the fields are derived from the Transcript and Translation doesn't inherit from Feature

            my $start = $self->coding_region_start;
            $start += $self->slice->start - 1 unless $rebase;

            my $end = $self->coding_region_end;
            $end += $self->slice->start - 1 unless $rebase;
            
            my $frame;
            if (defined(my $phase = $tsl->start_Exon->phase)) {
                $frame = $ens_phase_to_gff_frame{$phase};
            }
            else {
                $frame = 0;
            }
            
            my $attrib_str = qq{Class "Sequence" ; Name $name};
            if (my $stable = $tsl->stable_id) {
                $attrib_str .= qq{ ; Stable_ID "$stable"};
            }
            $gff .= join(
                "\t",
                $gff_hash->{'seqname'},
                $gff_hash->{'source'},
                'CDS',    # feature
                $start,
                $end,
                '.',      # score
                $gff_hash->{'strand'},
                $frame,
                $attrib_str,
            ) . "\n";
        }

        return $gff;
    }

    sub get_all_Exons_ref {
        my ($self) = @_;

        $self->get_all_Exons;
        if (my $ref = $self->{'_trans_exon_array'}) {
            return $ref;
        }
        else {
            $self->throw("'_trans_exon_array' not set");
            return;    # unreached, but quietens "perlcritic --stern"
        }
    }

    sub truncate_to_Slice {
        my ($self, $slice) = @_;

        # start and end exon are set to zero so that we can
        # safely use them in "==" without generating warnings
        # as we loop through the list of exons.
        ### Not used until we enable translation truncating
        my $start_exon = 0;
        my $end_exon   = 0;
        my ($tsl);
        if ($tsl = $self->translation) {
            $start_exon = $tsl->start_Exon;
            $end_exon   = $tsl->end_Exon;
        }
        my $exons_truncated     = 0;
        my $in_translation_zone = 0;
        my $slice_length        = $slice->length;

        # Ref to list of exons for inplace editing
        my $ex_list = $self->get_all_Exons_ref;

        for (my $i = 0; $i < @$ex_list;) {
            my $exon       = $ex_list->[$i];
            my $exon_start = $exon->start;
            my $exon_end   = $exon->end;

            # now compare slice names instead of slice references
            # slice references can be different not the slice names
            if (   $exon->slice->name ne $slice->name
                or $exon_end < 1
                or $exon_start > $slice_length)
            {

                #warn "removing exon that is off slice";
                splice(@$ex_list, $i, 1);
                $exons_truncated++;
            }
            else {

                #printf STDERR
                #    "Checking if exon %s is within slice %s of length %d\n"
                #    . "  being attached to %s and extending from %d to %d\n",
                #    $exon->stable_id, $slice, $slice_length, $exon->contig, $exon_start, $exon_end;
                $i++;
                my $trunc_flag = 0;
                if ($exon->start < 1) {

                    #warn "truncating exon that overlaps start of slice";
                    $trunc_flag = 1;
                    $exon->start(1);
                }
                if ($exon->end > $slice_length) {

                    #warn "truncating exon that overlaps end of slice";
                    $trunc_flag = 1;
                    $exon->end($slice_length);
                }
                $exons_truncated++ if $trunc_flag;
            }
        }

        ### Hack until we fiddle with translation stuff
        #        if ($exons_truncated) {
        #            $self->{'translation'}     = undef;
        #            $self->{'_translation_id'} = undef;
        #            my $attrib = $self->get_all_Attributes;
        #            for ( my $i = 0 ; $i < @$attrib ; ) {
        #                my $this = $attrib->[$i];
        #
        #                # Should not have CDS start/end not found attributes
        #                # if there is no CDS!
        #                if ( $this->code =~ /^cds_(start|end)_NF$/ ) {
        #                    splice( @$attrib, $i, 1 );
        #                }
        #                else {
        #                    $i++;
        #                }
        #            }
        #        }

        $self->recalculate_coordinates;

        return $exons_truncated;
    }
}

{

    package Bio::EnsEMBL::Exon;

    sub _gff_hash {
        my ($self, @args) = @_;
        my $gff = $self->SUPER::_gff_hash(@args);
        $gff->{'feature'} = 'exon';
        $gff->{'attributes'}{'Class'} = qq{"Sequence"};
        if (my $stable = $self->stable_id) {
            $gff->{'attributes'}{'Stable_ID'} = qq{"$stable"};
        }
        return $gff;
    }
}

{

    package Bio::EnsEMBL::Intron;

    sub _gff_hash {
        my ($self, @args) = @_;
        my $gff = $self->SUPER::_gff_hash(@args);
        $gff->{feature} = 'intron';
        $gff->{attributes}->{Class} = qq("Sequence");
        return $gff;
    }
}

{

    package Bio::EnsEMBL::Variation::VariationFeature;

    ### Should unify with Gene URL stuff.
    my $url_format = 'http://www.ensembl.org/Homo_sapiens/Variation/Summary?v=%s';

    sub _gff_hash {
        my ($self, @args) = @_;

        my $name   = $self->variation->name;
        my $allele = $self->allele_string;
        my $url    = sprintf $url_format, $name;

        my $gff = $self->SUPER::_gff_hash(@args);
        my ($start, $end) = @{$gff}{qw( start end )};
        if ($start > $end) {
            @{$gff}{qw( start end )} = ($end, $start);
        }

        $gff->{attributes}->{Name} = qq("$name - $allele");
        $gff->{attributes}->{URL}  = qq("$url");

        return $gff;
    }

    sub _gff_source {
        return 'variation';
    }
}

{

    package Bio::EnsEMBL::RepeatFeature;

    sub _gff_hash {
        my ($self, @args) = @_;
        my $gff = $self->SUPER::_gff_hash(@args);

        if ($self->analysis->logic_name =~ /RepeatMasker/i) {
            my $class = $self->repeat_consensus->repeat_class;

            if ($class =~ /LINE/) {
                $gff->{source} .= '_LINE';
            }
            elsif ($class =~ /SINE/) {
                $gff->{source} .= '_SINE';
            }

            $gff->{feature} = 'similarity';
            $gff->{score}   = $self->score;

            $gff->{attributes}->{Class} = qq("Motif");
            $gff->{attributes}->{Name}  = '"' . $self->repeat_consensus->name . '"';
            $gff->{attributes}->{Align} = $self->hstart . ' ' . $self->hend . ' ' . ($self->hstrand == -1 ? '-' : '+');
        }
        elsif ($self->analysis->logic_name =~ /trf/i) {
            $gff->{feature} = 'misc_feature';
            $gff->{score}   = $self->score;
            my $cons   = $self->repeat_consensus->repeat_consensus;
            my $len    = length($cons);
            my $copies = sprintf "%.1f", ($self->end - $self->start + 1) / $len;
            $gff->{attributes}->{Name} = qq("$copies copies $len mer $cons");
        }

        return $gff;
    }
}

{

    package Bio::EnsEMBL::Map::DitagFeature;

    sub to_gff {
        my ($self, @args) = @_;

        my ($start, $end, $hstart, $hend, $cigar_string);

        if ($self->ditag_side eq "F") {
            $start        = $self->start;
            $end          = $self->end;
            $hstart       = $self->hit_start;
            $hend         = $self->hit_end;
            $cigar_string = $self->cigar_line;
        }
        elsif ($self->ditag_side eq "L") {

            # we only return some GFF for L side ditags, as the R side one will be included here

            my ($df1, $df2);
            eval {
                ($df1, $df2) =
                  @{ $self->adaptor->fetch_all_by_ditagID($self->ditag_id, $self->ditag_pair_id, $self->analysis->dbID)
                  };
            };

            if ($@ || !defined($df1) || !defined($df2)) {
                die "Failed to find matching ditag pair: $@";
            }

            die "Mismatching strands on in a ditag feature pair" unless $df1->strand == $df2->strand;

            ($df1, $df2) = ($df2, $df1) if $df1->start > $df2->start;

            $start = $df1->start;
            $end   = $df2->end;
            my $fw = $df1->strand == 1;
            $hstart = $fw ? $df1->hit_start : $df2->hit_start;
            $hend   = $fw ? $df2->hit_end   : $df1->hit_end;

            my $insert = $df2->start - $df1->end - 1;

            # XXX: gr5: this generates GFF slightly differently from the ace server for
            # instances where the hit_end of df1 and the hit_start of df2 are the same
            # e.g. 1-19, 19-37, which seems to occur fairly often. I don't really know
            # what this means (do the pair share a base of the alignment?), but I do not
            # cope with it here, and the GFF will show that such a pair have hit coords
            # 1-19, 20-38. The coords on the genomic sequence will be correct though.

            $cigar_string = $df1->cigar_line . $insert . 'I' . $df2->cigar_line;

        }
        else {

            # we are the R side ditag feature and we don't generate anything

            return '';
        }

        # fake up a DAF which we then convert to GFF as this is the format produced by acedb

        my $daf = Bio::EnsEMBL::DnaDnaAlignFeature->new(
            -slice        => $self->slice,
            -start        => $start - $self->slice->start + 1,
            -end          => $end - $self->slice->start + 1,
            -strand       => $self->strand,
            -hseqname     => $self->ditag->type . ':' . $self->ditag->name,
            -hstart       => $hstart,
            -hend         => $hend,
            -hstrand      => $self->hit_strand,
            -analysis     => $self->analysis,
            -cigar_string => $cigar_string,
        );

        return $daf->to_gff(@args);
    }

 #    sub _gff_hash {
 #
 #        my ($self, @args) = @_;
 #        my $gff  = $self->SUPER::_gff_hash(@args);
 #
 #        $gff->{feature} = 'similarity';
 #
 #        $gff->{attributes}->{Class} = qq("Sequence");
 #        $gff->{attributes}->{Name} = '"'.$self->ditag->type.':'.$self->ditag->name.'"';
 #        $gff->{attributes}->{Align} = $self->hit_start.' '.$self->hit_end.' '.( $self->hit_strand == -1 ? '-' : '+' );
 #
 #        return $gff;
 #    }

}

# my ($hit_description, $db_name, $hseq_prefix);
# if (   $self->can('get_HitDescription')
#     && ($hit_description = $self->get_HitDescription)
#     && ($db_name         = $hit_description->db_name)
#     && ($hseq_prefix     = $db_prefix->{$db_name}))
# {
#     $name = "$hseq_prefix:$name";
#     $gff->{'attributes'}{''}
# }


{
    package Bio::Vega::DnaDnaAlignFeature;

    # To avoid copy/pasting code:
    *{_gff_hash} = *{Bio::Vega::DnaPepAlignFeature::_gff_hash}
}

{
    package Bio::Vega::DnaPepAlignFeature;

    sub _gff_hash {
        my ($self, @args) = @_;

        my $gff = $self->SUPER::_gff_hash(@args);

        my $hd = $self->get_HitDescription;
        $gff->{'attributes'}{'Length'}   = $hd->hit_length;
        $gff->{'attributes'}{'Taxon_ID'} = $hd->taxon_id;
        $gff->{'attributes'}{'DB_Name'}  = sprintf(q{"%s"}, $hd->db_name);
        if (my $desc = $hd->description) {
            $desc =~ s/"/\\"/g;
            $gff->{'attributes'}{'Description'} = qq{"$desc"};
        }

        return $gff;
    }
}

1;

__END__

=head1 NAME - Bio::Vega::Utils::EnsEMBL2GFF 

=head1 SYNOPSIS

Inserts to_gff (and supporting _gff_hash) methods into various EnsEMBL and Otter classes, allowing
them to be converted to GFF by calling C<$object->to_gff>. You can also get the GFF for an entire slice
by calling C<$slice->to_gff>, passing in lists of the analyses and feature types you're interested in.

=head1 AUTHOR

Graham Ritchie B<email> gr5@sanger.ac.uk

