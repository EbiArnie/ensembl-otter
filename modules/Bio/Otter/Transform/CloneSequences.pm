package Bio::Otter::Transform::CloneSequences;

use strict;
use warnings;
use Bio::Otter::Lace::CloneSequence;

use base qw( Bio::Otter::Transform );

# ones we are interested in 
my $SUB_ELE = { map { $_ => 1 } qw(clone_name accession sv chromosome chr_start chr_end contig_name length contig_start contig_end contig_strand )};

my $value;

# this should be in xsl and use xslt to transform and create the objects
sub start_handler{
    my ( $self, $xml, $ele, %attr ) = @_;

    $value='';
    $self->_check_version(%attr) if $ele eq 'otter';
    if($ele eq 'clonesequence'){
      my $cl = Bio::Otter::Lace::CloneSequence->new();
      $self->add_object($cl);
    }
    if($ele eq 'chr'){
      my $cs=$self->objects;
      my $cl=$cs->[-1];

        # from now on, just keep the chromosome's name
      $cl->chromosome($attr{name});
    }
    if($ele eq 'lock'){
      my $authorObj = Bio::Vega::Author->new(
          -name  => $attr{'author_name'},
          -email => $attr{'email'});
      my $cloneLock = Bio::Vega::ContigLock->new(
          -author   => $authorObj,
          -hostname => $attr{'host_name'},
          -dbID     => $attr{'lock_id'});
      my $cs = $self->objects;
      my $cl = $cs->[-1];
      $cl->set_lock_status($cloneLock);

    }

    return;
}

sub end_handler{
    my ( $self, $xml, $context ) = @_;
    $value =~ s/^\s*//;
    $value =~ s/\s*$//;
    if($SUB_ELE->{$context}){
        my $context_method = $context;
        my $cs = $self->objects;
        my $current = $cs->[-1];
        if($current->can($context_method)){
            $current->$context_method($value);
        }else{
            print STDERR "$current can't $context_method\n";
        }
    }
    return;
}

sub char_handler{
    my ( $self, $xml, $data ) = @_;
    if ($data ne ""){
      $value .= $data;
    }
    return;
}


1;
__END__

=head1 NAME - CloneSequences.pm


=head1 DESCRIPTION

XML Parsing for Clone Sequences. Parses xml file and converts to CloneSequence Objects

=head1 AUTHOR

Sindhu K. Pillai B<email> sp1@sanger.ac.uk
