package App::SimpleBackuper::DB;

use strict;
use warnings;
use Const::Fast;
use App::SimpleBackuper::_linedump;
use App::SimpleBackuper::DB::BackupsTable;
use App::SimpleBackuper::DB::FilesTable;
use App::SimpleBackuper::DB::PartsTable;
use App::SimpleBackuper::DB::BlocksTable;
use App::SimpleBackuper::DB::UidsGidsTable;

const my $FORMAT_VERSION => 1;

sub _unpack_tmpl {
	my($self, $tmpl) = @_;
	my $length = length pack $tmpl;
	my $buf = substr $self->{dump}, $self->{offset}, $length;
	$self->{offset} += $length;
	return unpack $tmpl, $buf;
}

sub _unpack_record {
	my($self) = @_;
	my $length = $self->_unpack_tmpl("J");
	return $self->_unpack_tmpl("a$length");
}

sub new {
	my($class, $dump_ref) = @_;
	
	my $self = bless {
		backups 	=> App::SimpleBackuper::DB::BackupsTable->new(),
		files		=> App::SimpleBackuper::DB::FilesTable->new(),
		parts		=> App::SimpleBackuper::DB::PartsTable->new(),
		blocks		=> App::SimpleBackuper::DB::BlocksTable->new(),
		uids_gids	=> App::SimpleBackuper::DB::UidsGidsTable->new(),
	} => $class;
	
	if($dump_ref) {
		$self->{dump} = $$dump_ref;
		$self->{offset} = 0;
		
		my($format_version, $backups_cnt, $files_cnt, $uids_gids_cnt, $parts_cnt) = $self->_unpack_tmpl("JJJJ");
		
		die "Unsupported database format version $format_version" if $format_version != $FORMAT_VERSION;
		
		$self->{backups}	->[$_ - 1] = $self->_unpack_record() for 1 .. $backups_cnt;
		$self->{files}		->[$_ - 1] = $self->_unpack_record() for 1 .. $files_cnt;
		$self->{uids_gids}	->[$_ - 1] = $self->_unpack_record() for 1 .. $uids_gids_cnt;
		
		delete $self->{ $_ } foreach qw(dump offset);
	}
	
	
	for my $q (0 .. $#{ $self->{backups} }) {
		my $backup = $self->{backups}->unpack( $self->{backups}->[$q] );
		$backup->{files_cnt} = 0;
		$self->{backups}->[$q] = $self->{backups}->pack( $backup );
	}
	
	for my $q (0 .. $#{ $self->{files} }) {
		my $file = $self->{files}->unpack( $self->{files}->[ $q ] );
		foreach my $version (@{ $file->{versions} }) {
			
			foreach my $part ( @{ $version->{parts} } ) {
				$self->{parts}->upsert({hash => $part->{hash}}, $part);
			}
			
			for my $backup_id ( $version->{backup_id_min} .. $version->{backup_id_max} ) {
				my $backup = $self->{backups}->find_row({ id => $backup_id });
				$backup->{files_cnt}++;
				$self->{backups}->upsert({ id => $backup_id }, $backup );
			}
			
			my $block = $self->{blocks}->find_row({ id => $version->{block_id} });
			if(! $block) {
				$self->{blocks}->upsert(
					{id	=> $version->{block_id}},
					{
						id				=> $version->{block_id},
						last_backup_id	=> $version->{backup_id_max},
						parts_cnt		=> scalar @{ $version->{parts} },
					}
				);
			} else {
				$block->{last_backup_id} = $version->{backup_id_max} if $block->{last_backup_id} < $version->{backup_id_max};
				$block->{parts_cnt} += @{ $version->{parts} };
				$self->{blocks}->upsert({ id => $version->{block_id} }, $block);
			}
		}
	}
	
	return $self;
}

sub dump {
	my $self = shift;
	
	return \ join('',
		pack("JJJJ", $FORMAT_VERSION, scalar @{ $self->{backups} }, scalar @{ $self->{files} }, scalar @{ $self->{uids_gids} }),
		map { pack("Ja".length($_), length($_), $_) } @{ $self->{backups} }, @{ $self->{files} }, @{ $self->{uids_gids} }
	);
}

1;