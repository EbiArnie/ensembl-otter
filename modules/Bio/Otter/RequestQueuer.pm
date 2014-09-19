
### Bio::Otter::RequestQueuer

package Bio::Otter::RequestQueuer;

use strict;
use warnings;

use Log::Log4perl;
use Scalar::Util qw{ weaken };
use Try::Tiny;

sub new {
    my ($pkg, $session) = @_;

    my $client = $session->AceDatabase->Client;
    my $self = {
        '_session'          => $session,
        '_queue'            => [],
        '_current_requests' => {},
        '_resource_bins'    => {},
        '_cfg_concurrent'   => $client->config_section_value(RequestQueue => 'concurrent'),
        '_cfg_min_batch'    => $client->config_section_value(RequestQueue => 'min-batch'),
        '_cfg_send_queued_callback_timeout_ms' =>
            $client->config_section_value(RequestQueue => 'send-queued-callback-timeout-ms'),
        '_cfg_requests_per_bin' => 2, # try a simple global per-bin config before going further
    };
    weaken($self->{_session});
    bless $self, $pkg;

    my $logger = $self->_logger;
    $logger->debug('_cfg_concurrent: ', $self->_cfg_concurrent                      || '<unset>');
    $logger->debug('_cfg_min_batch:  ', $self->_cfg_min_batch                       || '<unset>');
    $logger->debug('_cfg_sqcbto_ms:  ', $self->_cfg_send_queued_callback_timeout_ms || '<unset>');

    return $self;
}

# Accepts Filter objects or column names
sub request_features {
    my ($self, @feature_list) = @_;
    $self->_queue_features(@feature_list);
    $self->_send_queued_requests;
    return;
}

sub _queue_features {
    my ($self, @feature_list) = @_;
    push @{$self->_queue}, @feature_list;
    $self->_logger->debug('_queue_features: queued ', scalar(@feature_list));
    return;
}

sub _send_queued_requests {
    my ($self) = @_;

    my $logger = $self->_logger;

    if (my $id = $self->_sender_timeout_id) {
        $id->cancel;
        $self->_sender_timeout_id(undef);
    }

    my $slots = $self->_slots_available;
    if ($slots < $self->_cfg_min_batch) {
        # This is only really required to avoid excessive interleaving in Zircon :-(
        $logger->debug("_send_queued_requests: min batch size not reached");
        return;
    }

    my $queue = $self->_queue;
    my @to_send;

  SLOTS: while ($self->_slots_available and $self->_queue_not_empty) {

      my ($current, $bin);
    QUEUE: foreach my $i ( 0 .. $#{$queue} ) {

        my $request = $queue->[$i];
        $bin = $self->_request_resource_bin($request);
        next QUEUE unless $bin;

        $current = $self->_request_to_name($request);
        splice @$queue, $i, 1;
        last QUEUE;
    }
      # if we didn't find an available resource, we're done here
      unless ($current) {
          $logger->debug("_send_queue_requests: no free resources for current queue");
          last SLOTS;
      }

      push @to_send, $current;
      $self->_current_request($current, $bin);
  }

    if (@to_send) {
        my $to_send_debug = join(',', @to_send);
        $logger->debug("_send_queued_requests: requesting '${to_send_debug}', ", scalar(@$queue), " remaining");

        try {
            $self->session->zmap->load_features(@to_send);
            $self->session->ColumnChooser->update_statuses_by_name('Loading', @to_send);
        }
        catch {
            my $err = $_;
            my $requeue;

            # This will never get hit under ZeroMQ, but code left in case it's useful:
            $requeue = 'send_command_and_xml timeout' if $err =~ /send_command_and_xml: timeout/;
            if ($requeue) {
                $logger->warn(
                  "_send_queued_requests: load_features Zircon request failed [$requeue], requeuing '${to_send_debug}'"
                  );
                $self->_clear_request($_) foreach @to_send;
                unshift @$queue, @to_send;
                # Set a timeout in case we're not called before
                my $id = $self->session->top_window->after(
                    $self->_cfg_send_queued_callback_timeout_ms,
                    sub {
                        $logger->debug('_send_queued_requests: timeout callback');
                        return $self->_send_queued_requests;
                    });
                $self->_sender_timeout_id($id);
            } else {
                die $err;
            }
        };

    } else {
        $logger->debug("_send_queued_requests: nothing to send, ",
                              scalar(@$queue) ? 'no slots' : 'queue empty');
    }

    return;
}

