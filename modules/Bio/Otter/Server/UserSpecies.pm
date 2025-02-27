=head1 LICENSE

Copyright [2018-2022] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut


### Bio::Otter::Server::UserSpecies

package Bio::Otter::Server::UserSpecies;

use strict;
use warnings;
use DBI;

sub species_group{
 my ($self, $dsn, $username, $password) = @_;
 my %attr = (PrintError=>0, RaiseError=>1);

 # Connect to MySQL database
 my $dbh = DBI->connect($dsn, $username, $password, \%attr);
 
 # Set up hash of species for each user
 my %final_species_groups = query_links($dbh);
 
 # Setting up 'dev','main', 'restricted' and 'mouse_strain' species groups
 $final_species_groups{'species_groups'}{'dev'} = ['human_test', 'human_training'];
 $final_species_groups{'species_groups'}{'main'} = ['c_elegans', 'cat', 'chicken', 'chimp', 'cow', 'dog', 'drosophila', 'gibbon', 'gorilla', 'herring', 'herring_test', 'human', 'lemur', 'marmoset', 'medicago', 'mouse', 'mus_spretus', 'opossum', 'pig', 'platypus', 'rat', 'sheep', 'sordaria', 'tas_devil', 'tomato', 'tropicalis', 'wallaby', 'wheat', 'zebrafish']; 
 $final_species_groups{'species_groups'}{'mouse_strains'} = ['mouse-SPRET-EiJ', 'mouse-PWK-PhJ', 'mouse-CAST-EiJ', 'mouse-WSB-EiJ', 'mouse-NZO-HlLtJ', 'mouse-C57BL-6NJ', 'mouse-NOD-ShiLtJ', 'mouse-FVB-NJ', 'mouse-DBA-2J', 'mouse-CBA-J', 'mouse-C3H-HeJ', 'mouse-AKR-J', 'mouse-BALB-cJ', 'mouse-A-J', 'mouse-LP-J', 'mouse-129S1-SvImJ', 'mouse-C57BL-6NJ_v1_test'];
 $final_species_groups{'species_groups'}{'restricted'} =['human_test','mouse_test', 'mouse_old', 'mouse_old_test'];
 
 # Disconnect from the MySQL database
 $dbh->disconnect();
 return \%final_species_groups;
}

sub query_links{ 
 my ($dbh) = @_;
 my %data_group;
 
  # Query the database
  my $sql_user_group = "SELECT username, species_write, species_read FROM otter_species_access";
  my $sth_user_group = $dbh->prepare($sql_user_group)
                       or die "Could not prepare statement: " . $dbh->errstr;
  $sth_user_group->execute()
                       or die "Could not execute statement: " . $dbh->errstr;
  my (@species_write_array, @species_read_array);
  while(my $array_ref = $sth_user_group->fetchrow_arrayref()){

        # Setting up read and write species for each user
        my $username = $array_ref->[0];
        $data_group{'user_groups'}{$username.'.data'}{'users'} = $username;
 
        my $species_write_string = $array_ref->[1];  
        if ($species_write_string){
            @species_write_array = split ',', $species_write_string;
        }
        else{
            @species_write_array = ();
        }        
        $data_group{'user_groups'}{$username.'.data'}{'write'} = [@species_write_array]; 

        my $species_read_string = $array_ref->[2]; 
        if ($species_read_string){
             @species_read_array = split ',', $species_read_string; 
        }
        else{
            @species_read_array = (); 
        } 
#        $data_group{'user_groups'}{$username.'.data'}{'read'} = [@species_read_array]; #Uncomment this line when READONLY datasets are available
  }
  die "Error in fetchrow_array(): ", $sth_user_group->errstr(), "\n"
        if $sth_user_group->err();

  $sth_user_group->finish();            

  return %data_group;      
  
}

1;
