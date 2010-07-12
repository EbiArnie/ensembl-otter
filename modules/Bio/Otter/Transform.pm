=pod

=head1 Bio::Otter::Transform

=head1 DESCRIPTION

This is a bit of an experiment, and is designed as a base class
for xml parsing and transformation to otter objects, with the 
goal of moving it out of Converter and moving to stream based method.

=head1 USAGE

Try this and see first implementation in Bio::Otter::Lace::Client
which uses the Bio::Otter::Transform::DataSets child.

  my $transform = Bio::Otter::Transform->new();
  
  # this returns the XML::Parser obj
  my $p = $transform->my_parser();
  $p->parse($xml);

  # get the objects created
  $transform->objects;

=head1 Note to subclasses

You need to implement {start,end,char}_handler methods to create
your object list, even if they're just "sub end_handler{ }".

=head1 BUGS

There's probably a better way to do this, but it kinda works at the 
moment for Datasets at least.

=head1 AUTHOR

Roy Storey rds@sanger.ac.uk

=cut


package Bio::Otter::Transform;

use strict;
use warnings;

use XML::Parser;
use Bio::Otter::Version qw( $SCHEMA_VERSION $XML_VERSION );

sub new{
    my ( $pkg ) = @_;

    my $self = bless({}, ref($pkg) || $pkg);

    return $self;
}

sub my_parser{
    my ( $self ) = @_;
    my $p1 = new XML::Parser(Style => 'Debug',
                             Handlers => {
                                 Start => sub { 
                                     $self->start_handler(@_);
                                 },
                                 End => sub {
                                     $self->end_handler(@_);
                                 },
                                 Char => sub { 
                                     $self->char_handler(@_);
                                 }
                             });

    return $p1;
}

sub default_handler{
    my ( @args ) = @_;
    my $c = (caller(1))[3];
    print "$c -> @args\n";
    return;
}

sub start_handler{
    my ( $self, $xml, $ele, %attr ) = @_;
    $self->_check_version(%attr) if lc $ele eq 'otter';
    return;
}

sub _check_version{
    my ( $self, %attr ) = @_;
    my $schemaVersion = $attr{'schemaVersion'} || '';
    my $xmlVersion    = $attr{'xmlVersion'}    || '';
    error_exit("Wrong schema version, expected '$SCHEMA_VERSION' not '$schemaVersion'\n")
        unless ($schemaVersion && $schemaVersion <= $SCHEMA_VERSION);
    # $schemaVersion xml client receives must be older than client understands ($SCHEMA_VERSION)
    error_exit("Wrong xml version, expected '$XML_VERSION' not '$xmlVersion'\n")
        unless ($xmlVersion    && $xmlVersion    <= $XML_VERSION);
    #### $xmlVersion xml client receives must be older than client understands ($XML_VERSION)
    return;
}

sub error_exit{
    my ( @args ) = @_;
    print STDOUT "@args";
    print STDERR "@args";
    exit(1);
}

sub end_handler{
    my ( $self, @args ) = @_;
    $self->default_handler(@args);
    return;
}

sub char_handler{
    my ( $self, @args ) = @_;
    $self->default_handler(@args);
    return;
}

sub set_property{
    my ($self, $prop_name, $value) = @_;
    return unless $prop_name;
    if($value){
        $self->{'_properties'}->{$prop_name} = $value;
    }
    return $self->{'_properties'}->{$prop_name};
}

sub get_property{
    my ( $self, @args ) = @_;
    return $self->set_property(@args);
}

sub objects{
    my ( $self ) = @_;
    return $self->{'_objects'} || [];
}

sub add_object{
    my ( $self, $obj ) = @_;
    push(@{$self->{'_objects'}}, $obj) if $obj;
    return;
}

# END
1; # return true;

__END__
