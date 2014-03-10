package Bio::Vega::DBSQL::SliceLockAdaptor;

use strict;
use warnings;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::DBSQL::BaseAdaptor;
use Bio::Vega::DBSQL::AuthorAdaptor;
use Bio::Vega::SliceLock;
use base qw ( Bio::EnsEMBL::DBSQL::BaseAdaptor);


=head1 NAME

Bio::Vega::DBSQL::SliceLockAdaptor - handle SliceLock objects


=head1 SYNOPSIS

 my $SLdba = $ds->get_cached_DBAdaptor->get_SliceLockAdaptor;
 # ...
 $SLdba->store($lock);
 $SLdba->do_lock($lock);
 $SLdba->unlock($lock, $lock->author);
 # see workflow below, for places the caller should COMMIT


=head1 DESCRIPTION

This is a region-exclusive lock attached directly to a slice and
operates like a feature.

It does not affect other slices which map to the same sequence.

=head2 Workflow

The workflow is

=over 4

=item 1. Create lock in state C<active='pre'>

=item 2. Call L</do_lock> to reach state C<active='held'>

Check the return value.  Maybe someone else got the lock.

=item 3. COMMIT

=item 4. Update rows as necessary.

=item 5. Check L<Bio::Vega::SliceLock/is_held_sync>

If the lock was broken from outside, roll back.

=item 6. COMMIT

Repeat as necessary.

=item 7. L</unlock>

As with C<is_held_sync>, this can fail, so be prepared to roll back.

=back

This workflow can be broken between runtime instances, because the
lock object persists in the database.


=head2 Other possible operations - dibs

In order to use the 'pre' state as a non-binding "dibs" on a region,
it might be useful for its owner to be able to split a 'pre' lock on a
Slice into two locks on smaller contiguous regions.

Possibly this should be done in another state, to avoid the need to
check over the entire state machine for locking operations.


=head1 METHODS

=cut


sub _generic_sql_fetch {
  my ($self, $where_clause, @param) = @_;
  my $sth = $self->prepare(q{
        SELECT slice_lock_id
          , seq_region_id
          , seq_region_start
          , seq_region_end
          , author_id
          , UNIX_TIMESTAMP(ts_begin)
          , UNIX_TIMESTAMP(ts_activity)
          , active
          , freed
          , freed_author_id
          , intent
          , hostname
          , UNIX_TIMESTAMP(ts_free)
        FROM slice_lock
        } . $where_clause);
  $sth->execute(@param);

  my $slicelocks=[];
  while (my $row = $sth->fetch) {
      my $slicelock = Bio::Vega::SliceLock->new
        (-ADAPTOR          => $self,
         -DBID             => $row->[0],
         -SEQ_REGION_ID    => $row->[1],
         -SEQ_REGION_START => $row->[2],
         -SEQ_REGION_END   => $row->[3],
         -AUTHOR       => $self->_author_find($row->[4]),
         -TS_BEGIN     => $row->[5],
         -TS_ACTIVITY  => $row->[6],
         -ACTIVE       => $row->[7],
         -FREED        => $row->[8],
         -FREED_AUTHOR => $self->_author_find($row->[9]),
         -INTENT       => $row->[10],
         -HOSTNAME     => $row->[11],
         -TS_FREE      => $row->[12],
        );
      push(@$slicelocks, $slicelock);
  }
  return $slicelocks;
}

sub _author_find {
    my ($self, $author_id) = @_;
    if (defined $author_id) {
        my $aad = $self->db->get_AuthorAdaptor;
        return $aad->fetch_by_dbID($author_id);
    } else {
        return undef;
    }
}

sub _author_dbID {
    my ($self, $what, $author) = @_;
    throw("$what not set on SliceLock object") unless $author;
    unless ($author->dbID) {
        my $aad = $self->db->get_AuthorAdaptor;
        $aad->store($author);
    }
    return $author->dbID;
}


=head2 fetch_by_dbID($id)

Return one SliceLock.

=head2 fetch_by_seq_region_id($sr_id, $extant)

If provided, $extant must be true.  Then freed locks are ignored.

Returns arrayref of SliceLock.

=cut

sub fetch_by_dbID {
  my ($self, $id) = @_;
  if (!defined($id)) {
      throw("Id must be entered to fetch a SliceLock object");
  }
  my ($obj) = $self->_generic_sql_fetch("where slice_lock_id = ? ", $id);
  return $obj->[0];
}

sub fetch_by_seq_region_id {
  my ($self, $id, $extant) = @_;
  throw("Slice seq_region_id must be entered to fetch a SliceLock object")
      unless $id;
  throw("extant=0 not implemented") if defined $extant && !$extant;
  my $q = "where seq_region_id = ?";
  $q .= " and active <> 'free' and freed is null" if $extant;
  my $slicelocks = $self->_generic_sql_fetch($q, $id);
  return $slicelocks;
}


