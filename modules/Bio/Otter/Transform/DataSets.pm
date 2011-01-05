package Bio::Otter::Transform::DataSets;

use strict;
use warnings;

use Bio::Otter::Lace::DataSet;

use base qw( Bio::Otter::Transform );


# probably these should be global rather than assign EVERY time
# ones we are interested in
my $SUB_ELE = {
    map { $_ => 1 }
      qw(host port user pass dbname type headcode alias
      dna_host dna_port dna_user dna_pass dna_dbname)
};

# this should be in xsl and use xslt to transform and create the objects
sub start_handler{
    my ( $self, $xml, $ele, %attr ) = @_;
    $ele     =~ tr/[A-Z]/[a-z]/;
    $self->_check_version(%attr) if $ele eq 'otter';

    if($ele eq 'dataset'){
        my $ds = Bio::Otter::Lace::DataSet->new();
        $ds->name($attr{'name'});
        $self->add_object($ds);
    }elsif($SUB_ELE->{$ele}){
     #   print "* Interesting $ele\n";
    }else{
      #  print "Uninteresting $ele\n";
    }

    return;
}

sub end_handler{ }

sub char_handler{
    my ( $self, $xml, $data ) = @_;
    my $context = $xml->current_element();
    if($SUB_ELE->{$context}){
        $context =~ tr/[a-z]/[A-Z]/;
        my $context_method = $context;
        my $ds = $self->objects;
        my $current = $ds->[-1];
        if($current->can($context_method)){
            $current->$context_method($data);
        }
    }
    return;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

