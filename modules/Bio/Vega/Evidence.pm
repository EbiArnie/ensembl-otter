package Bio::Vega::Evidence;

use strict;
use warnings;
use Bio::EnsEMBL::Utils::Argument qw ( rearrange );
use base 'Bio::EnsEMBL::Storable';

sub new {
  my($class,@args) = @_;
  my $self = $class->SUPER::new(@args);
  my ($name,$type)  = rearrange([qw(
NAME
TYPE
)
                                ],@args);

  $self->name($name);
  $self->type($type);
  return $self;
}

sub name {
  my ($obj,$value) = @_;
  if( defined $value) {
      $obj->{'name'} = $value;
  }
  return $obj->{'name'};
}

sub type{
  my ($obj,$value) = @_;
  if( defined $value) {
      if ($value eq 'ncRNA' || $value eq 'EST' || $value eq 'Protein' || $value eq 'cDNA' || $value eq 'Genomic' || $value eq 'UNKNOWN') {
          $obj->{'type'} = $value;
      } else {
          $obj->throw("Invalid type [$value]. Must be one of EST,ncRNA,Protein,cDNA,Genomic");
      }
  }
  return $obj->{'type'};
}


=head2 toString

 Title   : toString
 Usage   :
 Function:
 Example :
 Returns :
 Args    :


=cut

sub toString {
    my ($self) = @_;

    my $str = "";
    my $dbID   = "";
    my $infoid = "";

    if (defined($self->dbID)) {
        $dbID = $self->dbID;
    }
    if (defined($self->transcript_info_id)) {
        $infoid = $self->transcript_info_id;
    }
    $str = $str . "DbID                : " . $dbID . "\n";
    $str = $str . "Name                : " . $self->name . "\n";
    $str = $str . "Transcript info id  : " . $infoid . "\n";
    $str = $str . "Type                : " . $self->type . "\n";
    return $str;

}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

