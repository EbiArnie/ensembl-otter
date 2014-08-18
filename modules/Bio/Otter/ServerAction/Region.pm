package Bio::Otter::ServerAction::Region;

use strict;
use warnings;

use Readonly;
use Try::Tiny;

use Bio::Otter::Lace::CloneSequence;
use Bio::Vega::ContigInfo;
use Bio::Vega::SliceLockBroker;
use Bio::Vega::Region;

use base 'Bio::Otter::ServerAction';

=head1 NAME

Bio::Otter::ServerAction::Region - server requests on a region

=head1 CONSTRUCTOR

=cut

Readonly my @SLICE_REQUIRED_PARAMS => qw(
    dataset
    cs
    csver
    chr
    start
    end
);


=head2 new_with_slice

=cut

sub new_with_slice {
    my ($pkg, $server) = @_;

    my $self = $pkg->new($server);

    my $params = $server->require_arguments(@SLICE_REQUIRED_PARAMS);
    my $slice = $self->_get_requested_slice($params);
    $self->slice($slice);

    return $self;
}

sub _get_requested_slice {
    my ($self, $params) = @_;

    my $strand  = 1;

    return $self->server->otter_dba->get_SliceAdaptor->fetch_by_region(
        $params->{cs},
        $params->{chr},
        $params->{start},
        $params->{end},
        $strand,
        $params->{csver}
        );
}


=head1 METHODS

=head2 get_assembly_data

=cut

sub get_assembly_dna {
    my $self = shift;

    my $slice = $self->slice;
    my $output_string = $slice->seq . "\n";

    my $posn = 0;
    foreach my $tile (@{ $slice->project('seqlevel') }) {
        my $tile_slice = $tile->to_Slice;
        my $start = $tile->from_start;
        my $end   = $tile->from_end;

        # Is there a gap before this piece?
        if (my $gap = $start - $posn - 1) {
            # Debugging.  Show the char immediately before and after the string of "N".
            # $output_string .= substr($output_string, $posn == 0 ? 0 : $posn - 1, $posn == 0 ? $gap + 1 : $gap + 2) . "\n";
            # Change assembly gaps to dashes.
            substr($output_string, $posn, $gap, '-' x $gap);
        }
        $posn = $end;

        # To save copying large strings, we append onto the
        # end of the sequence in the output string.
        $output_string .= join("\t",
                               $tile->from_start,
                               $tile->from_end,
                               $tile_slice->seq_region_name,
                               $tile_slice->start,
                               $tile_slice->end,
                               $tile_slice->strand,
                               $tile_slice->seq_region_Slice->length,
            ) . "\n";
    }
    if (my $gap = $slice->length - $posn) {
        # If the slice ends in a gap, turn to dashes too
        substr($output_string, $posn, $gap, '-' x $gap);
    }

    return $output_string;
}


=head2 get_region

=cut

sub get_region {
    my $self = shift;

    my $odba  = $self->server->otter_dba;
    my $slice = $self->slice;

    my $region = Bio::Vega::Region->new_from_otter_db(
        otter_dba     => $odba,
        slice         => $slice,
        server_action => $self,
        );

    my $serialised_region = $self->serialise_region($region);
    return $serialised_region;
}


=head2 write_region

Input: region data, author, locknums.

Output: updated region, or error.

=cut

