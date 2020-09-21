#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::Spec;

describe SimpleBackuper => sub {
	require(__FILE__ =~ s/[^\/]+\.t$/\/lib\/App\/SimpleBackuper\/DB.t/r) or die $!;
	require(__FILE__ =~ s/[^\/]+\.t$/\/lib\/App\/SimpleBackuper\/RegularFile.t/r) or die $!;
	require(__FILE__ =~ s/[^\/]+\.t$/\/lib\/App\/SimpleBackuper\/Actions.t/r) or die $!;
};

runtests;
