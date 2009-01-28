#!/usr/local/bin/perl

=head1 NAME

finish_ensembl_vega_db.pl - final adjustments to an Ensembl-vega db
assembly

=head1 SYNOPSIS

finish_ensembl_vega_db.pl [options]

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
    --ensembldbname=NAME                use Ensembl (source) database NAME
    --evegadbname=NAME                  use ensembl-vega (target) database NAME
    --evegahost=HOST                    use ensembl-vega (target) database host
                                        HOST
    --evegaport=PORT                    use ensembl-vega (target) database port
                                        PORT
    --evegauser=USER                    use ensembl-vega (target) database
                                        username USER
    --evegapass=PASS                    use ensembl-vega (target) database
                                        passwort PASS

=head1 DESCRIPTION

This script is part of a series of scripts to transfer annotation from a
Vega to an Ensembl assembly. See "Related scripts" below for an overview of the
whole process.

This script does some final adjustments to an Ensembl-vega database. This
includes:

    - deleting data not needed any more (eg dna, repeats)
    - updating seq_region_ids to match those in the core Ensembl db
    - transfer selenocysteines
    - checking and setting the analysis_id and source for all genes and transcripts
    - update analysis_description for external_genes
    - transfer the whole genome assembly information back into the Vega db
    - delete orphan entries from object_xref

=head1 RELATED SCRIPTS

The whole Ensembl-vega database production process is done by these scripts:

    ensembl-otter/scripts/conversion/assembly/make_ensembl_vega_db.pl
    ensembl-otter/scripts/conversion/assembly/align_by_clone_identity.pl
    ensembl-otter/scripts/conversion/assembly/align_nonident_regions.pl
    ensembl-otter/scripts/conversion/assembly/map_annotation.pl
    ensembl-otter/scripts/conversion/assembly/finish_ensembl_vega_db.pl

See documention in the respective script for more information.

=head1 LICENCE

This code is distributed under an Apache style licence:
Please see http://www.ensembl.org/code_licence.html for details

=head1 AUTHOR

Steve Trevanion <st3@sanger.ac.uk>
Patrick Meidl <pm2@sanger.ac.uk>

=head1 CONTACT

Post questions to the EnsEMBL development list ensembl-dev@ebi.ac.uk

=cut

use strict;
use warnings;
no warnings 'uninitialized';

use FindBin qw($Bin);
use vars qw($SERVERROOT);

BEGIN {
  $SERVERROOT = "$Bin/../../../..";
  unshift(@INC, "$SERVERROOT/ensembl/modules");
  unshift(@INC, "$SERVERROOT/bioperl-live");
}

use Getopt::Long;
use Pod::Usage;
use Bio::EnsEMBL::Utils::ConversionSupport;

$| = 1;

my $support = new Bio::EnsEMBL::Utils::ConversionSupport($SERVERROOT);

# parse options
$support->parse_common_options(@_);
$support->parse_extra_options(
  'evegahost=s',
  'evegaport=s',
  'evegauser=s',
  'evegapass=s',
  'evegadbname=s',
  'ensembldbname=s',
);
$support->allowed_params(
  $support->get_common_params,
  'evegahost',
  'evegaport',
  'evegauser',
  'evegapass',
  'evegadbname',
  'ensembldbname',
);

if ($support->param('help') or $support->error) {
  warn $support->error if $support->error;
  pod2usage(1);
}

# ask user to confirm parameters to proceed
$support->confirm_params;

# get log filehandle and print heading and parameters to logfile
$support->init_log;

# there is nothing to do for a dry run, so exit
if ($support->param('dry_run')) {
  $support->log("Nothing to do for a dry run. Aborting.\n");
  exit;
}

# connect to database and get adaptors
my ($dba, $dbh, $sql, $c);
$dba->{'vega'}  = $support->get_database('core');
$dbh->{'vega'}  = $dba->{'vega'}->dbc->db_handle;
$dba->{'evega'} = $support->get_database('evega', 'evega');
$dbh->{'evega'} = $dba->{'evega'}->dbc->db_handle;
my $ensembl_db  = $support->param('ensembldbname');
my $vega_db     = $support->param('dbname');

my $ensemblassembly = $support->param('ensemblassembly');
my $vegaassembly    = $support->param('assembly');

# determine adjustment factors for Ensembl seq_region_ids and coord_system_ids
$sql = qq(
    SELECT MAX(seq_region_id)
    FROM seq_region sr, coord_system cs
    WHERE sr.coord_system_id = cs.coord_system_id
    AND cs.name = 'chromosome'
    AND cs.version = '$vegaassembly'
);
my $sth = $dbh->{'evega'}->prepare($sql);
$sth->execute;
my ($max_sri) = $sth->fetchrow_array;
my $E_sri_adjust = 10**(length($max_sri));
$sql = qq(
    SELECT coord_system_id
    FROM coord_system cs
    WHERE cs.name = 'chromosome'
    AND cs.version = '$vegaassembly'
);
$sth = $dbh->{'evega'}->prepare($sql);
$sth->execute;
my ($max_csi) = $sth->fetchrow_array;
my $E_csi_adjust = 10**(length($max_csi));