sub fetch_by_author {
  my ($self, $auth, $extant) = @_;
  throw("Author must be entered to fetch a SliceLock object")
      unless $auth;
  throw("extant=0 not implemented") if defined $extant && !$extant;
  my $authid = $self->_author_dbID(fetch_by => $auth);
  my $q = "where author_id = ?";
  $q .= " and active <> 'free' and freed is null" if $extant;
  my $slicelocks = $self->_generic_sql_fetch($q, $authid);
  return $slicelocks;
}


sub store {
  my ($self, $slice_lock) = @_;
  throw("Must provide a SliceLock object to the store method")
      unless $slice_lock;
  throw("Argument must be a SliceLock object to the store method.  Currently is [$slice_lock]")
      unless $slice_lock->isa("Bio::Vega::SliceLock");


  my $seq_region_id = $slice_lock->seq_region_id
    or $self->throw('seq_region_id not set on SliceLock object');

  my $author_id = $self->_author_dbID(author => $slice_lock->author);
  my $freed_author_id = defined $slice_lock->freed_author
    ? $self->_author_dbID(freed_author => $slice_lock->freed_author) : undef;

  if ($slice_lock->adaptor) {
#      $slice_lock->is_stored($slice_lock->adaptor->db)) {
      die "UPDATE or database move $slice_lock: not implemented";
  } else {
      my $sth = $self->prepare(q{
        INSERT INTO slice_lock(slice_lock_id
          , seq_region_id
          , seq_region_start
          , seq_region_end
          , author_id
          , ts_begin
          , ts_activity
          , active
          , freed
          , freed_author_id
          , intent
          , hostname
          , ts_free)
        VALUES (NULL, ?,?,?, ?, NOW(), NOW(), ?, ?, ?, ?, ?, NULL)
        });
      $sth->execute
        ($slice_lock->seq_region_id,
         $slice_lock->seq_region_start,
         $slice_lock->seq_region_end,
         $author_id,
         $slice_lock->active, $slice_lock->freed, $freed_author_id,
         $slice_lock->intent, $slice_lock->hostname);

      $slice_lock->adaptor($self);
      my $slice_lock_id = $self->last_insert_id('slice_lock_id', undef, 'slice_lock')
        or throw('Failed to get new autoincremented ID for lock');
      $slice_lock->dbID($slice_lock_id);

      $self->freshen($slice_lock);
  }

  return 1;
}

# After database engine has set timestamps or other fields,
# fetch them to keep object up-to-date
sub freshen {
    my ($self, $stale) = @_;
    my $dbID = $stale->dbID;
    throw("Cannot freshen an un-stored SliceLock") unless $dbID;
    my $fresh = $self->fetch_by_dbID($dbID);
    local $stale->{_mutable} = 'freshen';
    foreach my $field ($stale->FIELDS()) {
        my ($stV, $frV) = ($stale->$field, $fresh->$field);
        if (ref($stV) && ref($frV) &&
            $stV->dbID == $frV->dbID) {
            # object, with matching dbID --> no change
        } else {
            $stale->$field($frV);
        }
    }
    return;
}


=head2 do_lock($lock)

Given a lock in the C<active='pre'> state, attempt to bring it to
C<active='held'>.

On return the object will have been L</freshen>ed to match the
database.  The return value is true for success, false for an ordinary
failure where something else got there first.

Exceptions may be raised if $lock was in some unexpected state.

=cut

