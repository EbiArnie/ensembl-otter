
package Bio::Otter::Server::Support::Web;

use strict;
use warnings;

use feature 'switch';

use Try::Tiny;

use Bio::Vega::Author;
use Bio::Otter::Server::Config;
use Bio::Otter::Auth::SSO;

use IO::Compress::Gzip qw(gzip);

use CGI;
use JSON;
use SangerWeb;

use base ('Bio::Otter::MappingFetcher');


BEGIN {
    $SIG{__WARN__} = sub { ## no critic (Variables::RequireLocalizedPunctuationVars)
        my ($line) = @_;
        warn "pid $$: $line";
        # pid is sufficient to re-thread lines on one host,
        # and the script name is given once by a BEGIN block
        return;
    };
}

# Under webvm.git, Otter::LoadReport gives more info and is probably
# loaded by the CGI script stub.
BEGIN {
    warn "otter_srv script start: $0\n" unless Otter::LoadReport->can('show');
}
END {
    warn "otter_srv script end: $0\n" unless Otter::LoadReport->can('show');
}

our $ERROR_WRAPPING_ENABLED;
$ERROR_WRAPPING_ENABLED = 1 unless defined $ERROR_WRAPPING_ENABLED;

our $COMPRESSION_ENABLED;
$COMPRESSION_ENABLED = 1 unless defined $COMPRESSION_ENABLED;

sub new {
    my ($pkg, @args) = @_;

    my %options = (
        -compression  => 0,
        -content_type => 'text/plain',
        @args,
    );

    my $self = $pkg->SUPER::new();
    $self->cgi;                 # will create a new one or adopt the singleton
    $self->compression($options{-compression});
    $self->content_type($options{-content_type});

    $self->authenticate_user;
    if ($self->show_restricted_datasets || ! $self->local_user) {
        $self->authorized_user;
    }

    return $self;
}

{
    # Allows a package-wide CGI object to be set up before an object is instantiated,
    # which in turn allows CGI methods such as path_info() to be used to control object subtype.
    #
    my $cgi_singleton;

    sub cgi {
        my ($self, @args) = @_;

        unless (ref $self) {
            # We've been called as a class method
            return $cgi_singleton ||= CGI->new;
        }

        # Traditional accessor
        ($self->{'cgi'}) = @args if @args;
        my $cgi = $self->{'cgi'};
        return $cgi if $cgi;

        if ($cgi_singleton) {
            # Adopt the singleton, then unset it to avoid any mod_perl issues down the line...
            $cgi = $self->{'cgi'} = $cgi_singleton;
            $cgi_singleton = undef;
            return $cgi;
        }

        # Backstop is to create a new one
        return $self->{'cgi'} = CGI->new;
    }
}

sub compression {
    my ($self, @args) = @_;
    ($self->{'compression'}) = @args if @args;
    my $compression = $self->{'compression'};
    return $compression;
}

sub content_type {
    my ($self, @args) = @_;
    ($self->{'content_type'}) = @args if @args;
    my $content_type = $self->{'content_type'};
    return $content_type;
}

sub header {
    my ($self, @args) = @_;
    return $self->cgi->header(@args);
}

sub param {
    my ($self, @args) = @_;
    return $self->cgi->param(@args);
}

sub path_info {
    my ($self) = @_;
    return $self->cgi->path_info();
}

sub require_method {
    my ($self, $want) = @_;
    my $got = $self->cgi->request_method;
    die "Request should be made with $want method, but was made with $got method"
      unless lc($got) eq lc($want);
    return;
}

sub make_map {
    my ($self) = @_;
    return {
        map {
            $_ => $self->make_map_value($_);
        } qw( cs name chr start end csver csver_remote ),
    };
}

my $map_keys_required = { };
$map_keys_required->{$_}++ for qw(
type start end
);

sub make_map_value {
    my ($self, $key) = @_;
    my $getter =
        $map_keys_required->{$key} ? 'require_argument' : 'param';
    warn sprintf "getter = '%s', key = '%s'\n", $getter, $key;
    my $val = $self->$getter($key);
    return defined($val) ? $val : '';
}


############## getters: ###########################

sub dataset_name {
    my ($self) = @_;
    my $dataset_name = $self->require_argument('dataset');
    return $dataset_name;
}

sub allowed_datasets {
    my ($self) = @_;
    my $filter = $self->dataset_filter;
    return [ grep { $filter->($_) } @{$self->SpeciesDat->datasets} ];
}

sub dataset_filter {
    my ($self) = @_;

    my $user = lc $self->sangerweb->username;
    my $user_is_external = ! ( $self->local_user || $self->internal_user );
    my $user_datasets = $self->users_hash->{$user};

    return sub {
        my ($dataset) = @_;
        my $is_listed = $user_datasets && $user_datasets->{$dataset->name};
        my $list_rejected = $user_is_external && ! $is_listed;
        my $is_restricted = $dataset->params->{RESTRICTED};
        my $restrict_rejected = $is_restricted && ( $user_is_external || ! $is_listed );
        return ! ( $list_rejected || $restrict_rejected );
    };
}

