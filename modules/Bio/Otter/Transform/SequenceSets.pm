package Bio::Otter::Transform::SequenceSets;

use strict;
use warnings;

use Bio::Otter::Lace::SequenceSet;

use base qw( Bio::Otter::Transform );

# ones we are interested in 
my $SUB_ELE = { map { $_ => 1 } qw(description vega_set_id priority is_hidden write_access)};
my $value;
my $subregion_name;   # I hate this global_var style!
my $subregion_hidden; # me too!

# this should be in xsl and use xslt to transform and create the objects
sub start_handler{
    my ( $self, $xml, $ele, %attr ) = @_;
    $value='';
    $self->_check_version(%attr) if $ele eq 'otter';
    if($ele eq 'sequenceset'){
        my $ss = Bio::Otter::Lace::SequenceSet->new();
        $ss->name($attr{'name'});
        $ss->dataset_name($self->get_property('dataset_name'));
        $self->add_object($ss);
    }elsif($ele eq 'subregion'){
        $subregion_name   = $attr{'name'};
        $subregion_hidden = $attr{'hidden'};
    }elsif($SUB_ELE->{$ele}){
       # print "* Interesting $ele\n";
    }else{
       # print "Uninteresting $ele\n";
    }
    return;
}

sub end_handler{ 
    my ( $self, $xml, $context ) = @_;
    $value =~ s/^\s*//;
    $value =~ s/\s*$//;
    if($context eq 'subregion') {
        unless($subregion_hidden) {
            my $sss = $self->objects;
            my $current_ss = $sss->[-1];
            $current_ss->set_subset($subregion_name, [split(/,/, $value)]);
        }
    } elsif($SUB_ELE->{$context}){
        my $context_method = $context;
        my $sss = $self->objects;
        my $current_ss = $sss->[-1];
        if($current_ss->can($context_method)){
            $current_ss->$context_method($value);
        }else{
            print STDERR "$current_ss can't $context_method\n";
        }
    }
    return;
}

sub char_handler{
    my ( $self, $xml, $data ) = @_;
  if ($data ne ''){
    $value .= $data;
  }
  return;
}

1;
__END__

=head1 NAME - SequenceSets.pm


=head1 DESCRIPTION

XML Parsing for sequence sets. Parses xml file and converts to SequenceSet Objects

=head1 AUTHOR

Refactored by Sindhu K. Pillai B<email> sp1@sanger.ac.uk