## transfer Ensembl chromosomes and whole genome alignment into Vega
if ($support->user_proceed("Would you like to transfer the whole genome alignment back into Vega?")) {
  $support->log_stamped("Transfer whole genome alignment into Vega...\n");
  # seq_region
  $support->log("Seq regions...\n", 1);
  $sql = qq(
        INSERT INTO $vega_db.seq_region
        SELECT sr.*
        FROM seq_region sr, coord_system cs
        WHERE sr.coord_system_id = cs.coord_system_id
        AND cs.name = 'chromosome'
        AND cs.version = '$ensemblassembly'
    );
  $c = $dbh->{'evega'}->do($sql);
  $support->log_stamped("Done storing $c seq_region entries.\n", 1);
  # coord_system
  $support->log("Coordinate system...\n", 1);
  $sql = qq(
        INSERT INTO $vega_db.coord_system
        SELECT cs.coord_system_id, cs.name, cs.version, cs.rank+100, cs.attrib
        FROM coord_system cs
        WHERE cs.name = 'chromosome'
        AND cs.version = '$ensemblassembly'
    );
  $c = $dbh->{'evega'}->do($sql);
  $support->log_stamped("Done storing $c coord_system entries.\n", 1);
  # assembly
  $support->log("Assembly...\n", 1);
  $sql = qq(
        INSERT INTO $vega_db.assembly
        SELECT a.*
        FROM    assembly a,
                seq_region sr1,
                seq_region sr2,
                coord_system cs1,
                coord_system cs2
        WHERE a.asm_seq_region_id = sr1.seq_region_id
        AND a.cmp_seq_region_id = sr2.seq_region_id
        AND sr1.coord_system_id = cs1.coord_system_id
        AND sr2.coord_system_id = cs2.coord_system_id
        AND cs1.name = 'chromosome'
        AND cs2.name = 'chromosome'
        AND cs1.version = '$vegaassembly'
        AND cs2.version = '$ensemblassembly'
    );
  $c = $dbh->{'evega'}->do($sql);
  $support->log_stamped("Done storing $c assembly entries.\n", 1);
  # transfer assembly mapping into Vega
  $support->log_stamped("Meta assembly.mapping...\n", 1);
  my $mappingstring = 'chromosome:'.$support->param('assembly').'#chromosome:'.$support->param('ensemblassembly');
  $sql = qq(
        INSERT INTO $vega_db.meta (meta_key, meta_value)
        ( SELECT meta_key, meta_value
          FROM meta
          WHERE meta_key = 'assembly.mapping'
          AND meta_value = '$mappingstring')
    );
  $c = $dbh->{'evega'}->do($sql);
  $support->log_stamped("Done storing $c meta entries.\n", 1);
  $support->log_stamped("Done.\n");
}

# store Vega chromosome seq_regions and Ensembl-Vega assembly in temporary tables
$support->log_stamped("Storing Vega chromosome seq_regions and Ensembl-Vega assembly in temporary tables...\n");
$sql = qq(
    CREATE TABLE tmp_seq_region
    SELECT sr.*
    FROM    seq_region sr,
            coord_system cs
    WHERE sr.coord_system_id = cs.coord_system_id
    AND cs.name = 'chromosome'
    AND cs.version = '$vegaassembly'
);
my $c1 = $dbh->{'evega'}->do($sql);
$sql = qq(
    CREATE TABLE tmp_assembly
    SELECT a.*
    FROM    assembly a,
            seq_region sr1,
            seq_region sr2,
            coord_system cs1,
            coord_system cs2
    WHERE a.asm_seq_region_id = sr1.seq_region_id
    AND a.cmp_seq_region_id = sr2.seq_region_id
    AND sr1.coord_system_id = cs1.coord_system_id
    AND sr2.coord_system_id = cs2.coord_system_id
    AND cs1.name = 'chromosome'
    AND cs2.name = 'chromosome'
    AND cs1.version = '$vegaassembly'
    AND cs2.version = '$ensemblassembly'
);
my $c2 = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done storing $c1 seq_region and $c2 assembly entries.\n\n");

