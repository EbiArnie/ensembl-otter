#!/usr/local/bin/perl -w

#######################################################################
#
# When otterslave is up again (see switch_pipelines_to_master),
# switches over all otter_SPECIES databases to use pipeline data
# from otterslave instead of otterpipeX.
#
#######################################################################

use DBI;
use strict;

my @affected_keys = qw( pipeline_db pipeline_db_head mapper_db mapper_db.NCBI36 );
my $affected_list = join(', ', map { "'$_'" } @affected_keys);

sub connect_with_params {
	my %params = @_;

    my $dbname     = $params{-DBNAME} || '';
	my $username   = $params{-USER}   || 'anonymous';
	my $password   = $params{-PASS}   || '';
	my $datasource = "DBI:mysql:$dbname:$params{-HOST}:$params{-PORT}";

	return DBI->connect ($datasource, $username, $password, { RaiseError => 1 });
}

sub switch_over {
    my ($dbh, $dbname) = @_;

    my $sthm = $dbh->prepare("SELECT meta_key, meta_value FROM $dbname.meta where meta_key in ($affected_list)");
    $sthm->execute();
    while(my ($meta_key, $meta_value) = $sthm->fetchrow()) {
        $meta_value=~s/\n/ /g;
        if($meta_value=~/otterpipe\d/) {
            print "$dbname : $meta_key\n\t$meta_value\n-------------\n";
            if($meta_value=~s/3302/3312/) {
                $meta_value=~s/otterpipe1/otterslave/;
            } elsif($meta_value=~s/3303/3313/) {
                $meta_value=~s/otterpipe2/otterslave/;
            }
            $meta_value=~s/'/"/g;

            print "\t$meta_value\n===============\n\n\n";

            $dbh->do("UPDATE $dbname.meta set meta_value='$meta_value' where meta_key='$meta_key'");
        }
    }
}

sub main {
    my $dbh = connect_with_params(
        '-HOST'   => 'otterlive',
        '-PORT'   => '3301',
        '-USER'   => 'ottadmin',
        '-PASS'   => 'wibble',
    );

    my $sth1 = $dbh->prepare("SHOW DATABASES LIKE 'otter_%'");
    $sth1->execute();
    while(my($dbname) = $sth1->fetchrow()) {
        switch_over($dbh, $dbname);
    }

    my $sth2 = $dbh->prepare("SHOW DATABASES LIKE 'loutre_%'");
    $sth2->execute();
    while(my($dbname) = $sth2->fetchrow()) {
        switch_over($dbh, $dbname);
    }

    $dbh->disconnect ();
}

main();

