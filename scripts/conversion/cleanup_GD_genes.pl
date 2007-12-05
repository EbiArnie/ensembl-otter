#!/usr/local/bin/perl

=head1 NAME

cleanup_GD_genes.pl - identify CORF genes and transcripts and set analysis_ids
                    - identify and deelete redundant GD genes

=head1 SYNOPSIS

cleanup_GD_genes.pl [options]

General options:
    --conffile, --conf=FILE             read parameters from FILE
                                        (default: conf/Conversion.ini)

    --dbname, db_name=NAME              use database NAME
    --host, --dbhost, --db_host=HOST    use database host HOST
    --port, --dbport, --db_port=PORT    use database port PORT
    --user, --dbuser, --db_user=USER    use database username USER
    --pass, --dbpass, --db_pass=PASS    use database passwort PASS
    --logfile, --log=FILE               log to FILE (default: *STDOUT)
    --logpath=PATH                      write logfile to PATH (default: .)
    --logappend, --log_append           append to logfile (default: truncate)
    -v, --verbose                       verbose logging (default: false)
    -i, --interactive=0|1               run script interactively (default: true)
    -n, --dry_run, --dry=0|1            don't write results to database
    -h, --help, -?                      print help (this message)

Specific options:

    --logic_name=NAME                   logicname for CORF genes (defaults to otter_corf)
    --chromosomes=LIST                  List of chromosomes to read (not working)
    --delete=FILE                       file for stable IDs of GD genes to delete
                                        (defaults to GD_IDs_togo.txt)

=head1 DESCRIPTION

This script identifies all CORF genes in a Vega database and sets the analysis_id
for each gene and its transcripts. It creates a file of these redundant IDs, be
they CORF or Havana, which can be used to delete them from the database (either
during this run or later).
It must be run after the vega xrefs have been set.

Logic is:

(i) retrieve each gene with a GD: prefix on its name (gene.display_xref)
(ii) if that gene has at least one transcript with a hidden_remark of 'corf',
or a remark that starts with the term 'corf', then set the analysis_id of it
and its transcripts, to otter_corf.

Reports on other GD: loci that have other remarks containing 'corf'.
Verbosely reports on non GD: loci that have remarks containing 'corf'.

(iii) examine all GD: genes to identify redundant ones - ie have an
overlapping Havana gene. Generate a file of stable IDs and use this to
delete the genes by calling delete_by_stable_id.pl

Verbosely report numbers of GD genes with a gomi remark (for jla1).

TO DO: Steps (ii) and (iii) could be combined to save (a little bit of)
run time ?

=head1 LICENCE

This code is distributed under an Apache style licence:
Please see http://www.ensembl.org/code_licence.html for details

=head1 AUTHOR

Steve Trevanion <pm2@sanger.ac.uk>

=head1 CONTACT

Post questions to the EnsEMBL development list ensembl-dev@ebi.ac.uk

=cut

use strict;
use warnings;
no warnings 'uninitialized';

use FindBin qw($Bin);
use vars qw($SERVERROOT);

BEGIN {
    $SERVERROOT = "$Bin/../../..";
    unshift(@INC, "$SERVERROOT/ensembl/modules");
    unshift(@INC, "$SERVERROOT/ensembl-otter/modules");
    unshift(@INC, "$SERVERROOT/bioperl-live");
}

use Getopt::Long;
use Pod::Usage;
use Bio::EnsEMBL::Utils::ConversionSupport;
use Bio::EnsEMBL::Analysis;

$| = 1;

our $support = new Bio::EnsEMBL::Utils::ConversionSupport($SERVERROOT);

# parse options
$support->parse_common_options(@_);
$support->parse_extra_options(
    'logic_name=s',
    'chromosomes|chr=s@',
	'delete=s',
);
$support->allowed_params(
    $support->get_common_params,
    'logic_name',
    'chromosomes',
	'delete',
);

if ($support->param('help') or $support->error) {
    warn $support->error if $support->error;
    pod2usage(1);
}

$support->comma_to_list('chromosomes');
$support->param('logic_name','otter_corf') unless $support->param('logic_name');

