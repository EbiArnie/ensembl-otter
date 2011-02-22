#!/usr/bin/env perl

=head1 NAME

unhide_gene.pl

=head1 SYNOPSIS

unhide_gene.pl

=head1 DESCRIPTION

This script is used to make a gene visible again, by setting the is_current flag
(and those of its child transcripts and exons).

The most recently modified non_current gene will be rendered visible.

Must provide a list of gene stable ids.

Here is an example commandline:

./unhide_gene.pl -dataset mouse -stable_id OTTMUSG00000016621,OTTMUSG00000001145

=head1 OPTIONS

    -dataset    dataset to use, e.g. human

    -stable_id  list of gene stable ids, comma separated
    -force      proceed without user confirmation
    -help|h     displays this documentation with PERLDOC

=head1 CONTACT

Michael Gray B<email> mg13@sanger.ac.uk

=cut

use strict;
use warnings;

use Getopt::Long;

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::Otter::Lace::Defaults;

{
    my $dataset_name;
    my @ids;
    my $force;

    my $usage = sub { exec( 'perldoc', $0 ); };

    GetOptions(
        'dataset=s'     => \$dataset_name,
        'stable_id=s'   => \@ids,
        'force'         => \$force,
        'h|help!'       => $usage,
    )
    or $usage->();

    $usage->() unless ($dataset_name and @ids);

    local $0 = 'otterlace';     # for access to test_human

    # Client communicates with otter HTTP server
    my $cl = Bio::Otter::Lace::Defaults::make_Client();
    
    # DataSet interacts directly with an otter database
    my $ds = $cl->get_DataSet_by_name($dataset_name);

    # falls over on human_test, in _attach_DNA_DBAdaptor
    # my $otter_dba = $ds->get_cached_DBAdaptor;

    my $dba = $ds->make_Vega_DBAdaptor;

    my $gene_adaptor = $dba->get_GeneAdaptor;

    my @sids;
    foreach my $id_list (@ids) { push(@sids , split(/,/x, $id_list)); }

  GSI: foreach my $id (@sids) {
    
      my $gene = $gene_adaptor->fetch_latest_by_stable_id($id);
      if (!$gene) {
          print STDOUT "Cannot fetch gene stable id $id\n";
          next GSI;
      }

      printf STDOUT ("%s ID:%d Slice:%s <%d-%d:%d> Biotype:%s Source:%s is_current:%s\n",
                     $id, $gene->dbID,
                     $gene->seq_region_name, $gene->seq_region_start, $gene->seq_region_end, $gene->strand,
                     $gene->biotype, $gene->source, $gene->is_current ? 'yes':'no',
          );

      if ($gene->is_current) {
          print STDOUT "Gene $id already current, cannot unhide\n";
          next GSI;
      }

      if ($force || &proceed() =~ /^y$|^yes$/x ) {

          my $ok = eval {
              $gene_adaptor->unhide_db_gene($gene);
              1;
          };

          if ($ok) {
              print STDOUT "gene_stable_id $id is now visible\n";
          } else {
              warning("Cannot unhide $id\n$@\n");
          }
      }
  } # GSI

    exit 0;
}

sub proceed {
    print STDOUT "make this gene visible ? [no]";
    my $answer = <STDIN>;chomp $answer;
    $answer ||= 'no';
    return $answer;
}

__END__
