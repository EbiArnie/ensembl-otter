
### Bio::Otter::Lace::ProcessGFF

package Bio::Otter::Lace::ProcessGFF;

use strict;
use warnings;
use Carp;
use Text::ParseWords qw{ quotewords };
use Hum::Ace::SubSeq;
use Hum::Ace::Method;
use Hum::Ace::Locus;

{
    ### Should add this to otter_config
    ### or parse it from the Zmap styles
    my %evidence_type = (
        vertebrate_mRNA  => 'cDNA',
        vertebrate_ncRNA => 'ncRNA',
        BLASTX           => 'Protein',
        SwissProt        => 'Protein',
        TrEMBL           => 'Protein',
        OTF_ncRNA        => 'ncRNA',
        OTF_EST          => 'EST',
        OTF_mRNA         => 'cDNA',
        OTF_Protein      => 'Protein',
        Ens_cDNA         => 'cDNA',
    );


    sub store_hit_data_from_gff {
        my ($dbh, $gff_file) = @_;
    
        my $store = $dbh->prepare(q{
            INSERT OR REPLACE INTO accession_info (accession_sv
                  , taxon_id
                  , evi_type
                  , description
                  , source_db
                  , length)
            VALUES (?,?,?,?,?,?)
        });
    
        $dbh->begin_work;
        open my $gff_fh, '<', $gff_file or confess "Can't read GFF file '$gff_file'; $!";
        while (<$gff_fh>) {
            next if /^\s*#/;
            my ($seq_name, $source, $feat_type, $start, $end, $score, $strand, $frame, $attrib)
                = parse_gff_line($_);
            next unless $attrib->{'Name'};
            $store->execute(
                $attrib->{'Name'},
                $attrib->{'Taxon_ID'},
                substr($source, 0, 4) eq 'EST_' ? 'EST' : $evidence_type{$source},
                $attrib->{'Description'},
                $attrib->{'DB_Name'},
                $attrib->{'Length'},
                );
        }
        close $gff_fh or confess "Error reading GFF file '$gff_file'; $!";

        $dbh->commit;
    }
}

sub make_ace_transcripts_from_gff {
    my ($gff_file) = @_;
    
    my (%tsct, %locus_by_name, $gene_method, $coding_gene_method);
    
    open my $gff_fh, '<', $gff_file or confess "Can't read GFF file '$gff_file'; $!";
    my $length;     ### HACK: Should truncate to Slice on server
    
    while (<$gff_fh>) {
        if (/^\s*#/) {
            if (/^##sequence-region (\S+) (\d+) (\d+)/) {
                $length = $3 - $2 + 1;
            }
            next;
        }
        my ($seq_name, $source, $feat_type, $start, $end, $score, $strand, $frame, $attrib)
            = parse_gff_line($_);
        my $name = $attrib->{'Name'};
        next unless $name;
        unless ($length) {
            confess "length not calculated from GFF header";
        }
        my ($sub);
        unless ($sub = $tsct{$name}) {
            $sub = Hum::Ace::SubSeq->new;
            unless ($gene_method) {
                $gene_method = Hum::Ace::Method->new;
                $gene_method->name($source);
                $coding_gene_method = Hum::Ace::Method->new;
                $coding_gene_method->name($source);
                $coding_gene_method->coding(1);
            }
            $sub->name($name);
            $sub->GeneMethod($gene_method);
            $tsct{$name} = $sub;
        }
        
        if ($feat_type eq 'Sequence') {
            $sub->strand($strand eq '-' ? -1 : 1);
            if (my $stable = $attrib->{'Stable_ID'}) {
                $sub->otter_id($stable);
            }
            if (my $loc_name = $attrib->{'Locus'}) {
                my $locus = $locus_by_name{$loc_name};
                unless ($locus) {
                    $locus = $locus_by_name{$loc_name}
                        = Hum::Ace::Locus->new;
                    $locus->name($loc_name);
                    if (my $stable = $attrib->{'Locus_Stable_ID'}) {
                        $locus->otter_id($stable);
                    }
                }
                $sub->Locus($locus);
            }
        }
        elsif ($feat_type eq 'exon') {
            # Truncate exons to slice
            next if $end < 0;
            next if $start > $length;
            $start = 1 if $start < 0;
            $end = $length if $end > $length;
            
            my $exon = $sub->new_Exon;
            $exon->start($start);
            $exon->end($end);
            if (my $stable = $attrib->{'Stable_ID'}) {
                $exon->otter_id($stable);
            }
        }
        elsif ($feat_type eq 'CDS') {            
            # Don't attempt truncated CDS
            next if $start < 0;
            next if $end > $length;

            $sub->translation_region($start, $end);
            $sub->GeneMethod($coding_gene_method);
            if (my $stable = $attrib->{'Stable_ID'}) {
                $sub->translation_otter_id($stable);
            }
        }
    }
    
    my (@ok_tsct);
    while (my ($name, $sub) = each %tsct) {
        eval {$sub->validate};
        if ($@) {
            warn "Error in SubSeq '$name':\n$@";
        }
        else {
            push(@ok_tsct, $sub);
        }
    }
    return @ok_tsct;
}

sub parse_gff_line {
    my ($line) = @_;
    
    chomp($line);
    my ($seq_name, $source, $feat_type, $start, $end, $score, $strand, $frame, $group)
        = split(/\t/, $line, 9);
    my $attrib = {};
    # The "1" argument to quotewords tells it to keep the quotes
    # so that we preserve the fields for the next level of parsing
    foreach my $tag_val (quotewords('\s*;\s*', 1, $group)) {
        # The "0" argument means that we now discard the quotes
        my ($tag, @values) = quotewords('\s+', 0, $tag_val);
        $attrib->{$tag} = "@values";
    }
    return ($seq_name, $source, $feat_type, $start, $end, $score, $strand, $frame, $attrib);
}

# $gff->{seqname}, $gff->{source}, $gff->{feature}, $gff->{start},
# $gff->{end},     $gff->{score},  $gff->{strand},  $gff->{frame},


1;

__END__

=head1 NAME - Bio::Otter::Lace::ProcessGFF

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

   