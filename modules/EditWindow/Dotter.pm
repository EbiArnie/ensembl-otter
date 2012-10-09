
### EditWindow::Dotter

package EditWindow::Dotter;

use strict;
use warnings;
use Carp;
use Hum::Ace::DotterLauncher;
use Tk::LabFrame;
use base 'EditWindow';

sub initialise {
    my ($self) = @_;

    my $top = $self->top;

    my $dotter = Hum::Ace::DotterLauncher->new;
    $self->dotter($dotter);

    # Entry box for match at top
    my $match_frame = $top->Frame(
        -border => 3,
        )->pack(
            -side   => 'top',
            );
    $match_frame->Label(
        -text   => 'Match name:',
        -anchor => 's',
        -padx   => 6,
        )->pack(-side => 'left');
    $self->match(
        $match_frame->Entry(
            -width  => 16,
            )->pack(-side => 'left')
        );

    # Pad between entries
    $match_frame->Frame(
        -width  => 10,
        )->pack(-side => 'left');


    # Whether to open dotter with rev-comp'd match sequence
    my $rev_comp = 0;
    $self->revcomp_ref(\$rev_comp);
    $match_frame->Checkbutton(
        -text       => 'Reverse strand',
        -variable   => \$rev_comp,
        )->pack(-side => 'left');


    # Labelled frame around all the Genomic stuff
    my $lab_frame = $top->LabFrame(
        -border => 3,
        -label  => 'Genomic sequence',
        )->pack(
        -side   => 'top',
        -expand => 1,
        -fill   => 'both',
        );

    # Name of genomic sequence
    Tk::grid(
        $lab_frame->Label(
            -text   => 'Name:',
            -anchor => 'w',
        ),
        $self->genomic(
            $lab_frame->Entry(
                -width  => 30,
                -state  => 'disabled',
                # Recent versions of Tk::Entry have a
                # third state "readonly" which allows
                # the name to still be selected to copy
                # it to the clipboard.
            ),
        ),
        '-sticky' => 'nsew');

    # Region radio buttons
    my $region_frame = $lab_frame->Frame;
    Tk::grid(
        $lab_frame->Label(
            -text   => 'Region:',
            -anchor => 'w',
        ),
        $region_frame,
        '-sticky' => 'nsew');
    Tk::grid(
        (map { ## no critic (BuiltinFunctions::ProhibitComplexMappings)
            my ($text, $value) = @{$_};
            $region_frame->Radiobutton(
                -variable => \$self->{_use_mark},
                -text     => $text,
                -value    => $value,
                );
         } ([ 'All',  0 ], [ 'Marked region', 1 ], )),
        '-sticky' => 'ns');
    $region_frame->gridColumnconfigure($_, '-weight' => 1)
        for 0..1;
    $self->{_use_mark} = 1;

    my $button_frame = $top->Frame->pack(
        -side   => 'top',
        -fill   => 'x',
        );

    # Launch dotter
    my $launch = sub {
        $self->launch_dotter or return;
        $top->withdraw;
        };
    $button_frame->Button(
        -text       => 'Launch',
        -underline  => 0,
        -command    => $launch,
        )->pack(-side => 'left');
    $top->bind('<Control-l>', $launch);
    $top->bind('<Control-L>', $launch);

    # Update coords
    my $update = sub {
        $self->update_from_clipboard;
        };
    $button_frame->Button(
        -text       => 'Update',
        -underline  => 0,
        -command    => $update,
        )->pack(-side => 'left');
    $top->bind('<Control-u>', $update);
    $top->bind('<Control-U>', $update);

    # Manage window closes and destroys
    my $close_window = sub{ $top->withdraw };
    $button_frame->Button(
        -text       => 'Close',
        -command    => $close_window,
        )->pack(-side => 'right');
    $top->bind('<Control-w>',           $close_window);
    $top->bind('<Control-W>',           $close_window);
    $top->protocol('WM_DELETE_WINDOW',  $close_window);

    $top->bind('<Destroy>', sub{ $self = undef });

    return;
}

sub SessionWindow {
    my ($self, $SessionWindow) = @_;
    $self->{_SessionWindow} = $SessionWindow if $SessionWindow;
    return $self->{_SessionWindow};
}

sub update_from_SessionWindow {
    my ($self, $SessionWindow) = @_;

    $self->query_Sequence($SessionWindow->Assembly->Sequence);
    $self->genomic->configure(-state => 'normal');
    $self->set_entry('genomic', $SessionWindow->slice_name);
    $self->genomic->configure(-state => 'disabled');
    $self->update_from_clipboard;
    my $top = $self->top;
    $top->deiconify;
    $top->raise;

    return;
}

sub query_Sequence {
    my ($self, $query_Sequence) = @_;

    if ($query_Sequence) {
        $self->{'_query_Sequence'} = $query_Sequence;
    }
    return $self->{'_query_Sequence'};
}

my $name_from_clipboard_pattern = # match fMap "blue box"
    qr!^(?:<?(?:Protein|Sequence)[:>]?)?\"?([^\"\s]+)\"?\s+-?\d+\s+-?\d+\s+\(\d+\)!;

sub update_from_clipboard {
    my ($self) = @_;
    my $text = $self->get_clipboard_text or return;
    my ($name) = $text =~ /$name_from_clipboard_pattern/ or return;
    $self->set_entry('match', $name);
    return;
}

sub set_entry {
    my ($self, $method, $txt) = @_;

    my $entry = $self->$method();
    $entry->delete(0, 'end');
    $entry->insert(0, $txt);

    return;
}

sub get_entry {
    my ($self, $method) = @_;

    my $txt = $self->$method()->get or return;
    $txt =~ s/\s//g;
    return $txt;
}

sub match {
    my ($self, $match) = @_;

    if ($match) {
        $self->{'_match'} = $match;
    }
    return $self->{'_match'};
}

sub genomic {
    my ($self, $genomic) = @_;

    if ($genomic) {
        $self->{'_genomic'} = $genomic;
    }
    return $self->{'_genomic'};
}

sub revcomp_ref {
    my ($self, $revcomp_ref) = @_;

    if ($revcomp_ref) {
        $self->{'_revcomp_ref'} = $revcomp_ref;
    }
    return $self->{'_revcomp_ref'};
}

sub dotter {
    my ($self, $dotter) = @_;

    if ($dotter) {
        $self->{'_dotter'} = $dotter;
    }
    return $self->{'_dotter'};
}

sub launch_dotter {
    my ($self) = @_;

    my $match_name = $self->get_entry('match');
    my $genomic    = $self->query_Sequence;
    my $revcomp    = $self->revcomp_ref;

    unless ($match_name and $genomic and $genomic) {
        warn "Missing parameters\n";
        return;
    }

    my $length = $genomic->sequence_length;
    my ($start, $end) =
        ($self->{'_use_mark'})
        ? $self->SessionWindow->zmap->get_mark
        : (1, $length);
    (defined $start && $start >= 1)       or $start = 1;
    (defined $end   && $end   <= $length) or $end   = $length;
    ($start, $end) = ($end, $start) if $start > $end;

    my $dotter = $self->dotter;
    $dotter->query_Sequence($genomic);
    $dotter->query_start($start);
    $dotter->query_end($end);
    $dotter->subject_name($match_name);
    $dotter->revcomp_subject($$revcomp);

    return $dotter->fork_dotter;
}

sub DESTROY {
    #warn "Freeing DotterWindow\n";
}



1;

__END__

=head1 NAME - EditWindow::Dotter

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