sub users_hash {
    my ($self) = @_;
    return $self->{'_users_hash'} ||= Bio::Otter::Server::Config->users_hash;
}


=head2 sangerweb

Instance method.  Cache and return an instance of L<SangerWeb>
configured with our CGI instance.

=cut

sub sangerweb {
    my ($self) = @_;

    return $self->{'_sangerweb'} ||=
        SangerWeb->new({ cgi => $self->cgi });
}


sub authenticate_user {
    my ($self) = @_;

    my $sw = $self->sangerweb;
    my $users = $self->users_hash;
    my %set = Bio::Otter::Auth::SSO->auth_user($sw, $users);

    # Merge properties (_authorized_user, _internal_user, _local_user) into %$self
    @{ $self }{ keys %set } = values %set;

    return;
}

sub authorized_user {
    my ($self) = @_;

    my $user = $self->{'_authorized_user'};
    $self->unauth_exit('User not authorized') unless $user;

    return $user;
}

sub internal_user {
    my ($self) = @_;

    # authenticate_user sets '_internal_user', and is called
    # by new(), so this hash key will be populated.
    return $self->{'_internal_user'};
}


=head2 local_user

Is the caller on the WTSI internal network?

=cut

sub local_user {
    my ($self) = @_;

    # authenticate_user sets '_local_user', and is called
    # by new(), so this hash key will be populated.
    return $self->{'_local_user'};
}

sub show_restricted_datasets {
    my ($self) = @_;

    if (my $client = $self->param('client')) {
        return $client =~ /otterlace/;
    } else {
        return;
    }
}

############## I/O: ################################

sub send_response {
    my ($called, @args) = @_;

    my $sub = pop @args;
    my $self = $called->new(@args);

    my ($response, $ok, $error);
    try {
        $response = $sub->($self);
        $ok = 1;
    }
    catch {
        $error = $_;
    };

    # content_type may be set by $sub, so we don't choose encoding until here:
    my ($encode_response, $encode_error);
    for ($self->content_type) {
        when ($_ eq 'application/json') {
            $encode_response = \&_encode_json;
            $encode_error    = \&_encode_error_json;
        }
        default {
            $encode_error = \&_encode_error_xml;
            die "After the action, JSON used but content_type=$_"
              if $self->json(1); # code didn't fix its content_type - 500 error
        }
    }

    if ($ok) {
        try {
            $ok = undef;
            $response = $self->$encode_response($response) if $encode_response;
            $self->_send_response($response, 200);
            $ok = 1;
        }
        catch {
            $error = $_;
        };
    }
    return if $ok;

    die $error unless $ERROR_WRAPPING_ENABLED;
    chomp($error);
    warn "ERROR: $error\n";
    $self->compression(0);
    $self->_send_response($self->$encode_error($error), 417);

    return;
}

sub _encode_error_xml {
    my ($self, $error) = @_;
    return $self->otter_wrap_response(" <response>\n    ERROR: $error\n </response>\n");
}

sub _encode_json {
    my ($self, $obj) = @_;
    return $self->json->encode($obj);
}

sub _encode_error_json {
    my ($self, $error) = @_;
    return $self->_encode_json({ error => $error });
}

sub json {
    my ($self, $no_init) = @_;
    $self->{_json} ||= JSON->new->pretty unless $no_init;
    return $self->{_json};
}

sub _send_response {
    my ($self, $response, $status) = @_;
    my $len = length($response);
    my $content_type = $self->content_type;

    if ($COMPRESSION_ENABLED && $self->compression) {
        my $gzipped;
        gzip \$response => \$gzipped;
        print
            $self->header(
                -status           => $status,
                -type             => $content_type,
                -content_length   => length($gzipped),
                -x_plain_length   => $len, # to assist debug on client
                -content_encoding => 'gzip',
            ),
            $gzipped,
            ;
    }
    else {
        print
            $self->header(
                -status => $status,
                -content_length => $len,
                -type   => $content_type,
            ),
            $response,
            ;
    }

    return;
}

sub otter_wrap_response {
    my ($self, $response) = @_;

    return <<"XML"
<?xml version="1.0" encoding="UTF-8"?>
<otter>
$response</otter>
XML
;
}

sub unauth_exit {
    my ($self, $reason) = @_;

    print $self->header(
        -status => 403,
        -type   => 'text/plain',
        ), $reason;
    exit(1);
}


## no critic (Modules::ProhibitMultiplePackages)

package Bio::EnsEMBL::DBSQL::StatementHandle;

use strict;
use warnings;

# Work around DBI/DBD::mysql bug on webservers
sub bind_param {
    my ($self, $pos, $value, $attr) = @_;

    # Make $attr a hash ref if it is not
    if (defined $attr) {
        unless (ref $attr) {
            $attr = {TYPE => $attr};
        }
        return $self->SUPER::bind_param($pos, $value, $attr);
    } else {
        return $self->SUPER::bind_param($pos, $value);
    }
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

