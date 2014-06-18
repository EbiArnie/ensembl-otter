
=head1 NAME - Bio::Otter::Lace::Pfam

=head1 DESCRIPTION

    This module offer functionalities to use the Pfam website to run sequence searches through the RESTful services

=cut

package Bio::Otter::Lace::Pfam;
use strict;
use warnings;
use Try::Tiny;
use Log::Log4perl;
use LWP;
use LWP::UserAgent;
use HTTP::Request;
use XML::LibXML;
use XML::LibXML::XPathContext;

my $SEARCH_URL = 'http://pfam.xfam.org/search/sequence';
my $HMM_URL    = 'http://pfam.xfam.org/family/hmm';
my $SEED_URL   = 'http://pfam.xfam.org/family/alignment/download/format';

# full path for hmmalign
my $HMMALIGN = 'hmmalign'; # see also Bio::Otter::Utils::About

sub new {
    my ($self) = @_;
    $self->logger->debug('new');
    return bless {}, $self;
}

sub _ua_request {
    my ($self, $description, $req) = @_;
    my $L = $self->logger;
    $L->info($description, " to ", $req->uri);
    my $ua = $self->_user_agent;
    my $res = $ua->request($req);
    $L->info("Response: ", $res->status_line, "; ", $res->content_length, " bytes");
    unless ($res->is_success) {
        $L->debug(join "\n> ", "Request was",
                  $res->request->as_string) if $L->is_debug;
        $L->debug(join "\n< ", "Response was",
                  $res->status_line,
                  $res->headers_as_string,
                  $res->decoded_content) if $L->is_debug;
        die "$description failed ".$res->status_line;
    }
    return $res;
}

sub logger {
    return Log::Log4perl->get_logger('otter.pfam');
}

sub _user_agent { # create and cache a user agent
    my ($self) = @_;
    return $self->{'_user_agent'} ||= do {
        my $ua = LWP::UserAgent->new;
        $ua->env_proxy;
        $ua;
    };
}


# submits the sequence search and returns the XML that comes back from the
# server
sub submit_search {
    my ($self, $seq) = @_;

    # build the query parameters. Use URI to format them nicely for LWP...
    my $uri = URI->new;
    my %param = (
            seqOpts => 'both',    # search both models and merge results
            ga      => 0,         # use the gathering threshold
            seq     => $seq,      # sequence to search
            output  => 'xml'
    );
    $uri->query_form( %param );

    # set up the request
    my $req = HTTP::Request->new( POST => $SEARCH_URL );
    $req->content_type('application/x-www-form-urlencoded');
    $req->content( $uri->query );

    my $res = $self->_ua_request(submission => $req);
    return $res->decoded_content;
}


# parses the submission XML and returns the URL for retrieving results and the
# estimated job runtime
sub check_submission {
    my ($self, $xml) = @_;

    # parse the XML that came back from the server when we submitted the search
    my $parser = XML::LibXML->new();
    my $dom;
    try { $dom = $parser->parse_string($xml); }
    catch { $self->logger->warn("couldn't parse XML response for submission: $_") };
    return unless $dom;

    # the root element is "jobs"
    my $root = $dom->documentElement();

    # set up to use XPaths
    my $xc = XML::LibXML::XPathContext->new($root);
    $xc->registerNs( 'p', 'http://pfam.xfam.org/' );

    # we're only running a single Pfam-A search, so there will be only one "job"
    # tag, so we know that these XPaths will each give us only a single node
    my $result_url     = $xc->findvalue('/p:jobs/p:job/p:result_url');
    my $estimated_time = $xc->findvalue('/p:jobs/p:job/p:estimated_time');
    $result_url     =~ s/\s//g;
    $estimated_time =~ s/\s//g;
    return ( $result_url, $estimated_time );
}

# polls the result URL as often as necessary (up to a hard limit) and returns
# the results XML
sub poll_results {
    my ($self, $result_url) = @_;

    # this is the request that we'll submit repeatedly
    my $req = HTTP::Request->new( GET => $result_url );

    my $res = $self->_ua_request(poll => $req);
    return $res->decoded_content;
}

# parses the results XML and return a hash containing the hits and locations
sub parse_results {
    my ($self, $results_xml) = @_;
    $self->logger->info("parsing XML search results");

    my $parser = XML::LibXML->new();
    my $dom;
    try { $dom = $parser->parse_string($results_xml); }
    catch { $self->logger->warn("couldn't parse XML response for results: $_") };
    return unless $dom;

    # set up the XPath stuff for this document
    my $root = $dom->documentElement();
    my $xc   = XML::LibXML::XPathContext->new($root);
    $xc->registerNs( 'p', 'http://pfam.xfam.org/' );

    # get all of the matches, that is the list of Pfam-A families that are found
    # on the sequence
    my @matches =
      $xc->findnodes(
'/p:pfam/p:results/p:matches/p:protein/p:database/p:match[@type="Pfam-A"]' );
    print 'found ' . scalar @matches . " hit(s)\n";
    my $results = {};
    foreach my $match_node (@matches) {
        print STDOUT (
            'looking for locations for Pfam-A '
            . $match_node->getAttribute('class') . ' '
            . $match_node->getAttribute('id') . ' ('
            . $match_node->getAttribute('accession')
            . ')' );
        my @locations =
          $xc->findnodes( 'p:location[@significant=1]', $match_node );
        print '  found '
          . scalar @locations
          . ' location(s) for '
          . $match_node->getAttribute('accession') . "\n";

        next unless @locations;

        foreach my $location_node (@locations) {
            my $location = {
                start => $location_node->getAttribute('start'),
                end   => $location_node->getAttribute('end')
            };
            push @{ $results->{ $match_node->getAttribute('accession') }->{locations} }, $location;
        }

        $results->{ $match_node->getAttribute('accession') }->{id} = $match_node->getAttribute('id');
        $results->{ $match_node->getAttribute('accession') }->{class} = $match_node->getAttribute('class');
    }
    print "done parsing search results\n";
    return $results;
}

