
package Bio::Otter::Git;

use strict;
use warnings;

#  NB: This module must not have any non-standard dependencies,
#  because the installer uses this module and it runs with a very
#  minimal $PATH, $PERL5LIB etc. (due in part to ssh-ing to
#  development hosts) so it will only find modules in default
#  locations.  If you add any dependencies here then you *must* check
#  that the installer still works.

use Try::Tiny;
use File::Basename;

my $dir = dirname __FILE__;

my $commands = {
    head => q(git describe --tags --match 'humpub-release-*' HEAD),
};

our $CACHE = {
};

sub _getcache {
    #  Attempt to load a cache.
    return try {
        require Bio::Otter::Git::Cache;
        my $loaded = $INC{'Bio/Otter/Git/Cache.pm'};
        if (dirname(dirname($loaded)) ne $dir) {
            die "$dir loaded cache $loaded from wrong tree - suspected module shadowing";
        }
        1;
    } catch {
        if (m(\A\QCan't locate Bio/Otter/Git/Cache.pm in \E)) {
            warn "No git cache: assuming a git checkout.\n";
            0;
        }
        else {
            die "cache error: $_";
        }
    };
}

sub _try_git {
    return try {
        my $command = q(git tag);
        my $ok = system(qq(cd '$dir' && $command > /dev/null)) == 0;
        warn "'$command' failed: something is wrong with your git checkout"
          unless $ok;
        $ok;
    } catch {
        if (m(Insecure .* while running with -T switch)) {
            warn "Dev checkout under Apache? Cannot run git: $_";
            0;
        } else {
            die "unexpected error with Git: $_";
        }
    };
}

_getcache() || _try_git();
# Or we dev checkout and can't run Git.  ->param will return undef.

sub dump {
    my ($pkg) = @_;
    warn sprintf "git HEAD: %s\n", $pkg->param('head');
    return;
}

# Show something more user friendly for released versions
sub as_text {
    my ($called) = @_;
    my $head = $called->param('head');
    return "v$1.$2" if $head =~ m{^humpub-release-(\d+)-(\d+)$};
    return $head;
}


my $cache_template = <<'CACHE_TEMPLATE'

package Bio::Otter::Git::Cache;

use strict;
use warnings;

$Bio::Otter::Git::CACHE = {
%s};

1;

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut
CACHE_TEMPLATE
    ;

sub _create_cache { ## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
    my ($pkg, $module_dir) = @_;

    my $cache_contents = join '', map {
        sprintf "    %s => q(%s),\n", $_, $pkg->param($_);
    } keys %{$commands};

    require File::Path;
    my $git_dir = "${module_dir}/Bio/Otter/Git";
    File::Path::make_path($git_dir);

    my $cache_path = "${git_dir}/Cache.pm";
    open my $cache_h, '>', $cache_path
        or die "failed to open the git cache '${cache_path}': $!";
    printf $cache_h $cache_template, $cache_contents;
    close $cache_h
        or die "failed to close the git cache '${cache_path}': $!";

    return;
}

# may error or return undef when data is not available
sub param {
    my ($pkg, $key) = @_;
    $CACHE->{$key} = $pkg->_param($key)
        unless exists $CACHE->{$key};
    return $CACHE->{$key};
}

sub _param {
    my ($pkg, $key) = @_;
    my $command = $commands->{$key};
    die qq(invalid git parameter key "${key}") unless $command;
    my $shell_command = sprintf q( cd '%s' && %s ), $dir, $command;
    my $value = qx( $shell_command ); ## no critic (InputOutput::ProhibitBacktickOperators)
    chomp $value;
    unless ($? == 0) {
        warn qq("$shell_command" failed);
        return;
    }
    return $value;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

