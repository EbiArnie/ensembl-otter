#!/usr/local/bin/perl -w

# wrapper that loads agps from chromoview, checks them for redundant clones, 
# then against qc checked clones, loads them into otter, loads assembly tags
# and realigns genes...uff
#
# it also does this for haplotypic clones
#
# 17.11.2005 Kerstin Howe (kj2)

use strict;
use Getopt::Long;

my ($date,$test,$verbose,$skip,$haplo,$tags,$help,$stop,$chroms);
GetOptions(
        'date:s'   => \$date,       # format YYMMDD 
        'test'     => \$test,       # doesn't execute system commands
        'verbose'  => \$verbose,    # prints all commands 
        'skip:s'   => \$skip,       # skips certain steps
        'tags'     => \$tags,       # loads assembly tags
        'h'        => \$help,       # help
        'stop'     => \$stop,       # stops where you've put yuor exit(0) if ($stop)
        'haplo'    => \$haplo,      # deals with chr H clones (only)
        'chr=s'    => \$chroms,     # overrides all chromosomes
);

my @chroms = split /,/, $chroms if ($chroms);

if (($help) || (!$date)){
    print "agp_loader.pl -date YYMMDD\n";
    print "              -skip            # skip steps in order agp, qc, region, fullagp, load\n";
    print "              -haplo           # loads chr H clones\n";
    print "              -chr             # runs for your comma separated list of chromosomes\n";
    print "              -tags            # load assembly tags\n";
    print "              -test            # don't execute system commands\n";
    print "              -verbose         # print commands\n";
}

# date
die "Date doesn't have format YYMMDD\n" unless ($date =~ /\d{6}/);
my ($year,$month,$day) = ($date =~ /(\d\d)(\d\d)(\d\d)/);
my $moredate = "20".$date;
my $fulldate = $day.".".$month.".20".$year;

# paths
my $path = "/nfs/disk100/zfishpub/annotation/ana_notes_update";
my $agp = "agp_".$date;
my $agpdir; 
$agpdir = $path."/".$agp       unless ($haplo);
$agpdir = $path."/haplo_".$agp if ($haplo);
@chroms = (1..25,"U") unless (@chroms);

mkdir($agpdir,0777) or die "Cannot make agp_$date $!\n" unless (($test) || ($skip =~ /\S+/));
chdir($agpdir);

############
# get agps #
############

unless (($skip =~ /agp/) || ($skip =~ /qc/) || ($skip =~ /region/) || ($skip =~ /newagp/) || ($skip =~ /load/) || ($skip =~ /realign/)) {
    foreach my $chr (@chroms) {
        my $command; 
        $command = "perl \$CHROMO/oracle2agp -species Zebrafish -chromosome $chr -subregion H_".$chr." > $agpdir/chr".$chr.".agp" if ($haplo);
        $command = "perl \$CHROMO/oracle2agp -species Zebrafish -chromosome $chr > $agpdir/chr".$chr.".agp" unless ($haplo);
        eval {&runit($command)};
    }
    print "\n" if ($verbose);
    &check_agps;
}

#################
# get qc clones #
#################

# start here with -skip agp 

unless (($skip =~ /qc/) || ($skip =~ /region/) || ($skip =~ /newagp/) || ($skip =~ /load/) || ($skip =~ /realign/)){
    my $command = "$path/qc_clones.pl > $agpdir/qc_clones.txt";
    &runit($command);
    print "\n" if ($verbose);
}

#######################
# create region files #
#######################

# start here with -skip qc

unless (($skip =~ /region/) || ($skip =~ /newagp/) || ($skip =~ /load/) || ($skip =~ /realign/)) {
    foreach my $chr (@chroms) {
        my $command = "$path/make_agps_for_otter_sets.pl -agp $agpdir/chr".$chr.".agp -clones $agpdir/qc_clones.txt > chr".$chr.".agp.new";
        eval {&runit($command)};
    }
    print "\n" if ($verbose);
    
    # create only one agp.new file for chr H
    if ($haplo) {
        open(OUT,">$agpdir/chrH.agp.new") or die "Cannot open $agpdir/chrH.fullagp $!\n";
        foreach my $chr (@chroms) {
            my $line = "N	10000\n";
            my $file = "chr".$chr.".agp.new";
            open(IN,"$agpdir/$file") or die "Cannot open $agpdir/$file $!\n";
            while (<IN>) {
                print OUT;
            }
            print OUT $line;
        }
    }
}

##########################
# convert regions to agp #
##########################

# start here with -skip region

unless (($skip =~ /newagp/) || ($skip =~ /load/) || ($skip =~ /realign/)){
    @chroms = ("H") if ($haplo);
    foreach my $chr (@chroms) {
        my $command = "perl \$CHROMO/regions_to_agp -chromosome $chr $agpdir/chr".$chr.".agp.new > $agpdir/chr".$chr.".fullagp";
        eval {&runit($command)};
    }
    print "\n" if ($verbose);
}

#############
# load agps #
#############

# start here with -skip newagp

unless (($skip =~ /load/) || ($skip =~ /realign/)) {
    @chroms = ("H") if ($haplo);
    foreach my $chr (@chroms) {
        my $command = "\$OTTER/scripts/lace/load_otter_ensembl -no_submit -dataset zebrafish -description \"chromosome $chr $fulldate\" -set chr".$chr."_".$moredate." $agpdir/chr".$chr.".fullagp > &! $agpdir/".$chr.".log";
        &runit($command);
    }
    print "\n" if ($verbose);
    foreach my $chr (@chroms) {
        my $command = "You have to run the following under head\nperl /nfs/farm/Fish/kj2/head/ensembl-pipeline/scripts/Finished/load_from_otter_to_pipeline.pl -chr chr".$chr."_20051206 -chromosome_cs_version Otter -oname otter_zebrafish -phost otterpipe2 -pport 3303 -pname pipe_zebrafish";
        print "$command\n";
    }
    print "\n" if ($verbose);
}
die "This is it for haplotype chromosomes, but you might want to set the otter sequence entries and alert anacode to start the analyses\n" if ($haplo);

##########################
# realign offtrack genes #
##########################

# start here with -skip load

unless ($skip =~ /realign/) {
    foreach my $chr (@chroms) {
        my $command = "\$OTTER/scripts/lace/realign_offtrack_genes -dataset zebrafish -set chr".$chr."_".$moredate;
        &runit($command);
    }
}

######################
# load assembly tags #
######################

# start here with -skip realign

if ($tags) {
    my $command2 = "\$OTTER/scripts/lace/fetch_assembly_tags -dataset zebrafish -verbose -set all";
    &runit($command2);
}

############
# and last #
############

print STDERR "Don't forget to set the otter sequence_set entries, run \$OTTER/scripts/check_genes.pl and alert anacode to start the analyses!\n";



########################################################

sub runit {
    my $command = shift;
    print $command,"\n" if ($verbose);
    system("$command") and die "Cannot execute $command $!\n" unless ($test);
}


sub check_agps {
    my %seen;
    foreach my $chr (@chroms) {
        my $file = "chr".$chr.".agp";
        open(IN,"$agpdir/$file") or die "Cannot open $agpdir/$file $!\n";
        while (<IN>) {
            my @a = split /\s+/;
            $seen{$a[5]}++ unless ($a[5] =~ /^\d+$/);
        }
    }  
    my $alarm;  
    foreach my $clone (keys %seen) {
        if ($seen{$clone} > 1) {
            print STDERR "$clone is in more than one chromosome\n";
            $alarm++;
        }    
    }
    die "ERROR: agps are incorrect\n" if ($alarm > 0);
}
