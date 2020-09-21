package App::SimpleBackuper;

use strict;
use warnings;

sub RestoreDB {
	my($options, $state) = @_;
	
	my $db_file = App::SimpleBackuper::RegularFile->new($options->{db}, $options);
	print "Downloading database file from storage.\n";
	$db_file->data_ref($state->{storage}->get('db'));
	
	print "Downloading database keys from storage.\n";
	my $db_key = $state->{storage}->get('db.key');
	
	print "Decrypting database keys with RSA private key.\n";
	$db_key = $state->{rsa}->decrypt($$db_key);
	my($key, $iv) = unpack("a32a16", $db_key);
	
	print "Decrypting database with AES database keys.\n";
	$db_file->decrypt($key, $iv);
	
	print "Saving database.\n";
	$db_file->write();
}

1;
