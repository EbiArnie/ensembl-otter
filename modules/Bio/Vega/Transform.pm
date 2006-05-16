
### Bio::Vega::Transform

package Bio::Vega::Transform;

use strict;
use XML::Parser;
use Data::Dumper;   # For debugging

# This misses the "$VAR1 = " bit out from the Dumper() output
$Data::Dumper::Terse = 1;

# Using inside-out object design for speed.

my(
    %tag_stack,
    %current_object,
    %current_string,
    %object_builders,
    %object_data,
    %is_multiple,
    );

sub DESTROY {
    my ($self) = @_;
    
    printf STDERR "Destroying '%s'\n", ref($self);
    
    delete $tag_stack{$self};
    delete $current_object{$self};
    delete $current_string{$self};
    delete $object_builders{$self};
    my $data = delete $object_data{$self};
    warn "Unused data after parse: ", Dumper($data);
    delete $is_multiple{$self};
}

sub new {
    my ($pkg) = @_;

    my $scalar;
    my $self = bless \$scalar, $pkg;
    $self->initialize;
    $tag_stack{$self} = [];
    return $self;
}

sub parse {
    my ($self, $fh) = @_;
    
    my $parser = $self->new_Parser;
    $parser->parse($fh);
}

sub parsefile {
    my ($self, $filename) = @_;
    
    my $parser = $self->new_Parser;
    $parser->parsefile($filename);
}

sub new_Parser {
    my ($self) = @_;
    
    my $parser = XML::Parser->new(
        ErrorContext    => 3,
        Handlers => {
            Start => sub { 
                $self->handle_start(@_);
            },
            End => sub {
                $self->handle_end(@_);
            },
            Char => sub { 
                $self->handle_char(@_);
            },
        },
    );
    return $parser;
}

sub object_builders {
    my ($self, $value) = @_;
    
    if ($value) {
        $object_builders{$self} = $value;
    }
    return $object_builders{$self};
}

sub set_multi_value_tags {
    my ($self, $value) = @_;
    
    if ($value) {
        foreach my $row (@$value) {
            my ($context, @ele) = @$row;
            foreach my $element (@ele) {
                $is_multiple{$self}{$context}{$element} = 1;
            }
        }
    }
    return $is_multiple{$self};
}

sub handle_start {
    my ($self, $expat, $element, %attrib) = @_;
    
    if ($object_builders{$self}{$element}) {
        unshift @{$tag_stack{$self}}, $element;
    }
}

sub handle_char {
    my ($self, $expat, $txt) = @_;
    
    $current_string{$self} .= $txt;
}

sub handle_end {
    my ($self, $expat, $element) = @_;
    
    if (my $builder = $object_builders{$self}{$element}) {
        my $context = shift @{$tag_stack{$self}};
        my $data    = delete $object_data{$self}{$context};
        warn "\nCalling $builder at end of $context with: ", Dumper($data);
        $self->$builder($data);
    }
    elsif (defined( my $str = delete $current_string{$self} )) {
        my $context = $tag_stack{$self}[0];
        $str =~ s/(^\s+|\s+$)//g;
        #warn "Setting '$element' to '$str'\n";
        my $data = $object_data{$self}{$context};
        if ($is_multiple{$self}{$context}{$element}) {
            my $list = $data->{$element} ||= [];
            push(@$list, $str);
        } else {
            if (defined( my $value = $data->{$element} )) {
                # xpcroak method on Expat object gives
                # some context in the XML.
                $expat->xpcroak("Setting '$element' in '$context' to '$str' but already set to '$value'");
            } else {
                $object_data{$self}{$context}{$element} = $str;
            }
        }
    }
}

1;

__END__

=head1 NAME - Bio::Vega::Transform

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

