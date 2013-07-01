package Bio::Otter::Utils::Script::DataSet;

## Moose provides these, but webpublish doesn't know that!
##
use strict;
use warnings;
##

use 5.010;
use namespace::autoclean;

use Bio::Otter::Utils::Script::Transcript;

use Moose;

has 'otter_sd_ds' => (
    is       => 'ro',
    isa      => 'Bio::Otter::SpeciesDat::DataSet',
    handles  => [ qw( name params otter_dba pipeline_dba satellite_dba ) ],
    required => 1,
    );

has 'script' => (
    is       => 'ro',
    isa      => 'Bio::Otter::Utils::Script',
    weak_ref => 1,
    handles  => [ qw( setup_data dry_run may_modify inc_modified_count verbose ) ],
    );

has '_callback_data' => (
    traits   => ['Hash'],
    is       => 'ro',
    isa      => 'HashRef',        # not up to us to police the contents
    default  => sub { {} },
    init_arg => undef,
    handles  => {
        callback_data => 'accessor',
    },
    );

has '_transcript_sth' => (
    is      => 'ro',
    builder => '_build_transcript_sth',
    lazy    => 1,
    );

sub iterate_transcripts {
    my ($self, $ts_method) = @_;

    my $sth = $self->_transcript_sth;
    $sth->execute;

    my $count = 0;
    while (my $cols = $sth->fetchrow_hashref) {
        my $ts = Bio::Otter::Utils::Script::Transcript->new(%$cols, dataset => $self);
        my ($msg, $verbose_msg) = $self->$ts_method($ts);
        ++$count;
        my $stable_id = $ts->stable_id;
        if ($self->verbose) {
            $verbose_msg ||= '.';
            my $name      = $ts->name;
            my $sr_name   = $ts->seq_region_name;
            my $sr_hidden = $ts->seq_region_hidden ? " (HIDDEN)" : "";
            say "  $stable_id ($name) [${sr_name}${sr_hidden}]: $verbose_msg";
        } elsif ($msg) {
            say "$stable_id: $msg";
        }
    }
    say "Modified ", $self->script->modified_count, " of $count transcripts" if $self->verbose;
    return;
}

sub _build_transcript_sth {
    my $self = shift;
    my $dbc = $self->otter_dba->dbc;
    my $sql = q{
        SELECT
                g.gene_id        as gene_id,
                g.stable_id      as gene_stable_id,
                gan.value        as gene_name,
                t.transcript_id  as transcript_id,
                t.stable_id      as transcript_stable_id,
                tan.value        as transcript_name,
                sr.name          as seq_region_name,
                srh.value        as seq_region_hidden
        FROM
                transcript           t
           JOIN gene                 g   ON t.gene_id = g.gene_id
           JOIN gene_attrib          gan ON g.gene_id = gan.gene_id
                                        AND gan.attrib_type_id = (
                                              SELECT attrib_type_id
                                              FROM   attrib_type
                                              WHERE  code = 'name'
                                            )
           JOIN transcript_attrib    tan ON t.transcript_id = tan.transcript_id
                                        AND tan.attrib_type_id = (
                                              SELECT attrib_type_id
                                              FROM   attrib_type
                                              WHERE  code = 'name'
                                            )
           JOIN seq_region           sr  ON g.seq_region_id = sr.seq_region_id
           JOIN seq_region_attrib    srh ON sr.seq_region_id = srh.seq_region_id
                                        AND srh.attrib_type_id = (
                                              SELECT attrib_type_id
                                              FROM   attrib_type
                                              WHERE  code = 'hidden'
                                            )
        WHERE
                t.is_current = 1
            AND g.is_current = 1
        ORDER BY g.stable_id, t.stable_id
    };

    my $limit = $self->script->limit;
    $sql .= " LIMIT $limit" if $limit;

    my $sth = $dbc->prepare($sql);
    return $sth;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
