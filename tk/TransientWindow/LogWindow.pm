package TransientWindow::LogWindow;

use strict;
use TransientWindow;
use Symbol 'gensym';

our @ISA   = qw(TransientWindow);

my $email  = q`anacode`;
my $domain = q`sanger.ac.uk`;
my @mail   = qw(smtp Server localhost);
my $allow_mailing = 1;
my $loggingOn     = 0;

sub initialise{
    my $self = shift;
    $self->SUPER::initialise(@_);
    $self->get_log_contents(1);
    return;
}

sub draw{
    my $self   = shift;
    return if $self->{'_drawn'};

    my $lw        = $self->window;
    my $top_frame = $lw->Frame->pack(-side => 'top', -fill => 'both', -expand => 1);
    my $but_frame = $lw->Frame->pack(-side => 'top', -fill => 'x');
    my $scrolled  = $top_frame->Scrolled('ROText',
                                         -font             => ['lucidatypewriter', 10, 'normal'],
                                         -padx             => 6,
                                         -pady             => 6,
                                         -relief           => 'groove',
                                         -background       => 'white',
                                         -border           => 2,
                                         -selectbackground => 'gold',
                                         -scrollbars       => 'se',
                                         #-exportselection => 1,
                                         )->pack(
                                                 -expand => 1,
                                                 -fill   => 'both',
                                                 );
    my $ROText = $scrolled->Subwidget('rotext');
    unless($^O eq 'MSWin32'){
        my $y_scroll = $ROText->parent->Subwidget('yscrollbar');
        $ROText->Tk::bind('<4>', sub{
            $y_scroll->ScrlByUnits('v', -3);
        });
        $ROText->Tk::bind('<5>', sub{
            $y_scroll->ScrlByUnits('v',  +3);
        });
    }

    my $string = $self->get_log_contents();
    $ROText->delete('1.0', 'end');
    $ROText->insert('end', $string);
    $self->readonly_text($ROText);

    my $email_dev = sub { $self->mail_contents(); };
    $but_frame->Button(-text    => qq`Email $email`,
                       -command => $email_dev,
                       )->pack(-side => 'left') if $self->draw_email_flag() && $allow_mailing;
    $but_frame->Button(-text => 'SelectAll',
                       -command => sub { $self->readonly_text->selectAll() },
                       )->pack(-side => 'left');
    $but_frame->Button(-text    => 'Close',
                       -command =>  $self->hide_me_ref,
                       )->pack(-side => 'right');
    $but_frame->Button(-text => 'Refresh',
                       -command => sub { $self->refresh },
                       )->pack(-side => 'right');

    $but_frame->bind('<Destroy>' , sub {
        $self->do_callback_unregister();
        $self = undef; 
    }
                     );
    
    $self->{'_drawn'} = 1;
    return;
}
sub show_me{
    my ($self) = @_;
    $self->refresh();
    $self->do_callback_register();
    return $self->SUPER::show_me;
}
sub hide_me_ref{
    my $self = shift;
    my $ref  = $self->{'_hide_the_window'};
    unless($ref){
        my $window = $self->window();
        $self->{'_hide_the_window'} = $ref = sub{ 
            do_callback_unregister();
            $window->withdraw(); 
        };
    }
    return $ref;
}

sub refresh{
    my $self   = shift;
    my $string = $self->get_log_contents(1);
    my $ROText = $self->readonly_text();
    #warn "$self is refreshing\n";
    $ROText->delete('1.0', 'end');
    $ROText->insert('end',$string);
}

sub readonly_text{
    my ($self, $widget) = @_;
    $self->{'_rotext'} = $widget if $widget;
    return $self->{'_rotext'};
}
sub do_callback_register{
    my $self = shift;
    Bio::Otter::Lace::LogFile::register_callback(sub { $self->refresh }) if $loggingOn;
}
sub do_callback_unregister{
    Bio::Otter::Lace::LogFile::register_callback(undef) if $loggingOn;
}
sub draw_email_flag{
    my ($self, $flag) =  @_;
    if(defined $flag){
        $self->{'_draw_email_flag'} = ($flag ? 1 : 0);
    }
    return $self->{'_draw_email_flag'} || 0; # default is not to draw it
}

sub get_log_contents{
    my ($self, $refresh) = @_;
    
    if($refresh || !($self->{'_log_contents'})){
        my @log_strings = ();
        if($INC{'Bio/Otter/Lace/LogFile.pm'}){
            $loggingOn = 1;
            @log_strings = Bio::Otter::Lace::LogFile::tail_log();
            $self->draw_email_flag(scalar @log_strings) unless $self->draw_email_flag;
            push(@log_strings, q`Log is currently empty.`) unless @log_strings;
        }else{
            @log_strings = (qq`Logging is turned off.\n`,
                            qq`To see the log start otterlace as:\n`,
                            qq`$0 -logdir /path/to/logfile`);
        }
        $self->{'_log_contents'} = join('', @log_strings);
    }
    return $self->{'_log_contents'};
}

sub mail_contents{
    my $self   = shift;
    my $pre    = '';
    my $to     = $email . '@' . $domain;
    my $subj   = "[otterlace] user's error log";
    my $dialog = $self->window->toplevel->DialogBox(
        -title   => "Email $to?", 
        -buttons => [qw(Ok Cancel)], -default_button => 'Cancel');
    
    my @defaults = (
                 -width         => 30,
                 -background    => 'white',
                 -labelPack     => [-side => 'left']
        );
    $dialog->add('LabEntry', 
                 -textvariable  => \$subj,
                 -label         => 'Subject: ',
                 @defaults,
                 )->pack();
    $dialog->add('LabEntry', 
                 -textvariable  => \$pre, 
                 -label         => 'Problem: ',
                 @defaults,
                 )->pack();
    $dialog->add('Label',
        -text => "Really send this error log to $to?")->pack();
    my $result = $dialog->Show();
    return unless $result eq 'Ok';

    my $mess = $self->get_log_contents();
    if($allow_mailing){
        $subj =~ s/(['"\$])/\\$1/g;   #escape ", ', \, and $. :))
        my $fh = gensym();
        my $mail_pipe = qq{| Mail -s "$subj" $to};
        open $fh, $mail_pipe or die "Error opening '$mail_pipe' : $!";
        print $fh "$pre\n$mess";
        close $fh or warn "Error emailing with pipe '$mail_pipe' : exit($?)";
    }else{
        print STDOUT "$pre\n$mess";
    }
}


1;





__END__

