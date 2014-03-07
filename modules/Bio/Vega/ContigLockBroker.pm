package Bio::Vega::ContigLockBroker;

use strict;
use warnings;
use Bio::Vega::ContigLock;
use Bio::EnsEMBL::Utils::Exception qw ( throw warning );
use Bio::EnsEMBL::Utils::Argument qw ( rearrange );
use Try::Tiny;

sub new {
    my ($class, @args) = @_;

    my $self = bless {}, $class;
    my ($hostname, $author) = rearrange([qw(HOSTNAME AUTHOR)], @args);

    $self->client_hostname($hostname)   if $hostname;
    $self->author($author)              if $author;

    return $self;
}

sub client_hostname {
    my ($self, $hostname) = @_;
    if ($hostname) {
        $self->{'hostname'} = $hostname;
    }
    return $self->{'hostname'};
}

sub author {
    my ($self, $author) = @_;
    if ($author) {
        if(! eval { $author->isa('Bio::Vega::Author') }) {
            throw("[$author] is not a Bio::Vega::Author");
        }
        $self->{'author'} = $author;
    }
    return $self->{'author'};
}

### CloneLockBroker should have an Author and a CloneLockAdaptor attached
### so it doesn't need to inherit from BaseAdaptor

sub check_slice_argument {
    my ($self, $slice) = @_;

    unless (ref($slice) eq 'ARRAY') {
        $slice = [$slice];
    }

    foreach my $ting (@$slice) {
        unless (eval{ $ting->isa('Bio::EnsEMBL::Slice') }) {
            throw("slice argument should be Bio::EnsEMBL::Slice or ref. to array of Bio::EnsEMBL::Slice, but was: (@$slice)");
        }
    }
    return $slice;
}

sub check_locks_exist_by_slice {
    my ($self, $slice, $author, $db) = @_;

    $slice = $self->check_slice_argument($slice);
    $author ||= $self->author() || throw("An author object needs to be passed either on creation or on use");

    my $aptr        = $db->get_ContigLockAdaptor;
    my $contig_hash = $self->Contig_hashref_from_Slice($slice, $db);

    my( @locks );
    while( my($contig_id, $contig_name) = each %$contig_hash) {

        my $lock = $aptr->fetch_by_contig_id($contig_id)
            or throw(sprintf "Contig '%s' (id=%u) not locked\n", $contig_name, $contig_id);

        unless ($lock->author->name eq $author->name) {
            throw(sprintf "Author '%s' doesn't own lock for contig '%s' (id=%u) ", $author->name, $contig_name, $contig_id);
        }
        push(@locks, $lock);
    }

    return \@locks; # it's not currently used anyway :)
}

sub check_no_locks_exist_by_slice {
    my ($self, $slice, $author, $db) = @_;

    $slice = $self->check_slice_argument($slice);
    $author ||= $self->author() || throw("An author object needs to be passed either on creation or on use");

    my $aptr        = $db->get_ContigLockAdaptor;
    my $contig_hash = $self->Contig_hashref_from_Slice($slice, $db);

    while( my($contig_id, $contig_name) = each %$contig_hash) {

        if ($aptr->fetch_by_contig_id($contig_id) ) {
            throw(sprintf "Contig '%s' (id=%u) is locked\n", $contig_name, $contig_id);
        }
    }
    return 1;
}

sub lock_by_object {
    my ($self, $obj, $author) = @_;

    return $self->lock_clones_by_slice($obj->feature_Slice, $author, $obj->adaptor->db);
}