$support->param('delete') || $support->param('delete','/GD_IDs_togo.txt');
$support->param('delete',($support->param('logpath').$support->param('delete')));

# ask user to confirm parameters to proceed
$support->confirm_params;

# get log filehandle and print heading and parameters to logfile
$support->init_log;

# connect to database and get adaptors
my $dba = $support->get_database('ensembl');
my $dbh = $dba->dbc->db_handle;
my $ga  = $dba->get_GeneAdaptor;
my $sa  = $dba->get_SliceAdaptor;
my $ta  = $dba->get_TranscriptAdaptor;
my $aa = $dba->get_AttributeAdaptor;

#filehandle for output
my $outfile = $support->filehandle('>', $support->param('delete'));

# make a backup tables the first time the script is run
my @tables = qw(gene transcript);

### - need to add other tables affected by deletion
my %tabs;
map { $_ =~ s/`//g; $tabs{$_} += 1; } $dbh->tables;
foreach my $table (@tables) {
	my $t = 'backup_cgg_'.$table;
	if (! exists ($tabs{$t})) {
		$support->log("Creating backup ($t) of $table\n\n");
		$dbh->do(qq(CREATE table $t SELECT * FROM $table));
	}
}

#undo previous if needed
if ($support->param('prune')
	  && $support->user_proceed("\nDo you want to undo changes from previous runs of this script?")) {
	foreach my $table (@tables) {
		my $t = 'backup_cgg_'.$table;
		$dbh->do(qq(DELETE FROM $table));
		$dbh->do(qq(INSERT INTO $table SELECT * FROM $t));
	}
}

my $patch_trans = 0;
if ( (!$support->param('dry_run'))
		 && ($support->user_proceed("\nSet analysis_ids to of CORF transcripts equal those of their genes ?"))) {	
	$patch_trans = 1;
}

my $delete_genes = 0;
if ( (!$support->param('dry_run'))
		 && ($support->user_proceed("\nDelete redundant GD genes ? (Warning - this can't be undone so if in doubt do later!)"))) {	
	$delete_genes = 1;
}

#get chromosomes
my @chroms;
foreach my $chr ($support->sort_chromosomes) {
	push @chroms,  $sa->fetch_by_region('toplevel', $chr);
}

####################################################
# look at all Genes to identify corf, log comments #
# and set analysis IDs                             #
####################################################

$support->log("Examining GD genes to identify corfs...\n");

my (%non_GD_hidden,%non_GD,%to_change,);
foreach my $slice (@chroms) {
	$support->log_stamped("\n\nLooping over chromosome ".$slice->seq_region_name."\n");
    my $genes = $slice->get_all_Genes;
    $support->log_stamped("Done fetching ".scalar @$genes." genes.\n");

    foreach my $gene (@$genes) {
		my $gsi = $gene->stable_id;
		my $name = $gene->display_xref->display_id;
		$support->log_verbose("Studying gene $gsi ($name) for remarks and name\n");
		my $found_remark = 0;

		#get all remarks
		my (%hidden_remarks,%remarks);
		foreach my $trans (@{$gene->get_all_Transcripts()}) {
			my $tsi = $trans->stable_id;
			foreach my $remark ( @{$trans->get_all_Attributes('hidden_remark')} ) {
				push @{$hidden_remarks{$tsi}},$remark->value
			}
			foreach my $remark ( @{$trans->get_all_Attributes('remark')} ) {
				push @{$remarks{$tsi}},$remark->value
			}
		}
		
		#look for correct hidden remarks				
		foreach my $tsi (keys %hidden_remarks) {
			foreach my $value (@{$hidden_remarks{$tsi}} ) {
				if ( $value =~ /^corf/i) {
					$found_remark = 1;
					#capture GD genes to patch analysis_id
					if ($name =~ /^GD:/) {
						$to_change{$gsi}->{'name'} = $name;
						push @{$to_change{$gsi}->{'transcripts'}}, [$tsi,$value];
					}
					#capture nonGD genes with the correct remark
					else {
						$non_GD_hidden{$gsi}->{'name'} = $name;
						push @{$non_GD_hidden{$gsi}->{'transcripts'}},$tsi;
					}

				}
			}
		}

		#otherwise look for 'corf' type remarks
		if (! $found_remark) {
			foreach my $tsi (keys %remarks) {
				foreach my $value (@{$remarks{$tsi}} ) {
					if ($value =~ /corf/i) {
						#capture GD genes with a remark that should be a corf hidden_remark
						if ( $name =~ /^GD:/ ) {
							$support->log_warning("Setting gene $gsi to corf despite not having the properly formatted hidden_remark\n");
							$to_change{$gsi}->{'name'} = $name;
							push @{$to_change{$gsi}->{'transcripts'}}, [$tsi,$value];
						}
						#capture non GD genes with a corf remark
						else {
							$non_GD{$gsi}->{'name'} = $name;
							push @{$non_GD{$gsi}->{'transcripts'}},$tsi;
						}
					}

				}									
			}
		}
	}
}

#report on non GD genes with a hidden corf remark
$support->log("\nThe following are non GD genes with a corf hidden_remark:\n");
my $c1 = 0;
foreach my $gsi (keys %non_GD_hidden) {
	$c1++;
	$support->log("\n$gsi (".$non_GD_hidden{$gsi}->{'name'}.")",1);
	foreach my $t (@{$non_GD_hidden{$gsi}->{'transcripts'}}) {
		$support->log_verbose("\n".$t."\n",2);
	}
}

#report on non GD genes with corf remark
$support->log("\nThe following are non GD genes with a CORF remark:\n"); 
my $c2 = 0;
foreach my $gsi (keys %non_GD) {
	$c2++;
	$support->log("\n$gsi (".$non_GD{$gsi}->{'name'}.")",1);
	foreach my $t (@{$non_GD{$gsi}->{'transcripts'}}) {
		$support->log_verbose("\n".$t."\n",2);
	}
}

#report on GD genes with the correct syntax, ie the ones to be updated
$support->log("\nThe following GD genes with the correct CORF remark or hidden_remark will be updated:\n");
my $c3 = 0;
my @gene_stable_ids;
foreach my $gsi (keys %to_change) {
	$c3++;
	push @gene_stable_ids, $gsi;
	$support->log("\n$gsi (".$to_change{$gsi}->{'name'}.")\n",1);
	foreach my $t (@{$to_change{$gsi}->{'transcripts'}}) {
		$support->log_verbose("\n".$t->[0]." (".$t->[1].")\n",2);
	}
}
$support->log("\nSummary\n");
$support->log("There are $c1 non GD genes with a CORF hidden_remark.\n\n");
$support->log("There are $c2 non GD genes with the CORF remark.\n\n");
$support->log("There are $c3 GD genes with the correct CORF (hidden)remark that would be updated to otter_corf.\n\n");

#do the updates to analysis
if (! $support->param('dry_run') ) {
    $support->log("Adding new analysis...\n");
    my $analysis = new Bio::EnsEMBL::Analysis (
        -program     => "set_corf_genes.pl",
        -logic_name  => $support->param('logic_name'),
    );
    my $analysis_id = $dba->get_AnalysisAdaptor->store($analysis);
    $support->log_error("Couldn't store analysis ".$support->param('analysis').".\n") unless $analysis_id;

    # change analysis for genes in list
    $support->log("Updating analysis of genes in list...\n");
    my $gsi_string = join("', '", @gene_stable_ids);
    my $num = $dbh->do(qq(
        UPDATE gene g, gene_stable_id gsi
           SET analysis_id = $analysis_id
         WHERE g.gene_id = gsi.gene_id
           AND gsi.stable_id in ('$gsi_string')
    ));
    $support->log("Done updating $num genes.\n\n");

	#change analysis_ids of transcripts
	if ($patch_trans) {
		$support->log("Updating analysis of corresponding transcripts...\n");
		$dbh->do(qq(
            UPDATE transcript t, gene g, gene_stable_id gsi
               SET t.analysis_id = g.analysis_id
             WHERE t.gene_id = g.gene_id
               AND g.gene_id = gsi.gene_id
               AND gsi.stable_id in ('$gsi_string')
        ));
		$support->log("Done updating transcripts.\n\n");
	}
	else {
		$support->log("Transcripts analysis_ids not updated.\n\n");
	}
}
else {
	$support->log("No analysis ids updated since this is a dry run\n");
}

#########################################################
# Generate list of stable IDs of GD genes to be deleted #
# plus do some logging of gomi comments                 #
#########################################################

$support->log("Examining GD genes to identify redundant ones...\n");

#hashes for more detailed logging if ever needed
my (%to_delete,%gomi_to_log_overlap,%gomi_to_log_no_overlap);
#counters
my ($tot_c,$noverlap_c,$overlap_c);
foreach my $slice (@chroms) {
	$support->log_stamped("\n\nLooping over chromosome ".$slice->seq_region_name."\n");
    my $genes = $slice->get_all_Genes;
    $support->log_stamped("Done fetching ".scalar @$genes." genes.\n");
 GENE:
    foreach my $gene (@$genes) {
		my $gsi = $gene->stable_id;
		my $name = $gene->display_xref->display_id;
		next GENE if ($name !~ /^GD:/);
		$tot_c++;
		$support->log_verbose("Studying gene $gsi ($name) for overlap with Havana\n");
	
		#get any overlapping Havana genes - defined by logicname of otter without a GD: name
		my $slice = $gene->feature_Slice;
		my @genes = @{$slice->get_all_Genes('otter')};
		my $to_go = 0;
		foreach my $gene (@genes) {
			if ($gene->display_xref->display_id !~ /^GD:/) {
				$to_go = 1;
			}
		}
		if ($to_go) {
			$overlap_c++;
			#note stable id of file to be deleted
			$to_delete{$gsi} = $name;
			$support->log("Gene $gsi ($name) is redundant and will be deleted\n",1);
			#are there any gomi remarks ?
			foreach my $trans (@{$gene->get_all_Transcripts()}) {
				my $tsi = $trans->stable_id;
				if (&any_gomi_remarks($trans)) {
					push @{$gomi_to_log_overlap{$gsi}}, $tsi;
				}
			}
		}
		else {
			$noverlap_c++;
			#are there any gomi remarks ?
			$support->log_verbose("Gene $gsi ($name) will be kept\n",1);
			foreach my $trans (@{$gene->get_all_Transcripts()}) {
				my $tsi = $trans->stable_id;
				if (&any_gomi_remarks($trans)) {
					push @{$gomi_to_log_no_overlap{$gsi}}, $tsi;
				}
			}
		}
	}			
}

#logging
my $log_c_o = keys %gomi_to_log_overlap;
my $log_c_no = keys %gomi_to_log_no_overlap;
$support->log("There are $tot_c GD genes in total:\n");	
$support->log("$noverlap_c of these do not overlap with Havana\n",1);
$support->log("$overlap_c of these overlap with Havana and will be deleted\n",1);

$support->log_verbose("$log_c_no GD genes do not overlap Havana loci but do have a gomi remark\n");
$support->log_verbose("$log_c_o GD genes overlap Havana loci (and will be pruned from Vega) and have a gomi remark\n");

#create file to delete
print $outfile join("\n", keys %to_delete), "\n";
close $outfile;

################
# delete genes #
################
if ($delete_genes) {
	#delete genes by stable ID
	my $options = $support->create_commandline_options({
		'allowed_params' => 1,
		'schematype' => 'vega',
		'exclude' => ['prune',
				      'logic_name'],
		'replace' => {
			'interactive' => 0,
			'logfile'     => 'cleanup_GD_genes_delete_by_stable_id.log',
		}
	});
	$support->log("\nDeleting unwanted GD genes from ".$support->param('dbname')."...\n");
#	warn $options;
	system("./delete_by_stable_id.pl $options") == 0
	or $support->throw("Error running delete_by_stable_id: $!");
}

$support->finish_log;

sub any_gomi_remarks {
	my ($trans) = @_;
	foreach my $remark (@{$trans->get_all_Attributes('remark')}) {
		my $value = $remark->value;
		return 1 if ($value =~ /gomi/);	
	}
}
