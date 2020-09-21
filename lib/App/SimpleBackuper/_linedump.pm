package App::SimpleBackuper;

use strict;
use warnings;
use Data::Dumper;

sub import {
	my $caller = caller;
	no strict 'refs';
	no warnings 'redefine';
	*{$caller.'::_linedump'} = \&_linedump;
}

sub _linedump { scalar Data::Dumper->new(\@_)->Indent(0)->Terse(1)->Pair('=>')->Quotekeys(0)->Sortkeys(1)->Dump() }

1;