sub do_lock {
    my ($self, $lock) = @_;

    # relevant properties
    my ($lock_id, $active, $srID, $sr_start, $sr_end) =
      ($lock->dbID, $lock->active,
       $lock->seq_region_id, $lock->seq_region_start, $lock->seq_region_end);
    my $author_id = $self->_author_dbID(author => $lock->author);

    throw("do_lock($lock_id) failed: expected active=pre, got active=$active")
      unless $active eq 'pre';

    # Check for non-free locks on our slice
    my ($seen_self, @too_late) = (0);
    my $sth_check = $self->prepare(q{
      SELECT slice_lock_id, active, freed
      FROM slice_lock
      WHERE active in ('pre', 'held')
        AND seq_region_id = ?
        AND seq_region_start = ?
        AND seq_region_end = ?
    });
    $sth_check->execute($srID, $sr_start, $sr_end);
    while (my $row = $sth_check->fetch) {
        my ($ch_slid, $ch_act, $ch_freed) = @$row;
        if ($ch_slid == $lock_id) {
            # us
            if ($ch_act eq $active) {
                $seen_self ++;
            } elsif ($ch_act eq 'free' && $ch_freed eq 'too_late') {
                $seen_self ++;
                push @too_late, "before stale do_lock, by slid=$ch_slid";
            } else {
                throw "do_lock($ch_slid) failed: input not fresh - active=$ch_act";
            }
        } else {
            # them
            if ($ch_act eq 'pre') {
                # Potential race: either they will free(too_late) us,
                # we will free(too_late) them in our next query.
            } else {
                # Either our 'pre' was added after their 'held'
                # existed, so they didn't UPDATE us to free(too_late);
                # or we have been UPDATEd to free(too_late) already.
                push @too_late,
                  "early do_lock / before insert, by slid=$ch_slid";
            }
        }
    }
    throw("do_lock($lock_id) failed: did not see our row match")
      unless $seen_self;

    if (@too_late) {
        # "Early" too_late detection above, tidy up
        my $sth_free = $self->prepare(q{
      UPDATE slice_lock
      SET active='free'
        , freed='too_late'
        , ts_free=now()
      WHERE slice_lock_id = ?
        AND active <> 'free'
        AND freed <> 'too_late'
        });
        my $rv = $sth_free->execute($lock_id);
        push @too_late, "(tidy rv=$rv)"; # for debug only
    } else {
        # Have a chance for the lock, do atomic update for exclusion
        my $sth_activate = $self->prepare(q{
      UPDATE slice_lock
      SET active          = if(slice_lock_id = ?, 'held', 'free')
        , ts_activity     = if(slice_lock_id = ?, now(), ts_activity)
        , freed           = if(slice_lock_id = ?, null, 'too_late')
        , ts_free         = if(slice_lock_id = ?, null, now())
        , freed_author_id = if(slice_lock_id = ?, null, ?)
      WHERE slice_lock_id = ?
        AND active='pre'
        AND seq_region_id = ?
        AND seq_region_end >= ?
        AND seq_region_start <= ?
        });
        my $rv = $sth_activate->execute
          ($lock_id, $lock_id, $lock_id, $lock_id, $lock_id,
           $author_id,
           $lock_id, $srID, $sr_start, $sr_end);
        push @too_late, # for debug only
          $rv ? "race looks won? (rv=$rv)" : "beaten in race? (rv=$rv)";
    }

    $self->freshen($lock);
    $active = $lock->active;
    if ($active eq 'free') {
        return 0;
    } elsif ($active eq 'held') {
        return 1;
    } else {
        throw "do_lock($lock_id) confused, active=$active";
    }
}


=head2 unlock($slice_lock, $unlock_author, $freed)

$freed defaults to C<finished>, which is the expected value when
$unlock_author is the lock owner.  Other authors must set $freed to
C<interrupted> or C<expired>, and be able to justify doing this.

Throws an exception if the lock was already free in-memory.

$slice_lock is freed and its properties are updated from the database.

Throws an exception if the lock was freed asynchronously in the
database (e.g. to the C<freed(interrupted)> state).

Then returns true.

=cut

sub unlock {
  my ($self, $slice_lock, $unlock_author, $freed) = @_;
  $freed = 'finished' if !defined $freed;
  my $dbID = $slice_lock->dbID;

  my $author_id = $self->_author_dbID(author => $slice_lock->author);
  my $freed_author_id = $self->_author_dbID(freed_author => $unlock_author)
    or throw "unlock must be done by some author";
  throw "SliceLock dbID=$dbID is already free (in-memory)"
    unless $slice_lock->is_held || $slice_lock->active eq 'pre';

  # the freed type is constrained, depending on freed_author
  if ($freed_author_id == $author_id) {
      # Original author frees her own lock
      throw "unlock type '$freed' inappropriate for same-author unlock"
        unless $freed eq 'finished';
  } else {
      # Somebody else frees her lock (presumably with good reason)
      my $a_email = $slice_lock->author->email;
      my $f_email = $unlock_author->email;
      throw "unlock type '$freed' inappropriate for $f_email acting on $a_email lock"
        unless grep { $_ eq $freed } qw( expired interrupted );
  }

  my $sth = $self->prepare(q{
    UPDATE slice_lock
    SET active='free', freed=?, freed_author_id=?, ts_free=now()
    WHERE slice_lock_id = ?
      AND active <> 'free'
  });
  my $rv = $sth->execute($freed, $freed_author_id, $dbID);

  $self->freshen($slice_lock);

  throw "SliceLock dbID=$dbID was already free (async lock-break?).  UPDATE...SET active=free... failed, rv=$rv"
    unless $rv == 1;

  return 1;
}


1;
