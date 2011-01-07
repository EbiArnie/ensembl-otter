
### CanvasWindow::DataSetChooser

package CanvasWindow::DataSetChooser;

use strict;
use warnings;
use Carp;
use Tk::DialogBox;
use base 'CanvasWindow';
use EditWindow::LoadColumns;
use CanvasWindow::SequenceSetChooser;

sub new {
    my( $pkg, @args ) = @_;
    
    my $self = $pkg->SUPER::new(@args);
    
    my $canvas = $self->canvas;
    $canvas->Tk::bind('<Button-1>', sub{
            $self->deselect_all;
            $self->select_dataset;
        });
    my $open_command = sub{ $self->open_dataset; };
    $canvas->Tk::bind('<Double-Button-1>',  $open_command);
    $canvas->Tk::bind('<Return>',           $open_command);
    $canvas->Tk::bind('<KP_Enter>',         $open_command);
    $canvas->Tk::bind('<Control-o>',        $open_command);
    $canvas->Tk::bind('<Control-O>',        $open_command);
    $canvas->Tk::bind('<Escape>', sub{ $self->deselect_all });
    
    my $quit_command = sub{
        $self->canvas->toplevel->destroy;
        $self = undef;  # $self gets nicely DESTROY'd with this
    };
    $canvas->Tk::bind('<Control-q>',    $quit_command);
    $canvas->Tk::bind('<Control-Q>',    $quit_command);
    $canvas->toplevel
        ->protocol('WM_DELETE_WINDOW',  $quit_command);
        
    my $top = $canvas->toplevel;
    my $button_frame = $top->Frame->pack(-side => 'top', -fill => 'x');

    my $open = $button_frame->Button(
        -text       => 'Open',
        -command    => sub{
            unless ($self->open_dataset) {
                $self->message("No dataset selected - click on a name to select one");
            }
        },
    )->pack(-side => 'left');

    my $recover = $button_frame->Button(
        -text       => "Recover sessions",
        -command    => sub{
            $self->recover_some_sessions;
        },
    )->pack(-side => 'left');

    my $quit = $button_frame->Button(
        -text       => 'Quit',
        -command    => $quit_command,
    )->pack(-side => 'right');
        
    return $self;
}

sub Client {
    my( $self, $Client ) = @_;
    
    if ($Client) {
        $self->{'_Client'} = $Client;
    }
    return $self->{'_Client'};
}

sub select_dataset {
    my( $self ) = @_;
    
    return if $self->delete_message;
    my $canvas = $self->canvas;
    if (my ($current) = $canvas->find('withtag', 'current')) {
        $self->highlight($current);
    } else {
        $self->deselect_all;
    }

    return;
}

sub open_dataset {
    my( $self ) = @_;
    
    return if $self->recover_some_sessions;
    
    my ($obj) = $self->list_selected;
    return unless $obj;
    
    my $canvas = $self->canvas;
    $canvas->Busy;
    foreach my $tag ($canvas->gettags($obj)) {
        if ($tag =~ /^DataSet=(.+)/) {
            my $name = $1;
            my $client = $self->Client;
            my $ds = $client->get_DataSet_by_name($name);

            my $top = $self->{'_sequence_set_chooser'}{$name};
            if (Tk::Exists($top)) {
                $top->deiconify;
                $top->raise;
            } else {
                $top = $canvas->Toplevel(-title => "DataSet $name");
                my $ssc = CanvasWindow::SequenceSetChooser->new($top);

                $ssc->name($name);
                $ssc->Client($client);
                $ssc->DataSet($ds);
                $ssc->DataSetChooser($self);
                $ssc->draw;

                $self->{'_sequence_set_chooser'}{$name} = $top;
            }
            $canvas->Unbusy;
            return 1;
        }
    }
    $canvas->Unbusy;

    return;
}

sub draw {
    my( $self ) = @_;

    my $canvas = $self->canvas;

    $canvas->toplevel->withdraw;
    my @dsl = $self->Client->get_all_DataSets;
    $canvas->toplevel->deiconify;
    $canvas->toplevel->raise;
    $canvas->toplevel->focus;

    my $font = $self->font_fixed_bold;
    my $size = $self->font_size;
    my $row_height = int $size * 1.5;
    for (my $i = 0; $i < @dsl; $i++) {
        my $data_set = $dsl[$i];
        my $x = $size;
        my $y = $row_height * (1 + $i);
        $canvas->createText(
            $x, $y,
            -text   => $data_set->name,
            -font   => $font,
            -anchor => 'nw',
            -tags   => ['DataSet=' . $data_set->name],
            );
    }
    $self->fix_window_min_max_sizes;

    return;
}

sub recover_some_sessions {
    my ($self) = @_;

    my $client = $self->Client();
    my $recoverable_sessions = $client->sessions_needing_recovery();
    
    if (@$recoverable_sessions) {
        my %session_wanted = map { $_->[0] => 1 } @$recoverable_sessions;

        my $rss_dialog = $self->canvas->toplevel->DialogBox(
            -title => 'Recover sessions',
            -buttons => ['Recover', 'Cancel'],
        );

        $rss_dialog->add('Label',
            -wrap    => 400,
            -justify => 'left',
            -text    => join("\n\n",
                "You have one or more lace sessions on this computer which are not"
                . " associated with a running otterlace process.",

                "This should not happen, except where lace has crashed or it has"
                . " been exited by pressing the exit button in the 'Choose Dataset'"
                . " window.",

                "You will need to recover and exit these sessions. There may be"
                . " locks left in the otter database or some of your work which has"
                . " not been saved.",
                
                "Please contact anacode if you still get an error when you attempt"
                . " to exit the session, or have information about the error which"
                . " caused a session to be left.",
                ), 
        )->pack(-side=>'top', -fill=>'x', -expand=>1);
        
        foreach my $rec (@$recoverable_sessions) {
            my ($session_dir, $date, $title) = @$rec;
            my $full_session_title = sprintf "%s - %s", scalar localtime($date), $title;
            my $cb = $rss_dialog->add('Checkbutton',
                -text     => $full_session_title,
                -variable => \$session_wanted{$session_dir},
                -onvalue  => 1,
                -offvalue => 0,
                -anchor   => 'w',
            )->pack(-side=>'top', -fill=>'x', -expand=>1);
        }

        my $answer = $rss_dialog->Show();

        my @selected_recs = grep { $session_wanted{$_->[0]} } @$recoverable_sessions;

        if ($answer=~/recover/i && @selected_recs) {
            eval{
                my $canvas = $self->canvas;

                foreach my $rec (@selected_recs) {
                    my ($session_dir, $date, $title) = @$rec;
                    
                    # Bring up GUI
                    my $adb = $client->recover_session($session_dir);
                    
                    my $top = $canvas->Toplevel(
                        -title  => 'Select column data to load',
                    );
                    
                    my $lc = EditWindow::LoadColumns->new($top);
                    $lc->AceDatabase($adb);
                    $lc->DataSetChooser($self);
                    $lc->initialize;
                    $lc->change_checkbutton_state('deselect');
                    $lc->load_filters;
                    $top->withdraw;
                }
            };
            if ($@) {
                # Destruction of the AceDatabase object prevents us seeing $@
                $self->exception_message($@, 'Error recovering lace sessions');
            }
            return 1;
        } else {
            return 0;
        }
    } else {
        return 0;
    }
}


1;

__END__

=head1 NAME - CanvasWindow::DataSetChooser

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

