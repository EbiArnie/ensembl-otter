=head1 LICENSE

Copyright [2018-2022] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package Test::Bio::Vega::Evidence;

use Test::Class::Most
    parent     => 'OtterTest::Class';

sub build_attributes {
    my $test = shift;
    return {
        name => 'A121415',
        type => 'ncRNA',
    };
}

sub matches_parsed_xml {
    my ($test, $parsed_xml, $description) = @_;
    my $evi = $test->our_object;
    $test->attributes_are($evi,
                          {
                              name => $parsed_xml->{name},
                              type => $parsed_xml->{type},
                          },
                          "$description (attributes)");
    return;
}

1;