sub _sender_timeout_id {
    my ($self, @args) = @_;
    ($self->{'_sender_timeout_id'}) = @args if @args;
    my $_sender_timeout_id = $self->{'_sender_timeout_id'};
    return $_sender_timeout_id;
}

sub features_loaded_callback {
    my ($self, @loaded_features) = @_;

    foreach my $loaded (@loaded_features) {
        my $bin = $self->_current_request($loaded);
        unless ($bin) {
            $self->_logger->warn("features_loaded_callback: no request in progress for '$loaded'");
            next;
        }

        $self->_logger->debug("features_loaded_callback: loaded '$loaded', resource_bin '$bin'");
        $self->_clear_request($loaded, $bin);
    }
    $self->_send_queued_requests;
    return;
}

sub flush_current_requests {
    my ($self) = @_;
    $self->{'_current_requests'} = {};
    $self->{'_resource_bins'} = {};
    return;
}

sub _slots_available {
    my ($self) = @_;
    my $n_current = scalar keys %{$self->{_current_requests}};
    my $available = $self->_cfg_concurrent - $n_current;
    $available = 0 if $available < 0;
    return $available;
}

sub session {
    my ($self, @args) = @_;
    ($self->{'_session'}) = @args if @args;
    my $session = $self->{'_session'};
    return $session;
}

sub _queue {
    my ($self) = @_;
    my $_queue = $self->{'_queue'};
    return $_queue;
}

sub _queue_not_empty {
    my ($self) = @_;
    return @{$self->_queue};
}

sub _current_request {
    my ($self, $feature, @args) = @_;
    ($self->{'_current_requests'}->{$feature}) = @args if @args;
    my $_current_request = $self->{'_current_requests'}->{$feature};
    return $_current_request;
}

sub _clear_request {
    my ($self, $feature, $bin) = @_;
    $self->{_resource_bins}->{$bin}--;
    return delete $self->{'_current_requests'}->{$feature};
}

sub _request_resource_bin {
    my ($self, $request) = @_;
    my $resource_bin = $self->_request_to_resource_bin($request);

    my $bins = $self->{_resource_bins};
    my $count = $bins->{$resource_bin};
    if ($count and $count >= $self->_cfg_requests_per_bin) {
        return;                 # bin full
    }
    $bins->{$resource_bin}++;
    return $resource_bin;
}

sub _request_to_name {
    my ($self, $request) = @_;
    if (ref($request)) {
        return $request->name;
    } else {
        return $request;
    }
}

sub _request_to_resource_bin {
    my ($self, $request) = @_;
    if (ref($request)) {
        if ($request->can('resource_bin')) {
            return $request->resource_bin;
        } else {
            return $request->name;
        }
    } else {
        return $request;
    }
}

sub _cfg_concurrent {
    my ($self, @args) = @_;
    ($self->{'_cfg_concurrent'}) = @args if @args;
    my $_cfg_concurrent = $self->{'_cfg_concurrent'};
    return $_cfg_concurrent;
}

sub _cfg_min_batch {
    my ($self, @args) = @_;
    ($self->{'_cfg_min_batch'}) = @args if @args;
    my $_cfg_min_batch = $self->{'_cfg_min_batch'};
    return $_cfg_min_batch;
}

sub _cfg_send_queued_callback_timeout_ms {
    my ($self, @args) = @_;
    ($self->{'_cfg_send_queued_callback_timeout_ms'}) = @args if @args;
    my $_cfg_send_queued_callback_timeout_ms = $self->{'_cfg_send_queued_callback_timeout_ms'};
    return $_cfg_send_queued_callback_timeout_ms;
}

sub _cfg_requests_per_bin {
    my ($self, @args) = @_;
    ($self->{'_cfg_requests_per_bin'}) = @args if @args;
    my $_cfg_requests_per_bin = $self->{'_cfg_requests_per_bin'};
    return $_cfg_requests_per_bin;
}

sub _logger {
    my ($self, $category) = @_;
    $category = scalar caller unless defined $category;
    return $self->session->logger($category);
}

1;

__END__

=head1 NAME - Bio::Otter::RequestQueuer

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk
