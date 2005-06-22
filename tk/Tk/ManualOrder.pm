package Tk::ManualOrder;

# A mega-widget that inherits from Tk::Frame.
#
# Accepts a list of toString()'able objects,
# displays them in a vertical list
# and allows the user to re-order the objects or remove some of them.
#
# The interface for getting/setting the list is done via configure/cget mechanism.
#
# lg4

use Tk;

use base ('Evi::DestroyReporter', 'Tk::LabFrame');

Construct Tk::Widget 'ManualOrder';

sub Populate {
	my ($self,$args) = @_;

    my $activelist = delete $args->{-activelist}; # save the parent from seeing this

	$self->SUPER::Populate($args);

	$self->ConfigSpecs(
        -activelist => ['METHOD', 'activelist', 'Activelist', $activelist ? $activelist : [] ],
	);
}

sub activelist { # the METHOD's name should match the option name minus dash
	my ($self, $newactive_lp) = @_;

	if(defined($newactive_lp)) {
		if($self->{_activelist}) {
			$self->_get_rid_of(); # of all widgets, basically
		}
		$self->{_activelist} = $newactive_lp;
		for my $idx (0..@$newactive_lp-1) {
			$self->_grid_object_at($newactive_lp->[$idx],$idx);
		}
	}
	return $self->{_activelist};
}

sub append_object {
	my ($self, $object) = @_;

	my $activelist = $self->{_activelist};

	$self->_grid_object_at($object, scalar(@$activelist));
	push @$activelist, $object;
}

# --------------------the rest is the implementation------------------

sub _get_rid_of {
	my ($self, @rest) = @_;

    print "[_get_rid_of @rest]:\n";

    print "gridSlaves($self):\n";
    for my $wid ($self->gridSlaves()) {
        print "\t".$wid->cget(-text)."\n";
    }
    print "-----------\n\n";

	for my $wid ($self->gridSlaves(@rest)) {
        print "!!! gridForgetting: $wid\n";
		$wid->gridForget();
	}
}

sub _grid_object_at {
	my ($self, $object, $idx) = @_;

    print "[_grid_object_at($idx)]\n";

	if($idx) {
		$self->Button(
			-text => 'Swap',
			-command => [ \&_swap_idx1_idx2, $self, $idx, $idx-1 ],
		)->grid(
            -row => 2*$idx-1,
            -rowspan => 2,
            -column => 0,
            -sticky => 'news',
        );
	}

	$self->Label(
		-text => $object->toString(),
	)->grid(
        -row => 2*$idx,
        -rowspan => 2,
        -column => 1,
        -sticky => 'news',
    );

	$self->Button(
		-text => 'Remove',
		-command => [ \&_remove_by_idx, $self, $idx ],
	)->grid(
        -row => 2*$idx,
        -rowspan => 2,
        -column => 2,
        -sticky => 'news',
    );

    print "gridSlaves($self):\n";
    for my $wid ($self->gridSlaves()) {
        print "\t".$wid->cget(-text)."\n";
    }
    print "-----------\n\n";

}

sub _swap_idx1_idx2 { # just re-create them from scratch
	my ($self, $idx1, $idx2) = @_;

    print "[_swap_idx1_idx2: $idx1, $idx2]\n";

	my $activelist = $self->{_activelist};

	$self->_get_rid_of(-row => 2*$idx1);
	$self->_get_rid_of(-row => 2*$idx2);

	my $temp = $self->{_activelist}[$idx1];
	$activelist->[$idx1] = $activelist->[$idx2];
	$activelist->[$idx2] = $temp;

	$self->_grid_object_at($activelist->[$idx1],$idx1);
	$self->_grid_object_at($activelist->[$idx2],$idx2);
}

sub _remove_by_idx {
	my ($self, $idx) = @_;

    print "[_remove_by_idx: $idx]\n";

	my $activelist = $self->{_activelist};

	for my $idx2 ($idx+1..@$activelist-1) {
		$self->_swap_idx1_idx2($idx2-1,$idx2);
	}
	
	pop @$activelist;
	$self->_get_rid_of(-row => 2*scalar(@$activelist));
}

1;

