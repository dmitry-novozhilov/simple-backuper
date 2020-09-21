#!/usr/bin/perl

use strict;
use warnings;
use Test::Spec;
use IPC::Open2;
use Crypt::OpenSSL::RSA;
use File::Path qw(make_path);
use Data::Dumper;
use App::SimpleBackuper::DB;
use App::SimpleBackuper::StorageLocal;
use App::SimpleBackuper::Create;
use App::SimpleBackuper::Info;
use App::SimpleBackuper::RestoreDB;
use App::SimpleBackuper::Restore;

it 'most common workflow' => sub {
	
	make_path('/tmp/simple-backuper-test/src', '/tmp/simple-backuper-test/storage');
	unlink('/tmp/simple-backuper-test/dst/a.file', '/tmp/simple-backuper-test/src/b.file', '/tmp/simple-backuper-test/db', '/tmp/simple-backuper-test/dst');
	open(my $fh, '>', '/tmp/simple-backuper-test/src/a.file') or die "Can't write test file: $!";
	print $fh "1" x 2_000_000;
	close($fh);
	
	
	my $priv_key = `openssl genrsa 2>/dev/null`;
	my $public_key;
	{
		my $pid = open2(my $out, my $in, qw(openssl rsa -pubout)) or die "Failed to gen public key by: $!";
		print $in $priv_key;
		close($in);
		$public_key = join('', <$out>);
		close($out);
		waitpid($pid, 0);
	}
	
	my %options = (
		db					=> '/tmp/simple-backuper-test/db',
		compression_level	=> 9,
		space_limit			=> 10_000_000,
		files				=> {
			'/tmp/simple-backuper-test/src'	=> 5,
		},
		'backup-name'		=> 'test',
	);
	
	my %state = (
		rsa		=> Crypt::OpenSSL::RSA->new_public_key($public_key),
		db		=> App::SimpleBackuper::DB->new(),
		storage	=> App::SimpleBackuper::StorageLocal->new('/tmp/simple-backuper-test/storage'),
	);
	
	App::SimpleBackuper::Create(\%options, \%state);
	
	ok -f '/tmp/simple-backuper-test/db';
	
	
	unlink '/tmp/simple-backuper-test/db';
	
	App::SimpleBackuper::RestoreDB(
		{db => '/tmp/simple-backuper-test/db'},
		{
			rsa		=> Crypt::OpenSSL::RSA->new_private_key($priv_key),
			storage	=> App::SimpleBackuper::StorageLocal->new('/tmp/simple-backuper-test/storage'),
		}
	);
	
	{
		my $db_file = App::SimpleBackuper::RegularFile->new($options{db}, \%options);
		$db_file->read();
		$db_file->decompress();
		$state{db} = App::SimpleBackuper::DB->new( $db_file->data_ref );
	}
	
	
	is_deeply App::SimpleBackuper::Info(\%options, \%state)->{subfiles},
		[ { name => 'tmp', oldest_backup => 'test', newest_backup => 'test'} ];
	
	is_deeply App::SimpleBackuper::Info({%options, path => '/'}, \%state)->{subfiles},
		[ { name => 'tmp', oldest_backup => 'test', newest_backup => 'test'} ];
	
	is_deeply App::SimpleBackuper::Info({%options, path => '/not-existent'}, \%state), {error => 'NOT_FOUND'};
	
	my $result = App::SimpleBackuper::Info({%options, path => '/tmp/simple-backuper-test/src'}, \%state);
	is_deeply $result->{subfiles}, [ { name => 'a.file', oldest_backup => 'test', newest_backup => 'test'} ];
	is $result->{versions}->[0]->{user}, scalar getpwuid($<);
	is $result->{versions}->[0]->{group}, scalar getgrgid($();
	is_deeply $result->{versions}->[0]->{backups}, ['test'];
	
	
	ok ! App::SimpleBackuper::Restore({
		db					=> '/tmp/simple-backuper-test/db',
		'backup-name'		=> 'test',
		path				=> '/tmp/simple-backuper-test/src',
		destination			=> '/tmp/simple-backuper-test/dst',
		write				=> 1,
	}, \%state)->{error};
	
	ok -f '/tmp/simple-backuper-test/dst/a.file';
	
	open($fh, '<', '/tmp/simple-backuper-test/dst/a.file') or die "Can't read test file: $!";
	my $file = join('', <$fh>);
	close($fh);
	
	is $file, "1" x 2_000_000;
	
	sleep 1; # For change mtime
	
	open($fh, '>>', '/tmp/simple-backuper-test/src/a.file') or die "Can't write test file: $!";
	print $fh "2";
	close($fh);
	
	App::SimpleBackuper::Create({%options, 'backup-name' => 'test2'}, \%state);
	
	ok ! App::SimpleBackuper::Restore({
		db					=> '/tmp/simple-backuper-test/db',
		'backup-name'		=> 'test2',
		path				=> '/tmp/simple-backuper-test/src',
		destination			=> '/tmp/simple-backuper-test/dst',
		write				=> 1,
	}, \%state)->{error};
	
	open($fh, '<', '/tmp/simple-backuper-test/dst/a.file') or die "Can't read test file: $!";
	$file = join('', <$fh>);
	close($fh);
	
	ok $file eq ("1" x 2_000_000)."2";
	
	ok ! App::SimpleBackuper::Restore({
		db					=> '/tmp/simple-backuper-test/db',
		'backup-name'		=> 'test',
		path				=> '/tmp/simple-backuper-test/src',
		destination			=> '/tmp/simple-backuper-test/dst',
		write				=> 1,
	}, \%state)->{error};
	
	open($fh, '<', '/tmp/simple-backuper-test/dst/a.file') or die "Can't read test file: $!";
	$file = join('', <$fh>);
	close($fh);
	
	is $file, "1" x 2_000_000;
	
	sleep 1;
	
	open($fh, '>', '/tmp/simple-backuper-test/src/b.file') or die "Can't write test file: $!";
	print $fh "3" x 1_000_000;
	close($fh);
	
	App::SimpleBackuper::Create({%options, 'backup-name' => 'test3'}, \%state);
	
	open($fh, '>', '/tmp/simple-backuper-test/src/a.file') or die "Can't write test file: $!";
	print $fh "3";
	close($fh);
	
	App::SimpleBackuper::Create({%options, space_limit => 700, 'backup-name' => 'test4'}, \%state);
};

1;