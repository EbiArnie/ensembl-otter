
### Bio::Otter::Utils::MM

package Bio::Otter::Utils::MM;

use strict;
use warnings;

use DBI;

=pod

Notes on the MM schema

All cells in the entry.accession columns match
/'^[[:alnum:]]+(-[[:digit:]]+)?\.[[:digit:]]+$'/

=cut

# NB: databases will be searched in the order in which they appear in this list
my @DB_CATEGORIES = (
    'emblnew',
    'emblrelease',
    'uniprot',
    'uniprot_archive',

    #'refseq'
);

sub new {
    my ($class, @args) = @_;

    my $self = bless {}, $class;

    my ($host, $port, $user, $name) = @args;

    $self->host($host || 'cbi3');
    $self->port($port || 3306);
    $self->user($user || 'genero');
    $self->name($name || 'mm_ini');

    return $self;
}

sub _get_connection {
    my ($self, $category) = @_;

    my $dbh;
    
    # get a connection to mm_ini to look up the correct tables/databases
    my $dsn_mm_ini = "DBI:mysql:".
        "database=".$self->name.
        ";host=".$self->host.
        ";port=".$self->port;
        
    my $dbh_mm_ini = DBI->connect($dsn_mm_ini, $self->user, '', { 'RaiseError' => 1 });

    if ($category eq 'uniprot_archive') {
        
        # find the correct host and db to connect to from the connections table
        
        my $arch_sth = $dbh_mm_ini->prepare(qq{
            SELECT db_name, port, username, host
            FROM connections
            WHERE is_active = 'yes'
            LIMIT 1
        });
        
        $arch_sth->execute or die "Couldn't execute statement: " . $arch_sth->errstr;
        
        my $db_details = $arch_sth->fetchrow_hashref or die "Failed to find active uniprot_archive";
        
        my $dsn = "DBI:mysql:".
            "database=".$db_details->{'db_name'}.
            ";host=".$db_details->{'host'}.
            ";port=".$db_details->{'port'};
            
        $dbh = DBI->connect($dsn, $db_details->{'username'}, '', { 'RaiseError' => 1 });
    }
    else {
        
        # look for the current and available table for this category from the ini table
      
        my $ini_sth = $dbh_mm_ini->prepare(qq{
            SELECT database_name 
            FROM ini
            WHERE database_category = ?
            AND current = 'yes'
            AND available = 'yes'
        });
        
        $ini_sth->execute($category) or die "Couldn't execute statement: " . $ini_sth->errstr;
        
        my $db_details = $ini_sth->fetchrow_hashref or die "Failed to find available db for $category";
        
        my $dsn = "DBI:mysql:".
            "database=".$db_details->{'database_name'}.
            ";host=".$self->host.
            ";port=".$self->port;
        
        $dbh = DBI->connect($dsn, $self->user, '', { 'RaiseError' => 1 });
    }
    
    return $dbh;
}

sub dbh {
    my ($self, $category, $dbh) = @_;

    die "DB category required" unless $category;

    die "Invalid DB category: $category"
      unless grep { /^$category$/ } @DB_CATEGORIES;

    if ($dbh) {
        die "Not a valid DB handle: " . (ref $dbh) unless ref $dbh && $dbh->isa('DBI::db');
        $self->{_dbhs}->{$category} = $dbh;
    }

    unless ($self->{_dbhs}->{$category}) {
        $self->{_dbhs}->{$category} = $self->_get_connection($category);
    }

    return $self->{_dbhs}->{$category};
}

