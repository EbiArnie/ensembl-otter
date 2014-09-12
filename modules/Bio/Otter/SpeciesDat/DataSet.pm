
package Bio::Otter::SpeciesDat::DataSet;

use strict;
use warnings;
use Carp;

use Try::Tiny;

use Bio::Otter::Server::Config;
use Bio::Otter::Utils::RequireModule qw(require_module);


=head1 METHODS

=head2 new

This class is not intended for construction directly.

Use L<Bio::Otter::Server::Config/SpeciesDat>, or where access control
is needed L<Bio::Otter::Server::Support::Web/allowed_datasets>, or if
you have a writable dataset L</clone_readonly>.

(Immediate callers C<catch> to put debug info in the error text.)

=cut

sub new {
    my ($pkg, $name, $params) = @_;
    my %params = %{ $params };
    $params{READONLY} = 0 unless exists $params{READONLY};
    my $new = {
        _name   => $name,
        _params => \%params,
    };
    bless $new, $pkg;
    $new->_init_fillin;
    return $new;
}


=head2 clone_readonly()

Returns a (weakly) readonly dataset, in that writing must be prevented
after inspecting ->params->{READONLY} .

=cut

sub clone_readonly {
    my ($called) = @_;
    die "Need an object" unless ref($called);
    return $called if $called->params->{READONLY};
    my $pkg = ref($called);
    my %param = %{ $called->params };
    $param{READONLY} = 1;
    # XXX: replace the database params
    my $name = $called->name;
    my $self = try {
        $pkg->new($name, \%param);
    } catch {
        croak "Dataset $name clone_readonly: $_";
    };
    return $self;
}

sub name {
    my ($self) = @_;
    return $self->{_name};
}

sub params {
    my ($self) = @_;
    return $self->{_params};
}

# Populate HOST,PORT,USER,PASS in-place from DBSPEC and databases.yaml
sub _init_fillin {
    my ($self) = @_;
    my $p = $self->params;
    my $nm = $self->name;
    foreach my $prefix ('', 'DNA_') {
        my $speckey = "${prefix}DBSPEC";
        my $dbspec = $p->{$speckey};
        die "no $speckey - old species.dat ?" unless $dbspec;
        my $db = Bio::Otter::Server::Config->Database($dbspec);

        my %info =
          ("${prefix}HOST" => $db->host,
           "${prefix}PORT" => $db->port,
           "${prefix}USER" => $db->user,
           $db->pass_maybe("${prefix}PASS"));

        # Replace into our params
        @$p{ keys %info } = values %info;
    }
    return;
}


sub otter_dba {
    my ($self) = @_;
    return $self->{_otter_dba} ||=
        $self->_otter_dba;
}

sub _otter_dba {
    my ($self) = @_;

    my $name   = $self->name;
    my $params = $self->params;

    my $dbname = $params->{DBNAME};
    die "Failed opening otter database [No database name]" unless $dbname;

    require Bio::Vega::DBSQL::DBAdaptor;
    require Bio::EnsEMBL::DBSQL::DBAdaptor;

    my $odba;
    try {
        $odba = Bio::Vega::DBSQL::DBAdaptor->new(
            -host    => $params->{HOST},
            -port    => $params->{PORT},
            -user    => $params->{USER},
            -pass    => $params->{PASS},
            -dbname  => $dbname,
            -group   => 'otter',
            -species => $name,
            );
    }
    catch { die "Failed opening otter database [$_]"; };

    my $dna_dbname = $params->{DNA_DBNAME};
    if ($dna_dbname) {
        my $dnadb;
        try {
            $dnadb = Bio::EnsEMBL::DBSQL::DBAdaptor->new(
                -host    => $params->{DNA_HOST},
                -port    => $params->{DNA_PORT},
                -user    => $params->{DNA_USER},
                -pass    => $params->{DNA_PASS},
                -dbname  => $dna_dbname,
                -group   => 'dnadb',
                -species => $name,
                );
        }
        catch { die "Failed opening dna database [$_]"; };
        $odba->dnadb($dnadb);
    }

    return $odba;
}

# With no options, you get a read-only vanilla-ensembl DBAdaptor.
# Pass opts 'pipe' and 'rw' to get a read-write B:E:Pipeline::Finished:DBA
sub pipeline_dba {
    my ($self, @opt) = @_;

    my %opt; @opt{@opt} = (1) x @opt;

    my $adaptor_class =
      (delete $opt{pipe}
       ? 'Bio::EnsEMBL::Pipeline::DBSQL::Finished::DBAdaptor'
       : 'Bio::EnsEMBL::DBSQL::DBAdaptor');

    my $meta_key =
      (delete $opt{rw}
       ? 'pipeline_db_rw_head'
       : 'pipeline_db_head');

    if (my @unk = sort keys %opt) {
        croak "Unknown options (@unk) to pipeline_dba";
    }

    return $self->satellite_dba($meta_key, $adaptor_class);
}

sub satellite_dba {
    my ($self, $metakey, $adaptor_class) = @_;
    $adaptor_class ||= "Bio::EnsEMBL::DBSQL::DBAdaptor";

    # check for a cached dba
    my $dba_cached = $self->{_sdba}{$metakey}{$adaptor_class};
    return $dba_cached if $dba_cached;

    # create the adaptor
    my $dba = $self->_satellite_dba_make($metakey, $adaptor_class);
    die "metakey '$metakey' is not defined" unless $dba;

    # create the variation database (if there is one)
    my $vdba = $self->_variation_satellite_dba("${metakey}_variation");
    $vdba->dnadb($dba) if $vdba;

    return $dba;
}

sub _variation_satellite_dba {
    my ($self, $metakey) = @_;
    my $adaptor_class = "Bio::EnsEMBL::Variation::DBSQL::DBAdaptor";

    # check for a cached dba
    my $dba_cached = $self->{_sdba}{$metakey}{$adaptor_class};
    return $dba_cached if $dba_cached;

    # create the adaptor
    my $dba = $self->_satellite_dba_make($metakey, $adaptor_class);

    return unless $dba; # (there isn't one)
    return $dba;
}

sub _satellite_dba_make {
    my ($self, $metakey, $adaptor_class) = @_;

    my $options = $self->_satellite_dba_options($metakey);
    return unless $options;

    my @options;
    {
        ## no critic (BuiltinFunctions::ProhibitStringyEval,Anacode::ProhibitEval)
        @options = eval $options;
    }
    die "Error evaluating '$options' : $@" if $@;

    my %anycase_options = (
         -group     => $metakey,
         -species   => $self->name,
        @options,
    );

    my %uppercased_options = ();
    while( my ($k,$v) = each %anycase_options) {
        $uppercased_options{uc($k)} = $v;
    }

    require_module($adaptor_class);
    my $dba = $adaptor_class->new(%uppercased_options);
    die "Couldn't connect to '$metakey' satellite db"
        unless $dba;
    if ((my $cls = ref($dba)) ne $adaptor_class) {
        # DBAdaptor class is caching(?) these somewhere.  Probably
        # don't need it to work right, but avoid silent surprises.
        die "Instantiation of '$adaptor_class' failed, got a '$cls'";
    }

    $self->{_sdba}{$metakey}{$adaptor_class} = $dba;

    return $dba;
}

sub _satellite_dba_options {
    my ($self, $metakey) = @_;

    my $meta_container = $self->otter_dba->get_MetaContainer;
    my ($options) = @{ $meta_container->list_value_by_key($metakey) };

    return $options;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