#-------------------------------------------------------------------------------
# retrieves the HMM and seed alignment for each hit and drops them into the
# results hash

sub retrieve_pfam_hmm {
  my ($self, $domains) = @_;

  my %data;
  foreach my $domain (@$domains) {

    #----------------------------------------
    # get the HMM

    print STDOUT "$domain: retrieve HMM model\n";

    # set up the request
    my $req = HTTP::Request->new( POST => $HMM_URL );
    $req->content_type( 'application/x-www-form-urlencoded' );

    # add the query parameters onto the URL
    my $uri = URI->new;
    $uri->query_form( mode => 'ls',
                      entry => $domain );
    $req->content( $uri->query );

    try {
        my $res = $self->_ua_request("Domain $domain hmm", $req);
        $data{$domain} = $res->decoded_content;
    } catch {
        $self->logger->warn("$domain: HMM model retrieval failed: $_");
# Need UI feedback
    };
  } # end of "foreach domain"

  return \%data;

}

sub retrieve_pfam_seed {
  my ($self, $domains) = @_;

  my %data;
  foreach my $domain (@$domains) {

    #----------------------------------------
    # get the HMM

    print STDOUT "$domain: retrieve seed alignments\n";

    # set up the request
    my $req = HTTP::Request->new( POST => $SEED_URL );
    $req->content_type( 'application/x-www-form-urlencoded' );

    # add the query parameters onto the URL
    my $uri = URI->new;
    $uri->query_form( alnType  => 'seed',
                      download => 1,
                      entry    => $domain );
    $req->content( $uri->query );

    try {
        my $res = $self->_ua_request("Domain $domain seed", $req);

        $data{$domain} = $res->content;
        # (need to strip out secondary structure and consensus lines,
        # otherwise hmmalign seg faults...)
        $data{$domain} =~ s/^\#=G[CR].*?\n//mg;

    } catch {
        $self->logger->warn("$domain: seed alignment retrieval failed: $_");
# Need UI feedback
    };
  } # end of "foreach domain"

  return \%data;
}

sub get_seq_snippets {
    my ($self, $seq_name, $seq_string, $hit_locations) = @_;

    my $s;

    foreach my $location ( @$hit_locations ) {

            my $subseq = substr( $seq_string,
                           $location->{start} - 1,
                           $location->{end} - $location->{start} + 1 );

            $s .= ">${seq_name}_$location->{start}-$location->{end}\n$subseq\n";
    }

    return $s;
}


#-------------------------------------------------------------------------------
# builds a sequence file containing the sequence snippets that match Pfam
# hits and aligns them to the seed alignment using hmmalign. Writes the
# the resulting alignments to the working directory

sub align_to_seed {
  my ($self, $seq, $domain, $hmm, $seed) = @_;

  # the sequence that we'll be aligning
  my $seq_file = $self->create_filename($domain,"seq");
  open(my $seq_fh, '>', $seq_file)
            || die "Error creating '$seq_file' : $!";

  print $seq_fh $seq; close $seq_fh;


    # the seed alignment
    my $seed_file = $self->create_filename($domain,"seed");
    open(my $seed_fh, '>', $seed_file)
            || die "Error creating '$seed_file' : $!";

    print $seed_fh $seed; close $seed_fh;

    # the HMM
    my $hmm_file = $self->create_filename($domain,"ls");
    open(my $hmm_fh, '>', $hmm_file)
            || die "Error creating '$hmm_file' : $!";

    print $hmm_fh $hmm; close $hmm_fh;

    # the hmmalign output
    my $output_filename = $self->create_filename($domain,"aln");


    # build the hmmalign command
    my $cmd = $HMMALIGN . ' --mapali ' . $seed_file .
                          ' -q '        . $hmm_file .
                          ' '           . $seq_file .
                          ' > '         . $output_filename;

    print STDOUT "$domain: aligning\n";

    system( $cmd ) == 0
      or warn "$domain: couldn't run hmmalign '$cmd' [$!]\n";

    # delete tmp files
    unlink $seed_file ,  $hmm_file , $seq_file;
    $self->output_files($output_filename);

    return $output_filename;

}

sub create_filename{
  my ($self, $stem, $ext, $dir) = @_;
  if(!$dir){
    $dir = '/var/tmp';
  }
  $stem = '' if(!$stem);
  $ext = '' if(!$ext);
  die $dir." doesn't exist Runnable:create_filename" unless(-d $dir);
  my $num = int(rand(100000));
  my $file = $dir."/".$stem.".".$$.".".$num.".".$ext;
  while(-e $file){
    $num = int(rand(100000));
    $file = $dir."/".$stem.".".$$.".".$num.".".$ext;
  }
  return $file;
}

sub output_files {
    my ($self, $file) = @_;
    if ($file) {
        push @{$self->{_result_files}} , $file;
    }
    return $self->{_result_files};
}

sub DESTROY {
    my ($self) = @_;
    return unless $self->output_files;
    foreach (@{$self->output_files}) {
        unlink $_;
    }
        return;
}


1;
__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