{
    my $common_sql = q{
SELECT e.molecule_type
  , e.data_class
  , e.accession_version
  , e.sequence_length
  , GROUP_CONCAT(t.ncbi_tax_id) as taxon_list
  , d.description
FROM entry e
  , description d
  , taxonomy t
WHERE e.entry_id = d.entry_id
  AND e.entry_id = t.entry_id
  AND e.accession_version };
    
    # May be dangerous to assume that the most recent entries in uniprot_archive
    # will have the biggest entry_id
    my $group_order_sql = q{ GROUP BY e.entry_id ORDER BY e.entry_id ASC };
    
    my $with_sv_sql = "$common_sql    = ?\n$group_order_sql";
    my $like_sv_sql = "$common_sql LIKE ?\n$group_order_sql";

    sub get_accession_types {
        my ($self, $accs) = @_;

        my %acc_hash = map { $_ => 1 } @$accs;
        my $results = {};

        for my $db_name (@DB_CATEGORIES) {
            my $dbh = $self->dbh($db_name);
            my $with_sv_sth = $dbh->prepare($with_sv_sql);
            my $like_sv_sth = $dbh->prepare($like_sv_sql);

            foreach my $name (keys %acc_hash) {

                my $sth;
                if ($name =~ /\.\d+$/) {
                    $with_sv_sth->execute($name);
                    $sth = $with_sv_sth;
                }
                else {
                    $like_sv_sth->execute("$name.%");
                    $sth = $like_sv_sth;
                }

                while (my ($type, $class, $acc_sv, @extra_info) = $sth->fetchrow) {
                    if ($class eq 'EST') {
                        $results->{$name} = [ 'EST', $acc_sv, 'EMBL', @extra_info ];
                    }
                    elsif ($type eq 'mRNA') {
                        # Here we return cDNA, which is more technically correct since
                        # both ESTs and cDNAs are mRNAs.
                        $results->{$name} = [ 'cDNA', $acc_sv, 'EMBL', @extra_info ];
                    }
                    elsif ($type eq 'protein') {

                        my $source_db;

                        if ($class eq 'STD') {
                            $source_db = "Swissprot"
                        }
                        elsif ($class eq 'PRE') {
                            $source_db = 'TrEMBL';
                        }
                        elsif ($class eq 'ISO') {    # we don't think TrEMBL can have isoforms
                            $source_db = 'Swissprot';
                        }
                        else {
                            die "Unexpected data class for uniprot entry: $class";
                        }

                        $results->{$name} = [ 'Protein', $acc_sv, $source_db, @extra_info ];
                    }
                    elsif ($type eq 'other RNA' or $type eq 'transcribed RNA') {
                        $results->{$name} = [ 'ncRNA', $acc_sv, 'EMBL', @extra_info ];
                    }

                    delete $acc_hash{$name};
                }
            }

            # We don't need to search any further databases if 
            last unless keys %acc_hash;
        }

        return $results;
    }
    

}


my $feature_details_sql = {
    description => q{
    SELECT d.description
    FROM entry e, description d
    WHERE e.entry_id = d.entry_id
    AND e.accession_version = ?
},
    taxon_id => q{
    SELECT t.ncbi_tax_id
    FROM entry e, taxonomy t
    WHERE e.entry_id = t.entry_id
    AND e.accession_version = ?
},
};

sub get_feature_details {
    my ($self, $feature_name) = @_;

    return unless my ( $accession_version ) =
        $feature_name =~ /\A(?:[[:alpha:]]{2}:)?(.*)\z/;

    my $details = { };

    while ( my ($key, $sql) = each %{$feature_details_sql} ) {
        for my $db (@DB_CATEGORIES) {
            my $sth = $self->dbh($db)->prepare($sql);
            $sth->execute($accession_version);
            next unless my ($value) = $sth->fetchrow_array();
            $details->{$key} = $value;
            last;
        }
    }

    return $details;
}

sub name {
    my ($self, $name) = @_;
    $self->{_name} = $name if $name;
    return $self->{_name};
}

sub host {
    my ($self, $host) = @_;
    $self->{_host} = $host if $host;
    return $self->{_host};
}

sub port {
    my ($self, $port) = @_;
    $self->{_port} = $port if $port;
    return $self->{_port};
}

sub user {
    my ($self, $user) = @_;
    $self->{_user} = $user if $user;
    return $self->{_user};
}

1;

__END__

=head1 NAME - Bio::Otter::Utils::MM

=head1 AUTHOR

Graham Ritchie B<email> gr5@sanger.ac.uk

