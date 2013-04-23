
package Bio::Otter::ZMap::Core;

#  The transport/protocol independent code to manage ZMap processes.

use strict;
use warnings;

use Carp;
use Scalar::Util qw( weaken );
use POSIX ();

my @_list = ( );

sub list {
    my ($pkg) = @_;
    # filter the list because weak references may become undef
    my $list = [ grep { defined } @_list ];
    return $list;
}

my $_string_zmap_hash = { };

sub from_string {
    my ($pkg, $string) = @_;
    my $zmap = $_string_zmap_hash->{$string};
    return $zmap;
}

sub new {
    my ($pkg, %arg_hash) = @_;
    my $new = {
        '_program' => 'zmap',
    };
    bless($new, $pkg);
    push @_list, $new;
    weaken $_list[-1];
    $_string_zmap_hash->{"$new"} = $new;
    weaken $_string_zmap_hash->{"$new"};
    $new->_init(\%arg_hash);
    $new->launch_zmap;
    return $new;
}

sub _init {
    my ($self, $arg_hash) = @_;
    my $program = $arg_hash->{'-program'};
    $self->{'_program'} = $program if $program;
    $self->{'_arg_list'} = $arg_hash->{'-arg_list'};
    $self->{'_id_view_hash'} = { };
    $self->{'_view_list'} = [ ];
    $self->{'_conf_dir'} = $self->_conf_dir;
    $self->{'_config'} = $arg_hash->{'-config'};
    return;
}

sub _conf_dir {
    my $conf_dir = q(/var/tmp);
    my $user = getpwuid($<);
    my $dir_name = "otter_${user}";
    my $key = sprintf "%09d", int(rand(1_000_000_000));
    for ($dir_name, 'ZMap', $key) {
        $conf_dir .= "/$_";
        -d $conf_dir
            or mkdir $conf_dir
            or die sprintf "mkdir('%s') failed: $!", $conf_dir;
    }
    return $conf_dir;
}

sub _make_conf {
    my ($self) = @_;
    my $conf_file = sprintf "%s/ZMap", $self->conf_dir;
    open my $conf_file_h, '>', $conf_file
        or die sprintf
        "failed to open the configuration file '%s': $!"
        , $conf_file;
    print $conf_file_h $self->config;
    close $conf_file_h
        or die sprintf
        "failed to close the configuration file '%s': $!"
        , $conf_file;
    return;
}

sub launch_zmap {
    my ($self) = @_;

    $self->_make_conf;

    my @e = $self->zmap_command;
    warn "Running: @e\n";
    my $pid = fork;
    confess "Error: couldn't fork()\n" unless defined $pid;
    return if $pid;
    { exec @e; }
    # DUP: EditWindow::PfamWindow::initialize $launch_belvu
    # DUP: Hum::Ace::LocalServer
    warn "exec '@e' failed : $!";
    close STDERR; # _exit does not flush
    close STDOUT;
    POSIX::_exit(127); # avoid triggering DESTROY

    return; # unreached, quietens perlcritic
}

sub zmap_command {
    my ($self) = @_;
    my @zmap_command = ( $self->program, @{$self->zmap_arg_list} );
    return @zmap_command;
}

sub zmap_arg_list {
    my ($self) = @_;
    my $zmap_arg_list = [ '--conf_dir' => $self->conf_dir ];
    my $arg_list = $self->arg_list;
    push @{$zmap_arg_list}, @{$arg_list} if $arg_list;
    return $zmap_arg_list;
}

sub add_view {
    my ($self, $id, $view) = @_;
    $self->id_view_hash->{$id} = $view;
    weaken $self->id_view_hash->{$id};
    push @{$self->_view_list}, $view;
    weaken $self->_view_list->[-1];
    return;
}

# waiting

sub wait {
    my ($self) = @_;
    $self->{'_wait'} = 1;
    $self->waitVariable(\ $self->{'_wait'});
    return;
}

sub waitVariable {
    my ($self, $var) = @_;
    die sprintf
        "waitVariable() is not implemented in %s, "
        . "derived classes must implement it"
        , __PACKAGE__;
}

sub wait_finish {
    my ($self) = @_;
    $self->{'_wait'} = 0;
    delete $self->{'_wait'};
    return;
}

# attributes

sub config {
    my ($self) = @_;
    my $config = $self->{'_config'};
    return $config;
}

sub conf_dir {
    my ($self) = @_;
    my $conf_dir = $self->{'_conf_dir'};
    return $conf_dir;
}

sub program {
    my ($self) = @_;
    my $program = $self->{'_program'};
    return $program;
}

sub arg_list {
    my ($self) = @_;
    my $arg_list = $self->{'_arg_list'};
    return $arg_list;
}

sub id_view_hash {
    my ($self) = @_;
    my $id_view_hash = $self->{'_id_view_hash'};
    return $id_view_hash;
}

sub view_list {
    my ($self) = @_;
    # filter the list because weak references may become undef
    my $view_list = [ grep { defined } @{$self->_view_list} ];
    return $view_list;
}

sub _view_list {
    my ($self) = @_;
    my $view_list = $self->{'_view_list'};
    return $view_list;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

