
package Bio::Otter::UI::ZMapSelectMixin;

#  A mixin module for UI classes that want to popup a "Select ZMap"
#  window.

use strict;
use warnings;

use Tk::Toplevel;
use Tk::Radiobutton;

use Zircon::ZMap;

sub zmap_select_initialize {
    my ($self) = @_;
    $self->{'_zmap_select'} = '';
    return;
}

sub zmap_select_window {
    my ($self) = @_;

    my $window = $self->ZMapSelectWindow;
    $window->destroy if $window;

    $window = $self->zmap_select_widget->Toplevel;
    $window->title("Select ZMap");
    $self->ZMapSelectWindow($window);

    my $close_command = sub {
        $window->destroy;
        $self->ZMapSelectWindow(undef);
    };
    $window->protocol( 'WM_DELETE_WINDOW', $close_command );

    $self->_zmap_select_button($_) for
        '', @{Zircon::ZMap->list};

    $window->Button(
        -text    => 'Close',
        -command => $close_command,
        )
        ->pack(
        -side => 'top',
        -fill => 'both',
        );

    # _colour_init
    my $sw;
    $sw = $self->SessionWindow if $self->can('SessionWindow');
    $sw = $self if $self->isa('MenuCanvasWindow::SessionWindow');
    if ($sw) {
        $sw->colour_init($window);
    } else {
        warn "$self uncoloured, cannot SessionWindow";
    }

    return;
}

sub _zmap_select_button {
    my ($self, $zmap) = @_;
    my $text = $zmap
        ? ( join ' / ', map { $_->name } @{$zmap->view_list} )
        : 'New';
    $self->ZMapSelectWindow->Radiobutton(
        -text     => $text,
        -value    => "$zmap",
        -variable => \ $self->{'_zmap_select'},
        )
        ->pack(
        -side => 'top',
        -fill => 'both',
        );
    return;
}

sub zmap_select {
    my ($self) = @_;
    my $zmap;
    if (my $zmap_string = $self->{'_zmap_select'}) {
        $zmap = Zircon::ZMap->from_string($zmap_string)
            or warn sprintf "ZMap '%s' has disappeared", $zmap_string;
    }
    return $zmap;
}

sub zmap_select_destroy {
    my ($self) = @_;
    if ($self->ZMapSelectWindow) {
        $self->ZMapSelectWindow->destroy;
        $self->ZMapSelectWindow(undef);
    }
    return;
}

# attributes

sub ZMapSelectWindow {
    my ($self, @args) = @_;
    ($self->{'_ZMapSelectWindow'}) = @args if @args;
    my $ZMapSelectWindow = $self->{'_ZMapSelectWindow'};
    return $ZMapSelectWindow;
}

# and now a kludge to work around the lack of a single method name
# that accesses the top level widget across all our window classes 

## no critic (Modules::ProhibitMultiplePackages)

package EditWindow;

sub zmap_select_widget {
    my ($self) = @_;
    my $zmap_select_widget = $self->top;
    return $zmap_select_widget;
}

package CanvasWindow;

sub zmap_select_widget {
    my ($self) = @_;
    my $zmap_select_widget = $self->top_window;
    return $zmap_select_widget;
}

1;

__END__

=head1 NAME - Bio::Otter::UI::ZMapSelectMixin

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

