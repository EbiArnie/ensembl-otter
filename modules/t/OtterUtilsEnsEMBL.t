#!/usr/bin/env perl

use strict;
use warnings;

use lib "${ENV{ANACODE_TEAM_TOOLS}}/t/tlib";
use Test::CriticModule;

use Test::More;

use Bio::Otter::Server::Config;

my $module;
BEGIN {
    $module = 'Bio::Otter::Utils::EnsEMBL';
    use_ok($module);
}
critic_module_ok($module);

my $dataset = Bio::Otter::Server::Config->SpeciesDat->dataset('human');

my $ens = new_ok($module => [ $dataset ]);

my $ens_id = $ens->stable_id_from_otter_id('OTTHUMT00000010323');
is($ens_id, 'ENST00000373833', 'EnsEMBL transcript id from Otter transcript id');

$ens_id = $ens->stable_id_from_otter_id('OTTHUMG00000012711');
is($ens_id, 'ENSG00000254875', 'EnsEMBL gene id from Otter gene id');

$ens_id = $ens->stable_id_from_otter_id('OTTHUMP00000018803');
is($ens_id, 'ENSP00000369497', 'EnsEMBL translation id from Otter translation id');

done_testing;

1;

# Local Variables:
# mode: perl
# End:

# EOF