sub write_region {
    my ($self) = @_;

    my $server = $self->server;

    # These all require parameters, get them out of the way before trying anything else.
    my $odba       = $server->otter_dba();
    my $xml_string = $server->require_argument('data');

    my $slb;
    my ($new_region, $db_region, $ci_hash, $action);
    try {
        $action = 'init';
        $server->require_method('POST');
        $slb = $self->_slice_lock_broker(1);
        # author is checked against the locks by the broker.
        # we don't check source hostname: sessions do sometimes move around.

        $action = 'converting XML to otter';
        $new_region = $self->deserialise_region($xml_string);

        $action = 'comparing XML assembly with database assembly';
        $db_region = $self->_fetch_db_region($new_region);
        $ci_hash   = $self->_compare_region_create_ci_hash($new_region, $db_region);

        $action = 'checking locks';
        $slb->exclusive_work(sub { $slb->assert_bumped($db_region->slice) });

    } catch {
        die "Writing region failed whilst $action [$_]";
    };

    my $serialised_output;

    die "don't do it yet, we are out of exclusive_work";

    # everything that needs saving should use this timestamp:
    my $time_now = $serialised_output->wibble; # $lock->ts_activity during exclusive_work

    my $author_obj = $slb->author;
    $odba->begin_work;
    try {
        # update all contig_info and contig_info_attrib
        while (my ($contig_name, $pair) = each %$ci_hash) {
            my ($db_ctg_slice, $xml_ci_attribs) = @$pair;
            $self->_insert_ContigInfo_Attributes($author_obj, $db_ctg_slice, $xml_ci_attribs, $time_now);
            warn "Updating contig info-attrib for '$contig_name'\n";
        }

        ## strip_incomplete_genes for the xml genes
        my @new_genes = $new_region->genes;
        $self->_strip_incomplete_genes(\@new_genes);

        my $db_slice = $db_region->slice;

        ##fetch database genes and compare to find the new/modified/deleted genes
        warn "Fetching database genes for comparison...\n";
        my $ga =  $db_slice->adaptor->db->get_GeneAdaptor();
        my $db_genes = $ga->fetch_all_by_Slice($db_slice) || [];
        $self->_strip_incomplete_genes($db_genes);
        warn "Comparing " . scalar(@$db_genes) . " old to " . scalar(@new_genes) . " new gene(s)...\n";

        my $gene_adaptor = $odba->get_GeneAdaptor;
        warn "Attaching gene to slice \n";


        my @changed_genes;
        foreach my $gene (@new_genes) {
            # attach gene and its components to the right slice
            $gene->slice($db_slice);
            # update author in gene and transcript
            $gene->gene_author($author_obj);
            foreach my $tran (@{ $gene->get_all_Transcripts }) {
                $tran->slice($db_slice);
                $tran->transcript_author($author_obj);
            }
            foreach my $exon (@{ $gene->get_all_Exons }) {
                $exon->slice($db_slice);
            }
            # update all gene and its components in db (new/mod)
            $gene->is_current(1);
            if ($gene_adaptor->store($gene, $time_now)) {
                push(@changed_genes, $gene);
            }
        }
        warn "Updated " . scalar(@changed_genes) . " genes\n";

        my %stored_genes_hash = map {$_->stable_id, $_} @new_genes;

        my $del_count = 0;
        foreach my $dbgene (@$db_genes) {
            next if $stored_genes_hash{$dbgene->stable_id};

            ##attach gene and its components to the right slice
            $dbgene->slice($db_slice);
            ##update author in gene and transcript
            $dbgene->gene_author($author_obj);
            foreach my $tran (@{ $dbgene->get_all_Transcripts }) {
                $tran->slice($db_slice);
                $tran->transcript_author($author_obj);
            }
            foreach my $exon (@{ $dbgene->get_all_Exons }) {
                $exon->slice($db_slice);
            }
            ##update all gene and its components in db (del)

            # Setting is_current to 0 will cause the store method to delete it.
            $dbgene->is_current(0);
            $gene_adaptor->store($dbgene, $time_now);
            $del_count++;
            "Deleted gene " . $dbgene->stable_id . "\n";
        }
        warn "Deleted $del_count Genes\n" if ($del_count);

        my $ab = $odba->get_AnnotationBroker();

        # Because exons are shared between transcripts, genes and gene versions
        # setting which are current is not simple
        #$ab->set_exon_current_flags($db_genes, \@new_genes);

        ##update feature_sets
        ##SimpleFeatures - deletes old features(features not in xml)
        ##and stores the current featues in databse(features in xml)
        my @new_simple_features = $new_region->seq_features;
        my $sfa                 = $odba->get_SimpleFeatureAdaptor;
        my $db_simple_features  = $sfa->fetch_all_by_Slice($db_slice);

        my ($delete_sf, $save_sf) = $ab->compare_feature_sets($db_simple_features, \@new_simple_features);
        foreach my $del_feat (@$delete_sf) {
            $sfa->remove($del_feat);
        }
        warn "Deleted " . scalar(@$delete_sf) . " SimpleFeatures\n" unless $@;
        foreach my $new_feat (@$save_sf) {
            $new_feat->slice($db_slice);
            $sfa->store($new_feat);
        }
        warn "Saved " . scalar(@$save_sf) . " SimpleFeatures\n" unless $@;

        ##assembly_tags are not taken into account here, as they are not part of annotation nor versioned ,
        ##but may be required in the future
        ##fetch a new slice, and convert this new_slice to xml so that
        ##the response xml has all the above changes done in this session

        ##pass on to the xml generator the current set of genes , simple features
        my $current_region =  Bio::Vega::Region->new(
            otter_dba     => $odba,
            slice         => $db_slice,
            server_action => $self,
            );
        $current_region->genes(@changed_genes);
        $current_region->seq_features(@new_simple_features);
        $current_region->fetch_species;
        $current_region->fetch_CloneSequences;

        $serialised_output = $self->serialise_region($current_region);

        $odba->commit;
        $odba->clear_caches;
    } catch {
        $odba->rollback;
        chomp;
        die "Writing region failed writing annotations [$_]";
    };
    return $serialised_output;
}

sub _slice_lock_broker {
    my ($self, $add_locknums) = @_;
    die unless defined $add_locknums;
    my $server = $self->server;

    my @lockp;
    if ($add_locknums) {
        my $locknums   = $server->require_argument('locknums');
        my @locknum = split ',', $locknums;
        @lockp = (-lockid => \@locknum);
    }

    my $slb = Bio::Vega::SliceLockBroker->new
      (-author => $server->make_Author_obj,
       -adaptor => $server->otter_dba,
       @lockp);

    return $slb;
}

sub _fetch_db_region {
    my ($self, $new_region) = @_;

    my $odba = $self->server->otter_dba;
    my $new_slice = $new_region->slice;

    my $db_slice = $odba->get_SliceAdaptor()->fetch_by_region(
        $new_slice->coord_system->name,
        $new_slice->seq_region_name,
        $new_slice->start,
        $new_slice->end,
        $new_slice->strand,
        $new_slice->coord_system->version,
        );

    my $db_region = Bio::Vega::Region->new;
    $db_region->slice($db_slice);

    my @db_tiles = sort { $a->from_start() <=> $b->from_start() } @{ $db_slice->project('contig') };

    my @db_clone_sequences;
    foreach my $tile ( @db_tiles ) {
        my $ctg_slice = $tile->to_Slice;

        my $cs = Bio::Otter::Lace::CloneSequence->new;
        $cs->chr_start(    $tile->from_start + $new_slice->start - 1 );
        $cs->chr_end(      $tile->from_end   + $new_slice->start - 1 );
        $cs->contig_start( $ctg_slice->start  );
        $cs->contig_end(   $ctg_slice->end    );
        $cs->contig_strand($ctg_slice->strand );

        my $ci = Bio::Vega::ContigInfo->new( -slice => $ctg_slice );
        $cs->ContigInfo($ci);

        push @db_clone_sequences, $cs;
    }
    $db_region->clone_sequences(@db_clone_sequences);

    return $db_region;
}

sub _compare_region_create_ci_hash {
    my ($self, $new_region, $db_region) = @_;

    my $db_slice = $db_region->slice;

    my @new_clone_sequences = $new_region->clone_sequences;
    my @db_clone_sequences  = $db_region->clone_sequences;

    if (@db_clone_sequences != @new_clone_sequences) {
        die "The numbers of tiles in new_region and DB_region do not match";
    }

    my %contig_info_hash;

    for (my $i = 0; $i < @db_clone_sequences; $i++) {

        my $db_asm_start = $db_clone_sequences[$i]->chr_start();
        my $db_asm_end   = $db_clone_sequences[$i]->chr_end();
        my $db_ctg_slice = $db_clone_sequences[$i]->ContigInfo->slice();

        my $new_asm_start  = $new_clone_sequences[$i]->chr_start();
        my $new_asm_end    = $new_clone_sequences[$i]->chr_end();
        my $new_ctg_slice  = $new_clone_sequences[$i]->ContigInfo->slice();
        my $new_ci_attribs = $new_clone_sequences[$i]->ContigInfo->get_all_Attributes();

        if($db_asm_start != $new_asm_start) {
            die "In tile number $i 'asm_start' is different (new_value='$new_asm_start', db_value='$db_asm_start') ";
        }

        if($db_asm_end != $new_asm_end) {
            die "In tile number $i 'asm_end' is different (new_value='$new_asm_end', db_value='$db_asm_end') ";
        }

        foreach my $method (qw{ seq_region_name start end strand }) {
            my $db_value  = $db_ctg_slice->$method();
            my $new_value = $new_ctg_slice->$method();
            if ($db_value ne $new_value) {
                die "In tile number $i '$method' is different (new_value='$new_value', db_value='$db_value') ";
            }
        }

        ## hash the [db_contig, new_ci_attribs] pairs for saving the attributes after the locks are obtained
        $contig_info_hash{$new_ctg_slice->seq_region_name()} = [ $db_ctg_slice, $new_ci_attribs ];
    }

    return \%contig_info_hash;
}

sub _insert_ContigInfo_Attributes {
    my ($self, $ctg_author, $ctg_slice, $ctg_attrib_list, $time_uniseconds) = @_;
    my $contig_info =  Bio::Vega::ContigInfo->new(
                        -author     => $ctg_author,
                        -slice      => $ctg_slice,
                        -attributes => $ctg_attrib_list,
    );
    $self->server->otter_dba->get_ContigInfoAdaptor->store($contig_info, $time_uniseconds);
    return;
}

sub _strip_incomplete_genes {
    my ($self, $gene_list) = @_;

    for (my $i = 0 ; $i < @$gene_list ;) {
        my $gene = $gene_list->[$i];
        if ($gene->truncated_flag) {
            my $gene_name = $gene->get_all_Attributes('name')->[0]->value;
            warn "Splicing out incomplete gene '$gene_name'\n";
            splice(@$gene_list, $i, 1);
            next;
        } else {
            $i++;
        }
    }
    return;
}


=head2 lock_region

Input: region, author, hostname, client.

Output (JSON): error or { locknums => $txt }.

=cut

sub lock_region {
    my ($self) = @_;

    my $server = $self->server;
    $server->content_type('application/json');

    my $client = $server->param('client') || $server->cgi->user_agent;
    substr($client, 35) = '...' if length($client) > 38; # keep -intent short

    my $cl_host = $server->best_client_hostname;

    my ($lock_token, $action);
    try {
        $action = 'init';
        $server->require_method('POST');
        my $slb = $self->_slice_lock_broker(0);
        $slb->client_hostname($cl_host);

        $action = 'pre-lock';
        $slb->lock_create_for_Slice
          (-slice => $self->slice,
           -intent => "lock_region for $client");

        $action = 'locking';
        $slb->exclusive_work(sub {}); # do lock and commit, or rollback

        $action = 'output';
        my @dbID = map { $_->dbID } $slb->locks;
        $lock_token = { locknums => join ',', @dbID };
    } catch {
        chomp;
        die "Locking slice failed during $action \[$_]";
    };

    return $lock_token;
}


=head2 unlock_region

Input: locknums.

Output: error, or { unlocked => $locknums1, already => $locknums2 }

When the C<locknums> contains multiple locks, they must be compatible
within the SliceLockBroker together i.e. have the same author and
host.

=cut

sub unlock_region {
    my ($self) = @_;
    my $server = $self->server;
    $server->content_type('application/json');

    my (%out, $action);
    try {
        $action = 'init';
        $server->require_method('POST');
        my $slb_all = $self->_slice_lock_broker(1);

        $action = 'checking locks';
        my @already = grep { ! $_->is_held } $slb_all->locks;
        my @locked  = grep {   $_->is_held } $slb_all->locks;

        $action = 'to unlock slice';
        if (@locked) {
            my $slb_locked = $self->_slice_lock_broker(0);
            $slb_locked->locks(@locked);
            my $unlock_fail = $slb_locked->exclusive_work(sub {}, 1);
            die $unlock_fail if $unlock_fail;
        }

        $action = 'output';
        $out{unlocked} = join ',', map { $_->dbID } @locked if @locked;
        $out{already} = join ',', map { $_->dbID } @already if @already;
        die "Nothing happened" unless keys %out;

    } catch {
        chomp;
        die "Failed $action \[$_]";
    };

    return \%out;
}

### Null serialisation & deserialisation methods

sub serialise_region {
    my ($self, $region) = @_;
    return $region;
}

sub deserialise_region {
    my ($self, $region) = @_;
    return $region;
}

### Accessors

sub server {
    return shift->{_server};
}

sub slice {
    my ($self, @args) = @_;
    ($self->{_slice}) = @args if @args;
    return $self->{_slice};
}

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

1;
