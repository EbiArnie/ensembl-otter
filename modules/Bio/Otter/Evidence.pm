package Bio::Otter::Evidence;

use vars qw(@ISA);
use strict;
use Bio::EnsEMBL::Root;

@ISA = qw(Bio::EnsEMBL::Root);

sub new {
  my($class,@args) = @_;

  my $self = bless {}, $class;

  my ($dbid,$name,$transcript_info_id,$type)  = $self->_rearrange([qw(
							  DBID
                                                          NAME
							  TRANSCRIPT_INFO_ID
							  TYPE
							  )],@args);

  $self->dbID($dbid);
  $self->name($name);
  $self->transcript_info_id($transcript_info_id);
  $self->type($type);

  return $self;
}

=head2 name
    
 Title   : name 
 Usage   : $obj->name($newval)
 Function:
 Example :
 Returns : value of name 
 Args    : newvalue (optional)

 
=cut
 
sub name { 
   my ($obj,$value) = @_;
   if( defined $value) {
      $obj->{'name'} = $value;
    }
    return $obj->{'name'};

}


=head2 dbID

 Title   : dbID
 Usage   : $obj->dbID($newval)
 Function: 
 Example : 
 Returns : value of dbID
 Args    : newvalue (optional)


=cut

sub dbID{
   my ($obj,$value) = @_;

   if( defined $value) {
      $obj->{'dbID'} = $value;
    }

    return $obj->{'dbID'};

}

=head2 transcript_info_id

 Title   : transcript_info_id
 Usage   : $obj->transcript_info_id($newval)
 Function: 
 Example : 
 Returns : value of transcript_info_id
 Args    : newvalue (optional)


=cut

sub transcript_info_id {
   my ($obj,$value) = @_;
   if( defined $value) {
      $obj->{'transcript_info_id'} = $value;
    }
    return $obj->{'transcript_info_id'};

}
=head2 type

 Title   : type
 Usage   : $obj->type($newval)
 Function: 
 Example : 
 Returns : value of type
 Args    : newvalue (optional)


=cut

sub type{
   my ($obj,$value) = @_;
   if( defined $value) {

       if ($value eq 'EST' || $value eq 'Protein' || $value eq 'cDNA' || $value eq 'Genomic' || $value eq 'UNKNOWN') {
	   $obj->{'type'} = $value;
       } else {
	   $obj->throw("Invalid type [$value]. Must be one of EST,Protein,cDNA,Genomic");
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
    my ($self, @args) = @_;

    my $str = "";
    if (scalar(@args) == 0) {
        push(@args, $self);
    }
    foreach my $arg (@args) {
        if ($arg->isa("Bio::Otter::Evidence")) {
            my $dbID   = "";
            my $infoid = "";

            if (defined($arg->dbID)) {
                $dbID = $arg->dbID;
            }
            if (defined($arg->transcript_info_id)) {
                $infoid = $arg->transcript_info_id;
            }
            $str = $str . "DbID                : " . $dbID . "\n";
            $str = $str . "Name                : " . $arg->name . "\n";
            $str = $str . "Transcript info id  : " . $infoid . "\n";
            $str = $str . "Type                : " . $arg->type . "\n";
        }
        else {
            $self->throw(
                "Can't print string if object not Evidence.  Currently [$arg]\n"
            );
        }
    }
    return $str;

}


sub equals {
    my ($self, $obj) = @_;

    if (!defined($obj)) {
        $self->throw("Need an object to compare with");
    }
    if (!$obj->isa("Bio::Otter::Evidence")) {
        $self->throw("Can only compare with a Bio::Otter::Evidence object");
    }

    if ($self->name eq $obj->name) {
        #	$self->type eq $obj->type) {
        return 1;
    }
    else {
        print STDERR "FOUND DIFF : " . $self->name . " : " . $obj->name . "\n";
        return 0;
    }
}

1;