# During migration to Chromosome Range locks (RT#274099), find out
# what still works
sub supported {
    my ($called, $dataset) = @_;

    my $db_thing = $dataset->isa('DBI::db') ? $dataset
      : ($dataset->can('get_cached_DBAdaptor')
         ? $dataset->get_cached_DBAdaptor->dbc # B:O:Lace:D
         : $dataset->otter_dba->dbc # B:O:SpeciesDat:D
        );

    return try {
        local $SIG{__WARN__} = sub {
            my ($msg) = @_;
            warn $msg unless $msg =~ /execute failed:/;
            return;
        };
        my $sth = $db_thing->prepare(q{ SELECT * FROM contig_lock LIMIT 1 });
        my $rv = $sth->execute();
        return 0 unless defined $rv; # when RaiseError=0
        my @junk = $sth->fetchrow_array;
        1;
    } catch {
        if (m{(?:^|: )Table '[^']+' doesn't exist($| )}) {
            0;
        } else {
            throw("Unexpected error in supported check: $_");
        }
    };
}


sub lock_clones_by_slice {
    my ($self, $slice, $author, $db) = @_;

    $slice = $self->check_slice_argument($slice);
    $author ||= $self->author() || throw("An author object needs to be passed either on creation or on use");

    my $aptr        = $db->get_ContigLockAdaptor;
    my $contig_hash = $self->Contig_hashref_from_Slice($slice, $db);

    my(
        @successful_locks,  # Locks we manange to create
        $lock_error_str,    # Any locking problems
    );

    while( my($contig_id, $contig_name) = each %$contig_hash) {

        my( $lock );
        eval {
            $lock = Bio::Vega::ContigLock->new(
                -author       => $author,
                -contig_id    => $contig_id,
                -hostname     => $self->client_hostname,
                );
            $db->get_ContigLockAdaptor->store($lock);
        };

        if ($@) {
            $lock_error_str .= sprintf "Failed to lock contig '%s'", $contig_name;
            if (my $dblock = $db->get_ContigLockAdaptor->fetch_by_contig_id($contig_id)) {
                $lock_error_str .= sprintf " already locked by '%s' on '%s' since %s\n",
                $dblock->author->name,
                $dblock->hostname,
                scalar localtime($dblock->timestamp);
            } else {
                # Locking failed for another reason.
                $lock_error_str .= ": $@\n";
                last;   # No point trying to lock other contigs
            }
        } else {
            push(@successful_locks, $lock);
        }
    }

    if ($lock_error_str) {
        # Unlock any that we just locked (could do this with rollback?)
        foreach my $lock (@successful_locks) {
            $aptr->remove($lock);
        }
        throw($lock_error_str);
    }
}

sub remove_by_object {
    my ($self, $obj, $author) = @_;

    return $self->remove_by_slice($obj->feature_Slice, $author, $obj->adaptor->db);
}

sub remove_by_slice {
    my ($self, $slice, $author, $db) = @_;

    $slice = $self->check_slice_argument($slice);
    $author ||= $self->author() || throw("An author object needs to be passed either on creation or on use");

    my $aptr        = $db->get_ContigLockAdaptor;
    my $contig_hash = $self->Contig_hashref_from_Slice($slice, $db);

    while( my($contig_id, $contig_name) = each %$contig_hash) {

        if (my $lock = $db->get_ContigLockAdaptor->fetch_by_contig_id($contig_id)) {
            unless ($lock->author->name eq $author->name) {
                    # FIXME: I think we have to be more pedantic here:
                    # first try to unlock everything possible, then throw
                throw(sprintf "Author '%s' doesn't own lock for contig '%s' (id=%u) ", $author->name, $contig_name, $contig_id);
            }
            $aptr->remove($lock);
        } else {
            warning("Can't unlock contig '$contig_name'. Lock doesn't exist");
        }
    }

    return;
}

sub Contig_hashref_from_Slice {
    my ($self, $slices, $db) = @_;

    my $sa          = $db->get_SliceAdaptor;
    my %contig_hash = ();
    foreach my $slice (@$slices) {
        foreach my $contig_seg (@{ $slice->project('contig') }) {
            my $contig_slice = $contig_seg->to_Slice();
            my $contig_id    = $sa->get_seq_region_id($contig_slice);
            my $contig_name  = $contig_slice->seq_region_name();
            $contig_hash{$contig_id} = $contig_name;
        }
    }

    return \%contig_hash;
}

1;
