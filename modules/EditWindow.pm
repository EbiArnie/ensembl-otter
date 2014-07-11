
### EditWindow

package EditWindow;

use strict;
use warnings;

use Try::Tiny;

use parent 'BaseWindow';


sub new {
    my ($pkg, $tk) = @_;

    my $self = bless {}, $pkg;
    $self->top($tk);
    return $self;
}

sub top {
    my ($self, $top) = @_;

    if ($top) {
        $self->{'_top'} = $top;
    }
    return $self->{'_top'};
}

sub balloon {
    my ($self) = @_;

    $self->{'_balloon'} ||= $self->top->Balloon(
        -state  => 'balloon',
        );
    return $self->{'_balloon'};
}

sub colour_init {
    my ($self, @widg) = @_;
    my $sw = $self->can('SessionWindow') && $self->SessionWindow;
    if ($sw) {
        $sw->colour_init($self->top, @widg);
    } else {
        # some just don't, but they should not call
        die "$self uncoloured, no SessionWindow (yet?)";
    }
    return;
}

sub set_minsize {
    my ($self) = @_;

    my $top = $self->top;
    $top->update;
    $top->minsize($top->width, $top->height);
    return;
}

sub get_clipboard_text {
    my ($self) = @_;

    my $top = $self->top;
    return unless Tk::Exists($top);

    return try {
        return $top->SelectionGet(
            -selection => 'PRIMARY',
            -type      => 'STRING',
            );
    };
}

1;

__END__

=head1 NAME - EditWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

