
### Bio::Otter::Filter

package Bio::Otter::Filter;

use strict;
use warnings;

use Carp;

use URI::Escape qw( uri_escape );

my @server_params = (

    # session
    qw(
    server_script
    process_gff_file
    gff_source
    ),

    # common
    qw(
    analysis
    feature_kind
    csver_remote
    metakey
    filter_module
    swap_strands
    url_string
    ),

    # GFF
    qw(
    ditypes
    ),

    # DAS
    qw(
    grouplabel
    dsn
    sieve
    source
    ),

    # Gene
    qw(
    transcript_analyses
    translation_xref_dbs
    ),

    );

sub from_config {
    my ($pkg, $config) = @_;

    die sprintf "no filter configuration" unless keys %{$config};

    die "you can't specify a zmap_style and multiple featuresets"
        if 1
        # NB: use redundant ( ... ) to discipline emacs mode indentation
        && ($config->{zmap_style})
        && ($config->{featuresets})
        && ($config->{featuresets} =~ /[,;]/)
        ;

    my $filter = $pkg->new;

    for my $key (keys %{$config}) {
        die "unrecognized configuration key '$key'"
            unless $filter->can($key);
        $filter->$key($config->{$key});
    }

    return $filter;
}

sub new {
    my ($obj_or_class, @args) = @_;
    
    confess "No arguments to new" if @args;

    return bless {}, ref($obj_or_class) || $obj_or_class;
}

sub server_script {
    my ($self, $server_script) = @_;
    $self->{_server_script} = $server_script if defined $server_script;
    return $self->{_server_script};
}

sub wanted { # it's a flag showing whether the user wants this filter to be loaded
             # ( initialized from ['species'.use_filters] section of otter_config )
    my ($self, $wanted) = @_;

    if(defined($wanted)) {
        $self->{_wanted} = $wanted;
    }
    return $self->{_wanted};
}

sub name {
    # the canonical name for this filter
    my ($self, $name) = @_;
    $self->{_name} = $name if $name;
    return $self->{_name};
}

sub url_string {
    my($self, $url_string) = @_;

    if($url_string) {
        $self->{_url_string} = $url_string;
    }
    return $self->{_url_string};
}

sub description {
    my($self, $description) = @_;

    if($description) {
        $self->{_description} = $description;
    }
    return $self->{_description};
}

sub analysis_name {
    my ($self, @args) = @_;
    return $self->analysis(@args);
}

sub analysis {
    my ($self, $analysis) = @_;

    if($analysis) {
        $self->{_analysis} = $analysis;
    }

    # the analysis name defaults to the filter name

    return $self->{_analysis} || $self->name;
}

sub metakey {
    my ($self, $metakey) = @_;

    if($metakey) {
        $self->{_metakey} = $metakey;
    }
    return $self->{_metakey};
}

sub csver_remote {
    my ($self, $csver_remote) = @_;

    if($csver_remote) {
        $self->{_csver_remote} = $csver_remote;
    }
    return $self->{_csver_remote};
}

sub feature_kind {
    my ($self, $feature_kind) = @_;
    $self->{_feature_kind} = $feature_kind if $feature_kind;
    return $self->{_feature_kind};
}

sub filter_module {
    my ($self, $filter_module) = @_;
    $self->{_filter_module} = $filter_module if $filter_module;
    return $self->{_filter_module};
}

sub swap_strands {
    my ($self, $swap_strands) = @_;
    $self->{_swap_strands} = $swap_strands if defined $swap_strands;
    return $self->{_swap_strands};
}

sub featuresets {
    my ($self, $featuresets) = @_;

    if ($featuresets) {
        $self->{_featuresets} =
            ref $featuresets ? $featuresets : [split(/\s*[,;]\s*/, $featuresets)];
    }

    # the list of featuresets defaults to the name of this filter
    return $self->{_featuresets} || [ $self->name ];
}

sub zmap_column {
    my ($self, $zmap_column) = @_;
    
    if ($zmap_column) {
        $self->{'_zmap_column'} = $zmap_column;
    }
    return $self->{'_zmap_column'};
}

sub zmap_style {
    my ($self, $zmap_style) = @_;
    
    if ($zmap_style) {
        $self->{'_zmap_style'} = $zmap_style;
    }
    return $self->{'_zmap_style'};
}

sub ditypes {
    my ($self, $ditypes) = @_;
    
    if ($ditypes) {
        $self->{'_ditypes'} = $ditypes;
    }
    return $self->{'_ditypes'};
}

sub process_gff_file {
    my($self, $flag) = @_;
    
    if (defined $flag) {
        $self->{'_process_gff_file'} = $flag ? 1 : 0;
    }
    return $self->{'_process_gff_file'};
}

sub grouplabel {
    my ($self, $grouplabel) = @_;
    $self->{_grouplabel} = $grouplabel if $grouplabel;
    return $self->{_grouplabel};
}

sub dsn {
    my ($self, $dsn) = @_;
    $self->{_dsn} = $dsn if $dsn;
    return $self->{_dsn};
}

sub sieve {
    my ($self, $sieve) = @_;
    $self->{_sieve} = $sieve if $sieve;
    return $self->{_sieve};
}

sub source {
    my ($self, $source) = @_;
    $self->{_source} = $source if $source;
    return $self->{_source};
}

sub transcript_analyses {
    my ($self, $transcript_analyses) = @_;
    $self->{_transcript_analyses} = $transcript_analyses if $transcript_analyses;
    return $self->{_transcript_analyses};
}

sub translation_xref_dbs {
    my ($self, $translation_xref_dbs) = @_;
    $self->{_translation_xref_dbs} = $translation_xref_dbs if $translation_xref_dbs;
    return $self->{_translation_xref_dbs};
}

# session handling

sub url {
    my ($self, $session) = @_;
    my $script = $self->script_name;
    my $param_string =
        join '&', @{$self->gff_http_script_arguments($session)};
    return sprintf "pipe:///%s?%s", $script, $param_string,
}

sub delayed {
    my ($self, $session) = @_;
    my $state = $session->filters->{$self->name}{state};
    my $delayed = ! $state->{wanted} || $state->{failed};
    return $delayed;
}

sub call_with_session_data_handle {
    my ($self, $session, $data_sub) = @_;

    my $gff_http_script = $self->script_name;
    my @gff_http_command =
        ( $gff_http_script,
          @{$self->gff_http_script_arguments($session)} );

    open my $data_h, '-|', @gff_http_command
        or confess "failed to run $gff_http_script: $!";

    $data_sub->($data_h);

    close $data_h
        or confess $!
        ? "error closing $gff_http_script: $!"
        : "$gff_http_script failed: status = $?";

    return;
}

sub gff_http_script_arguments {
    my( $self, $session ) = @_;

    my $params = {
        %{ $session->script_arguments },
        ( map { $_ => $self->$_ } @server_params ),
    };
    $params->{gff_seqname} = $params->{type};

    my $arguments = [ ];
    for my $key (sort keys %{$params}) {
        my $value = $params->{$key};
        next unless defined $value;
        push @$arguments, join "=", uri_escape($key), uri_escape($value);
    }

    return $arguments; 
}

sub gff_source {
    my( $self ) = @_;
    return $self->name;
}

sub script_name {
    return "filter_get";
}

1;

__END__

=head1 NAME - Bio::Otter::Filter

=head1 AUTHOR

Stephen Keenan B<email> keenan@sanger.ac.uk

James Gilbert B<email> jgrg@sanger.ac.uk

Graham Ritchie B<email> gr5@sanger.ac.uk
