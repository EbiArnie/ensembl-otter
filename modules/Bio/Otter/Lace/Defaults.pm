
### Bio::Otter::Lace::Defaults

package Bio::Otter::Lace::Defaults;

use strict;
use warnings;
use Carp;
use Getopt::Long 'GetOptions';
use Config::IniFiles;
use POSIX 'uname';


my $CLIENT_STANZA   = 'client';
my $DEBUG_CONFIG    = 0;
#-------------------------------
my $CONFIG_INIFILES = [];
my %OPTIONS_TO_TIE  = (
                       -default     => 'default', 
                       -reloadwarn  => 1,
                       );

my $HARDWIRED = {};
tie %$HARDWIRED, 'Config::IniFiles', (-file => \*DATA, %OPTIONS_TO_TIE);
push(@$CONFIG_INIFILES, $HARDWIRED);

# The tied hash for the GetOptions variables
my $GETOPT = {};
tie %$GETOPT, 'Config::IniFiles', (%OPTIONS_TO_TIE);

my ($THIS_USER, $HOME_DIR) = (getpwuid($<))[0,7];
my $CALLED = "$0 @ARGV";

my @CLIENT_OPTIONS = qw(
    host=s
    port=s
    author=s
    email=s
    pipeline!
    write_access!
    group=s
    gene_type_prefix=s
    debug=i
    misc_acefile=s
    logdir=s
    fetch_truncated_genes!
    );

# @CLIENT_OPTIONS is Getopt::GetOptions() keys which will be included in the 
# $GETOPT->{$CLIENT_STANZA} hash.  To add another client option just include in above
# and if necessary add to hardwired defaults in do_getopt().

# not a method
sub save_option {
    my ($option, $value) = @_;
    $GETOPT->{$CLIENT_STANZA}->{$option} = $value;
    return;
}

# not a method
sub save_deep_option {
    my ( undef, $getopt ) = @_; # ignore the option name
    my ($option, $value) = split(/=/, $getopt, 2);
    $option = [ split(/\./, $option) ];
    my $param = pop @$option;
    return unless @$option;
    my $opt_str = join('.', @$option);
    $GETOPT->{$opt_str}->{$param} = $value;
    return;
}

################################################
#
## PUBLIC METHODS
#
################################################


=head1 do_getopt

 A wrapper function around GetOptions

    We get options from:
     - files provided by list_config_files()
     - command line
     - hardwired defaults (in this subroutine)
    overriding as we go.

Returns true on success, but on failure does:

  exec('perldoc', $0)

Suggested usage:

  Bio::Otter::Lace::Defaults::do_getopt(
    -dataset => \$dataset,
    );

=cut

my $DONE_GETOPT = 0;
sub do_getopt {
    my (@script_args) = @_;

    confess "do_getopt already called" if $DONE_GETOPT;
    $DONE_GETOPT = 1;

    ## If you have any 'local defaults' that you want to take precedence
    #  over the configuration files' settings, unshift them into @ARGV
    #  before running do_getopt()

    push(@$CONFIG_INIFILES, parse_available_config_files());
    ############################################################################
    ############################################################################
    my $start = "Called as:\n\t$CALLED\nGetOptions() Error parsing options:";
    GetOptions(
        'h|help!' => \&show_help,

        # map {} makes these lines dynamically from @CLIENT_OPTIONS
        # 'host=s'        => \&save_option,
        (map { $_ => \&save_option } @CLIENT_OPTIONS),

        # this allows setting of options as in the config file
        'cfgstr=s' => \&save_deep_option,

        # this is just a synonym feel free to add more
        'view' => sub { $GETOPT->{$CLIENT_STANZA}{'write_access'} = 0 },
        'local_fasta=s' => sub { $GETOPT->{'local_blast'}{'database'} = pop },
        'noblast' => sub {
            map { $_->{'local_blast'} = {} if exists $_->{'local_blast'} }
              @$CONFIG_INIFILES;
        },

        # this allows multiple extra config file to be used
        'cfgfile=s' => sub {
            push(@$CONFIG_INIFILES, options_from_file(pop));
        },

        # 'prebinpath=s' => sub { $ENV{PATH} = "$_[1]:$ENV{PATH}"; },

        # these are the caller script's options
        @script_args,
      )
      or show_help();
    ############################################################################
    ############################################################################

    push(@$CONFIG_INIFILES, $GETOPT);

    # now safe to call any subs which are required to setup stuff

    return 1;
}

sub save_server_otter_config {
    my ($config) = @_;
    
    my $server_otter_config = "/tmp/server_otter_config.$$";
    open my $SRV_CFG, '>', $server_otter_config
        or die "Can't write to '$server_otter_config'; $!";
    print $SRV_CFG $config;
    close $SRV_CFG or die "Error writing to '$server_otter_config'; $!";
    my $ini = options_from_file($server_otter_config);
    unlink($server_otter_config);
    
    # Server config file should be second in list, just after HARDWIRED
    splice(@$CONFIG_INIFILES, 1, 0, $ini);

    return;
}

sub show_help {
    exec('perldoc', $0);
}

sub make_Client {
    require Bio::Otter::Lace::Client;
    return Bio::Otter::Lace::Client->new;
}

