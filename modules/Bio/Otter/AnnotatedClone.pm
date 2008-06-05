package Bio::Otter::AnnotatedClone;

use vars qw(@ISA);
use strict;
use warnings;
use Bio::EnsEMBL::Clone;

@ISA = qw(Bio::EnsEMBL::Clone);

sub new {
  my($class,@args) = @_;

  my $self = $class->SUPER::new(@args);
  
  my ($clone_info)  = $self->_rearrange([qw(
					   CLONE_INFO
					   )],@args);
  
  $self->clone_info($clone_info);

  return $self;
}

=head2 clone_info

 Title   : clone_info
 Usage   : $obj->clone_info($newval)
 Function: 
 Example : 
 Returns : value of clone_info
 Args    : newvalue (optional)


=cut

sub clone_info {
   my ($obj,$value) = @_;

   if( defined $value) {

       if ($value->isa("Bio::Otter::CloneInfo")) {
	   $obj->{'clone_info'} = $value;
       } else {
	   $obj->throw("Argument to clone_info must be a Bio::Otter::CloneInfo object.  Currently is [$value]");
       }
    }
    return $obj->{'clone_info'};

}

=head2 toXMLString

 Title   : toXMLString
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub toXMLString{
    my ($self) = shift;

    my $str = "";

    $str .= "  <accession>" . $self->id . "<\/accession>\n";
    $str .= "  <version>" . $self->embl_version . "<\/version>\n";
   
    if (defined($self->clone_info)) {
      foreach my $keyword ($self->clone_info->keyword) {
        $str .= "  <keyword>" . $keyword->name . "<\/keyword>\n";
      }
      foreach my $remark ($self->clone_info->remark) {
        $str .= "  <remark>" . $remark->remark . "<\/remark>\n";
     }
    }
    return $str;    
}
   

sub equals {
    my ($self,$obj) = @_;

    if (!defined($obj)) {
	$self->throw("Need an object to compare with");
    }
    if (!$obj->isa("Bio::Otter::AnnotatedClone")) {
	$self->throw("[$obj] not a Bio::Otter::AnnotatedGene");
    }
    
    if ($self->clone_info->equals($obj->clone_info) == 0 ) {
	print "Clone info different\n";
    } else {
	print " - Equal clone info\n";
    }
}
    
1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