## adjust all coord_system_ids
$support->log_stamped("Adjusting coord_system_ids...\n");
$sth = $dbh->{'evega'}->prepare("SELECT MAX(coord_system_id) FROM coord_system");
$sth->execute;
my ($tmp_max_csi) = $sth->fetchrow_array;
my $V_csi_adjust = 10**(length($tmp_max_csi));
# delete all but the Vega chromosome coord system
$sql = qq(
    DELETE FROM coord_system
    WHERE NOT (name = 'chromosome' AND version = '$vegaassembly')
);
$c = $dbh->{'evega'}->do($sql);
# adjust Vega coord_system_ids
$sql = qq(
    UPDATE coord_system
    SET coord_system_id = coord_system_id+$V_csi_adjust
);
$c = $dbh->{'evega'}->do($sql);
$sql = qq(
    UPDATE tmp_seq_region
    SET coord_system_id = coord_system_id+$V_csi_adjust
);
$c = $dbh->{'evega'}->do($sql);
# add Ensembl coord_systems
$sql = qq(
    INSERT INTO coord_system
    SELECT *
    FROM $ensembl_db.coord_system
);
$c = $dbh->{'evega'}->do($sql);
# meta_coord
$sql = qq(
    DELETE FROM meta_coord
    WHERE coord_system_id < $E_csi_adjust
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done deleting $c meta_coord entries.\n");
$sql = qq(
    UPDATE meta_coord
    SET coord_system_id = coord_system_id-$E_csi_adjust
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done.\n\n");

# adjust seq_region_ids in tmp_seq_region and tmp_assembly
$support->log_stamped("Adjusting Vega seq_region_ids in tmp_assembly and tmp_seq_region...\n");
$sth = $dbh->{'evega'}->prepare("SELECT MAX(seq_region_id) FROM seq_region");
$sth->execute;
my ($tmp_max_sri) = $sth->fetchrow_array;
my $V_sri_adjust = 10**(length($tmp_max_sri));
$support->log("Adjustment factors: $V_sri_adjust for Vega, $E_sri_adjust for Ensembl seq_region_ids.\n", 1);
$sql = qq(
    UPDATE tmp_seq_region
    SET seq_region_id = seq_region_id+$V_sri_adjust
);
$c = $dbh->{'evega'}->do($sql);
$sql = qq(
    UPDATE  tmp_assembly a
    SET     a.asm_seq_region_id = a.asm_seq_region_id+$V_sri_adjust,
            a.cmp_seq_region_id = a.cmp_seq_region_id-$E_sri_adjust
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done.\n\n");

# delete from assembly, seq_region, dna, dnac, repeat_consensus, repeat_feature
$support->log_stamped("Deleting assembly...\n");
$sql = qq(DELETE FROM assembly);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done deleting $c assembly entries.\n\n");

$support->log_stamped("Deleting seq_region...\n");
$sql = qq(DELETE FROM seq_region);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done deleting $c seq_region entries.\n\n");

$support->log_stamped("Deleting seq_region_attrib...\n");
$sql = qq(DELETE FROM seq_region_attrib);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done deleting $c seq_region_attrib entries.\n\n");

$support->log_stamped("Deleting dna...\n");
$sql = qq(DELETE FROM dna);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done deleting $c dna entries.\n\n");

$support->log_stamped("Deleting dnac...\n");
$sql = qq(DELETE FROM dnac);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done deleting $c dnac entries.\n\n");

$support->log_stamped("Deleting repeat_consensus...\n");
$sql = qq(DELETE FROM repeat_consensus);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done deleting $c repeat_consensus entries.\n\n");

$support->log_stamped("Deleting repeat_feature...\n");
$sql = qq(DELETE FROM repeat_feature);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done deleting $c repeat_feature entries.\n\n");

# transfer assembly, assembly_exception, seq_region, seq_region_attribs from Ensembl db
$support->log_stamped("Transfering Ensembl assembly...\n");
$sql = qq(
    INSERT INTO assembly
    SELECT *
    FROM $ensembl_db.assembly
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done transfering $c assembly entries.\n\n");

$support->log_stamped("Transfering Ensembl assembly_exception...\n");
$sql = qq(
    INSERT INTO assembly_exception
    SELECT *
    FROM $ensembl_db.assembly_exception
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done transfering $c assembly_exception entries.\n\n");

$support->log_stamped("Transfering Ensembl seq_region...\n");
$sql = qq(
    INSERT INTO seq_region
    SELECT *
    FROM $ensembl_db.seq_region
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done transfering $c seq_regions.\n\n");

$support->log_stamped("Transfering Ensembl seq_region_attrib...\n");
$sql = qq(
    INSERT INTO seq_region_attrib
    SELECT *
    FROM $ensembl_db.seq_region_attrib
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done transfering $c seq_region_attrib entries.\n\n");

# transfer Ensembl-Vega assembly information from tmp_seq_region and
# tmp_assembly back into main tables
$support->log_stamped("Adding Ensembl-Vega assembly info from tmp tables...\n");
$sql = qq(
    INSERT INTO seq_region
    SELECT * FROM tmp_seq_region
);
my $c3 = $dbh->{'evega'}->do($sql);
$sql = qq(
    INSERT INTO assembly
    SELECT * from tmp_assembly
);
my $c4 = $dbh->{'evega'}->do($sql);
$support->log_stamped("Done adding $c3 seq_region and $c4 assembly entries.\n\n");

# now adjust all seq_region_ids
$support->log_stamped("Updating seq_region_ids on all tables:\n");
# exon
$support->log_stamped("exon...\n", 1);
$sql = qq(UPDATE exon SET seq_region_id = seq_region_id-$E_sri_adjust);
$c = $dbh->{'evega'}->do($sql);
# gene
$support->log_stamped("gene...\n", 1);
$sql = qq(UPDATE gene SET seq_region_id = seq_region_id-$E_sri_adjust);
$c = $dbh->{'evega'}->do($sql);
# transcript
$support->log_stamped("transcript...\n", 1);
$sql = qq(UPDATE transcript SET seq_region_id = seq_region_id-$E_sri_adjust);
$c = $dbh->{'evega'}->do($sql);
# dna_align_feature
$support->log_stamped("dna_align_feature...\n", 1);
$sql = qq(UPDATE dna_align_feature SET seq_region_id = seq_region_id-$E_sri_adjust);
$c = $dbh->{'evega'}->do($sql);
# protein_align_feature
$support->log_stamped("protein_align_feature...\n", 1);
$sql = qq(UPDATE protein_align_feature SET seq_region_id = seq_region_id-$E_sri_adjust);
$c = $dbh->{'evega'}->do($sql);
# misc_feature
$support->log_stamped("misc_feature...\n", 1);
$sql = qq(UPDATE misc_feature SET seq_region_id = seq_region_id-$E_sri_adjust);
$c = $dbh->{'evega'}->do($sql);

$support->log_stamped("Done.\n\n");

#analysis_description;
$support->log_stamped("Updating analysis_description table for external genes");
$sql = qq(UPDATE analysis a, analysis_description ad
             SET ad.description = 'See <a href=\"http://vega.sanger.ac.uk/info/about/man_annotation.html\">the Vega website</a> for details of the approaches used for the annotation of external Vega genes'
          WHERE ad.analysis_id = a.analysis_id
            AND a.logic_name = 'otter_external'
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Updated $c analysis_description entries.\n\n");

# selenocysteines
$support->log_stamped("Transfering Vega translation_attribs (selenocysteines)...\n");
$sql = qq(
    INSERT INTO translation_attrib
    SELECT tsi2.translation_id, at2.attrib_type_id, ta.value
    FROM
        $vega_db.translation_attrib ta,
        $vega_db.translation_stable_id tsi,
        $vega_db.attrib_type at,
        translation_stable_id tsi2,
        attrib_type at2
    WHERE ta.translation_id = tsi.translation_id
    AND tsi.stable_id = tsi2.stable_id
    AND ta.attrib_type_id = at.attrib_type_id
    AND at.code = at2.code
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Transferred $c selenocysteine translation_attrib entries.\n\n");

# delete ccds transcript_attribs
$sql = qq(DELETE ta
            FROM attrib_type at, transcript_attrib ta
           WHERE at.attrib_type_id = ta.attrib_type_id
             AND at.code = 'ccds'
);
$c = $dbh->{'evega'}->do($sql);
$support->log_stamped("Deleted $c ccds transcript_attrib entries.\n\n");

# set source to 'vega'
if ($support->user_proceed("Would you like to ensure that all genes have a source of \'vega\'?")) {
	$sql = qq(UPDATE gene set source = 'vega');
	$c = $dbh->{'evega'}->do($sql);
}
$support->log_stamped("Updated $c gene.source entries.\n\n");

if ($support->user_proceed("Would you like to delete orphan entries from object_xref?")) {
    $sql = qq(DELETE ox
              FROM object_xref ox
              LEFT JOIN xref x ON ox.xref_id = x.xref_id
              WHERE x.xref_id IS NULL);	
	$c = $dbh->{'evega'}->do($sql);
}
$support->log_stamped("Deleted $c orphan object_xref entries.\n\n");

#we never say no to this option!
#if ($support->user_proceed("Would you like to drop the transient tables tmp_assembl and tmp_seq_region?")) {
#    $sql = qq(DROP TABLE tmp_assembly);
#    $c = $dbh->{'evega'}->do($sql);
#    $sql = qq(DROP TABLE tmp_seq_region);
#    $c = $dbh->{'evega'}->do($sql);
#}

# finish logfile
$support->finish_log;

