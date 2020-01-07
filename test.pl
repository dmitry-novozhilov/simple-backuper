#!/usr/bin/perl

use strict;
use warnings;
use Readonly;

Readonly my $GPG_RECIPIENT => shift || die "Usage: test.pl <gpg recipient>";


run("rm -rf ./test_data");
run("mkdir -p ./test_data/data");
open(my $fh, ">./test_data/test.conf.json") or die $!;
print $fh <<CONF;
{
	low_memory: 1,
	db_file:	"test_data/test.db",
	data_proc_before_store_cmd: "xz --compress -9 --stdout --memlimit=1GiB | gpg --encrypt -z 0 --recipient $GPG_RECIPIENT",
	source: {
		"test_data/data": 5,
	},
	destination: {
		path: "test_data/backup",
		weight_limit_gb: 1,
	},
}
CONF
close($fh);
run("dd if=/dev/urandom of=./test_data/data/1 bs=1M count=1");
run("dd if=/dev/urandom of=./test_data/data/2 bs=1M count=1");
run("ln -s 2 ./test_data/data/symlink_to_2");
backup('first');
run("mkdir -p ./test_data/restored");
restore('first');

run("dd if=/dev/urandom bs=1M count=1 >> ./test_data/data/2");

backup('second');
restore('second');
check();

run("rm -rf ./test_data");
print "All tests passed.\n";


sub backup { run("perl ./backuper.pl ./test_data/test.conf.json ".shift) }

sub restore { run("perl ./restore.pl --db ./test_data/test.db --from test_data/data --restore --to ./test_data/restored --name ".shift." --storage-path test_data/backup --proc-cmd 'gpg --decrypt 2>/dev/null | xz --decompress'") }

sub check {	
	die "file '$_' doesn't restored" foreach grep {! -e "./test_data/restored/$_"} (qw(1 2 symlink_to_2));
	die $_ foreach map {`diff --brief test_data/data/$_ test_data/restored/$_`} (1, 2);
	die "Symlink broken" if `readlink test_data/restored/symlink_to_2` ne "2\n";
}

sub run {
	my($cmd) = @_;
	my $result = `$cmd 2>&1`;
	chomp $result;
	$result =~ s/\n/\n\t/g;
	if($?) {
		die "FAILED: $cmd:\n$result\n";
	} else {
		print "DONE:   $cmd".($result ? ":\n\t$result" : '')."\n";
	}
}
