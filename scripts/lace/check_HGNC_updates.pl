#!/usr/local/bin/perl -w

# Author: ck1@sanger.ac.uk
# This scripts checks for gene name updates from HGNC
# and downloads the file if positive.
# Currently HGNC updates files on their sFTP server every Friday night

use strict;
use Expect;
use Net::Netrc;
use Digest::MD5;

# for Net::SFTP::Foreign
use lib "/nfs/team71/analysis/ck1/SCRIPT_CVS/ck1_modules/lib/site_perl/5.6.1/";
use Net::SFTP::Foreign;

{
  my $hgnc   = "/lustre/cbi4/work1/humpub/data/HGNC/sFTP";

  # current Sanger annotations
  # chr20 is currently missing at HGNC
  my @sanger_files = qw(
                        c01b.current.data.txt
                        c06.current.data.txt
                        c09.current.data.txt
                        c10.current.data.txt
                        c13.current.data.txt
                        c14.current.data.txt
                        cX.current.data.txt
                       );

  my $sftp = connect_to_HGNC_sftp_host('ash.gene.ucl.ac.uk');

  print STDERR "Start checking HGNC update at ", `date`, "\n";

  my $changed = 0;

  foreach my $file ( @sanger_files ) {
    if ( compare_checksum($file, $hgnc, $sftp) ){
      $changed = 1;
      print STDERR "Update available for $file\n";
      $sftp->get("/incoming/$file", "$hgnc/$file");
    }
    else {
      print STDERR "$file unchanged\n";
    }
  }
  print STDERR "New file(s) downloaded to $hgnc\n\n" if $changed;

}

sub compare_checksum {

  my ($file, $hgnc, $sftp) = @_;

  my $md5 = Digest::MD5->new;

  # sftp file
  $md5->add($sftp->get_content("/incoming/$file"));
  my $sftp_md5 = $md5->b64digest;

  # local file
  open(my $local_file, "$hgnc/$file") or die;
  $md5->addfile($local_file);
  my $local_md5 = $md5->b64digest;

  return 1 if $sftp_md5 ne $local_md5;
}

sub connect_to_HGNC_sftp_host {

  my $host     = shift;
  my $timeout  = 3;
  my $mach     = Net::Netrc->lookup($host);
  my $password = $mach->password;
  my $user     = $mach->login;

  # use Expect and transport to handle password prompt

  my $conn = Expect->new;
  $conn->raw_pty(1);
  $conn->log_user(0);

  $conn->spawn('/usr/bin/ssh', -l => $user, $host, -s => 'sftp')
    or die "Something went wrong";

  $conn->expect($timeout, "Password:")
    or die "Password not requested as expected";

  $conn->send("$password\n");
  $conn->expect($timeout, "\n");

  my $sftp = Net::SFTP::Foreign->new(transport => $conn);

  if ( $sftp->error ){
    die "unable to stablish SSH connection: ". $sftp->error;
  }
  return $sftp;
}

__END__
