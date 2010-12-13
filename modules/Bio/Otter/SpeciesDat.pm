
package Bio::Otter::SpeciesDat;

# Read and maintain the hash from 'species.dat'.
# (Inherited by Bio::Otter::MFetcher)
#
# Author: lg4

use strict;
use warnings;


sub get_dataset_param {
    my ($self, $dataset_name, $param_name) = @_;

    my $all_species = $self->dataset_hash;
    my $subhash = $all_species->{$dataset_name} || $self->error_exit("Unknown Dataset '$dataset_name'");
    return $subhash->{$param_name};
}

sub dataset_hash { # used by scripts/apache/get_datasets only
    my ($self) = @_;

    unless ($self->{'_species_dat_hash'}) {
        $self->load_species_dat_file;
    }
    return $self->{'_species_dat_hash'};
}

sub species_dat_filename {
    my( $self, $filename ) = @_;

    if($filename) {
        $self->{'_species_dat_filename'} = $filename;
    }
    return $self->{'_species_dat_filename'};
}

sub load_species_dat_file {
    my ($self) = @_;

    my $filename = $self->species_dat_filename();

    open my $dat, '<', $filename or $self->error_exit("Can't read species file '$filename' : $!");

    my $cursect = undef;
    my $defhash = {};
    my $curhash = undef;
    my $sp = $self->{'_species_dat_hash'} = {};

    while (<$dat>) {
        next if /^\#/;
        next unless /\w+/;
        chomp;

        if (/\[(.*)\]/) {
            if (!defined($cursect) && $1 ne "defaults") {
                $self->error_exit("Error: first section in species.dat should be 'defaults'");
            }
            elsif ($1 eq "defaults") {
                $self->log("Got default section");
                $curhash = $defhash;
            }
            else {
                $curhash = {};
                foreach my $key (keys %$defhash) {
                    $key =~ tr/a-z/A-Z/;
                    $curhash->{$key} = $defhash->{$key};
                }
            }
            $cursect = $1;
            $sp->{$cursect} = $curhash;

        } elsif (/(\S+)\s+(\S+)/) {
            my $key   = uc $1;
            my $value =    $2;
            $self->log("Reading entry $key='$value'");
            $curhash->{$key} = $value;
        }
    }

    close $dat or $self->error_exit("Error reading '$filename' : $!");

    # Have finished with defaults, so we can remove them.
    delete $sp->{'defaults'};

    return;
}

sub keep_only_datasets {
    my ($self, $allowed_hash) = @_;

    my $sp = $self->dataset_hash;

    foreach my $dataset_name (keys %$sp) {
        $self->log(sprintf("Dataset %s is %sallowed", $dataset_name, $allowed_hash->{$dataset_name} ? '' : 'not '));
        delete $sp->{$dataset_name} unless $allowed_hash->{$dataset_name};
    }

    return;
}

sub remove_restricted_datasets {
    my ($self, $allowed_hash) = @_;
    
    my $sp = $self->dataset_hash;

    foreach my $dataset_name (keys %$sp) {
        next unless $sp->{$dataset_name}{'RESTRICTED'};
        $self->log(sprintf("Dataset %s is %srestricted", $dataset_name, $allowed_hash->{$dataset_name} ? 'not ' : ''));
        delete $sp->{$dataset_name} unless $allowed_hash->{$dataset_name};
    }

    return;
}

sub log { ## no critic(Subroutines::ProhibitBuiltinHomonyms)

    # to be overloaded

    my ($self, $message) = @_;

    print STDERR $message."\n";

    return;
}

sub error_exit { # to be overloaded
    my ($self, $message) = @_;

    $self->log($message);
    exit(1);
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

