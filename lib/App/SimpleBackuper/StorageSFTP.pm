package App::SimpleBackuper::StorageSFTP;

use strict;
use warnings;
use Net::SFTP::Foreign;
use Net::SFTP::Foreign::Constants qw(SSH2_FX_CONNECTION_LOST);

sub new {
	my($class, $options) = @_;
	my(undef, $user, $host, $path) = $options =~ /^(([^@]+)@)?([^:]+):(.*)$/;
	
	my $sftp = Net::SFTP::Foreign->new(host => $host, ($user ? (user => $user) : ()));
	$sftp->die_on_error("SFTP connect error");
	$sftp->setcwd($path) or die "Can't setcwd to '$path': ".$sftp->error;
	
	my $self = bless {user => $user, host => $host, path => $path} => $class;
	$self->_connect();
	
	return $self;
}

sub _connect {
	my($self) = @_;
	
	$self->{sftp} = Net::SFTP::Foreign->new(host => $self->{host}, ($self->{user} ? (user => $self->{user}) : ()));
	$self->{sftp}->die_on_error("SFTP connect error");
	$self->{sftp}->setcwd($self->{path}) or die "Can't setcwd to '$self->{path}': ".$self->{sftp}->error;
}

sub _do {
	my($self, $method, $params) = @_;
	my $attempts_left = 3;
	my @result;
	while($attempts_left--) {
		last if @result = $self->{sftp}->$method(@$params);
		if($self->{sftp}->status == SSH2_FX_CONNECTION_LOST and $attempts_left) {
			print " (".$self->{sftp}->error.", reconnecting)";
			sleep 30;
			$self->_connect();
		} else {
			$self->{sftp}->die_on_error("Can't $method (status=".$self->{sftp}->status.")");
		}
	}
	return @result;
}

sub put {
	my($self, $name, $content_ref) = @_;
	$self->_do(put_content => [ $$content_ref, $name ]);
	return $self;
}

sub get {
	my($self, $name) = @_;
	return \$self->_do(get_content => [ $name ]);
}

sub remove {
	my($self, $name) = @_;
	$self->_do(remove => [ $name ]);
	return $self;
}

1;