sub parse_available_config_files {
    my @conf_files = ("/etc/otter_config");
    if ($ENV{'OTTER_HOME'}) {
        push(@conf_files, "$ENV{OTTER_HOME}/otter_config");
    }
    push(@conf_files, "$HOME_DIR/.otter_config");

    my @ini;
    foreach my $file (@conf_files) {
        next unless -e $file;
        if (my $file_opts = options_from_file($file)) {
            push(@ini, $file_opts);
        }
    }
    return @ini;
}

sub options_from_file {
    my ($file) = @_;
    
    return unless -e $file;

    my $ini;
    print STDERR "Trying $file\n" if $DEBUG_CONFIG;
    tie %$ini, 'Config::IniFiles', ( -file => $file, %OPTIONS_TO_TIE)
        or confess "Error opening '$file':\n",
        join("\n", @Config::IniFiles::errors); ## no critic(Variables::ProhibitPackageVars)
    return $ini;
}

sub config_value {
    my ( $section, $key ) = @_;

    my $value;
    foreach my $ini ( @$CONFIG_INIFILES ) {
        if (my $v = $ini->{$section}{$key}) {
            $value = $v;
        }
    }

    return $value;
}

sub config_value_list {
    my ( $key1, $key2, $name ) = @_;

    my @keys = ( "default.$key2", "$key1.$key2" );

    return [
        map {
            my $ini = $_;
            map  {
                my $key = $_;
                my $vs = $ini->{$key}{$name};
                ref $vs ? @{$vs} : defined $vs ? ( $vs ) : ( );
            } @keys;
        } @$CONFIG_INIFILES, ];
}

sub config_value_list_merged {
    my ( $key1, $key2, $name ) = @_;

    my @keys = ( "default.$key2", "$key1.$key2" );

    my $values;
    foreach my $ini ( @$CONFIG_INIFILES ) {
        foreach my $key ( @keys ) {
            my $vs = $ini->{$key}{$name};
            next unless $vs && @{$vs};
            if ( $values ) {
                _config_value_list_merge($values, $vs);
            }
            else {
                $values = $vs;
            }
        }
    }

    return $values;
}

sub _config_value_list_merge {
    my ( $values, $vs ) = @_;

    # hash the new values
    my $vsh = { };
    $vsh->{$_}++ foreach @{$vs};

    # find the position of the first new value in the current list
    my $pos = 0;
    foreach ( @{$values} ) {
        last if $vsh->{$_};
        $pos++;
    }

    # remove any existing copies of the new values
    @{$values} = grep { ! $vsh->{$_} } @{$values};

    # splice the new values into place
    splice @{$values}, $pos, 0, @{$vs};

    return;
}

sub config_section {
    my ( $key1, $key2 ) = @_;

    my @keys = ( "default.$key2", "$key1.$key2" );

    return {
        map {
            my $ini = $_;
            map {
                my $key = $_;
                my $section= $ini->{$key};
                defined $section ? %{$section} : ( );
            } @keys;
        } @$CONFIG_INIFILES,
    };
}

1;

=head1 NAME - Bio::Otter::Lace::Defaults

=head1 DESCRIPTION

Loads default values needed for creation of an
otter client from:

  command line
  anything that you have unshifted into @ARGV before running do_getopt
  ~/.otter_config
  $ENV{'OTTER_HOME'}/otter_config
  /etc/otter_config
  hardwired defaults (in this module)

in that order.  The values filled in, which can
be given by command line options of the same
name, are:

=over 4

=item B<host>

Defaults to B<localhost>

=item B<port>

Defaults to B<39312>

=item B<author>

Defaults to user name

=item B<email>

Defaults to user name

=item B<write_access>

Defaults to B<0>

=back


=head1 EXAMPLE

Here's an example config file:


  [client]
  port=33999

  [default.use_filters]
  trf=1
  est2genome_mouse=1

  [zebrafish.use_filters]
  est2genome_mouse=0

  [default.filter.est2genome_mouse]
  module=Bio::EnsEMBL::Ace::Filter::Similarity::DnaSimilarity
  max_coverage=12


You can also specify options on the command line 
using the B<cfgstr> option.  Thus:

    -cfgstr zebrafish.use_filters.est2genome_mouse=0

will switch off est2genome_mouse for the
zebrafish dataset exactly as the config file example
above does.

=head1 SYNOPSIS

  use Bio::Otter::Lace::Defaults;

  # Script can add Getopt::Long compatible options:
  my $foo = 'bar';

  # or override the defaults from .otter_config onwards
  # (but allow the user's command line options to take precedence) :
  unshift @ARGV, '--port=33977', '--host=ottertest';

  Bio::Otter::Lace::Defaults::do_getopt(
      'foo=s'   => \$foo,     
      );

  # Make a Bio::Otter::Lace::Client
  my $client = Bio::Otter::Lace::Defaults::make_Client();

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

=cut


__DATA__

# This is where the HARDWIRED ABSOLUTE DEFAULTS are stored

[client]
host=www.sanger.ac.uk
port=80
version=57
write_access=0
debug=1
show_zmap=1
logdir=.otter
fetch_truncated_genes=1
