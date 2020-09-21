#!/usr/bin/perl

use strict;
use warnings;
use Test::Spec;

describe DB => sub {
	require(__FILE__ =~ s/\.t$/\/BaseTable.t/r) or die $!;
	require(__FILE__ =~ s/\.t$/\/BackupsTable.t/r) or die $!;
	require(__FILE__ =~ s/\.t$/\/FilesTable.t/r) or die $!;
};

1;
