package App::SimpleBackuper;

use strict;
use warnings;
use feature ':5.'.substr($], 3, 2);
use Carp;
use Try::Tiny;
use Time::HiRes qw(time);
use App::SimpleBackuper::_linedump;
use App::SimpleBackuper::_format;

sub _block_deletion_info($$$$$$);
sub _block_deletion_info($$$$$$) {
	my($options, $state, $block_info, $parent_id, $path, $priority) = @_;
	
	my $subfiles = $state->{db}->{files}->find_all({parent_id => $parent_id});
	foreach my $file ( @$subfiles ) {
		
		my $full_path = ($path eq '/' ?  $path : "$path/").$file->{name};
		my $prio = $priority;
		while(my($mask, $p) = each %{ $options->{files} }) {
			$prio = $p if match_glob( $mask, $full_path );
		}
		
		_block_deletion_info($options, $state, $block_info, $file->{id}, $full_path, $prio);
		
		my %file_added2block;
		foreach my $version ( @{ $file->{versions} } ) {
			next if ! $version->{block_id};
			
			$block_info->{ $version->{block_id} } ||= [0, 0, []];
			if($block_info->{ $version->{block_id} }->[0] < $version->{backup_id_max} * $prio) {
				$block_info->{ $version->{block_id} }->[0] = $version->{backup_id_max} * $prio;
			}
			foreach my $part (@{ $version->{parts} }) {
				$block_info->{ $version->{block_id} }->[1] += $part->{size};
			}
			if(! $file_added2block{ $version->{block_id} }) {
				push @{ $block_info->{ $version->{block_id} }->[2] }, $file->{parent_id}, $file->{id}, $full_path;
			}
			
			$file_added2block{ $version->{block_id} } = 1;
		}
	}
}

sub _proc_uid_gid($$$) {
	my($uid, $gid, $uids_gids) = @_;
	
	my $last_uid_gid = @$uids_gids ? $uids_gids->unpack( $uids_gids->[-1] )->{id} : 0;
	
	my $user_name = getpwuid($uid);
	my($user) = grep { $_->{name} eq $user_name } map { $uids_gids->unpack($_) } @$uids_gids;
	if(! $user) {
		$user = {id => ++$last_uid_gid, name => $user_name};
		$uids_gids->upsert({ id => $user->{id} }, $user );
		printf "new owner user added (unix uid %d, name %s, internal uid %d)\n", $uid, $user_name, $user->{id};
	}
	$uid = $user->{id};
	
	my $group_name = getgrgid($gid);
	my($group) = grep { $_->{name} eq $group_name } map { $uids_gids->unpack($_) } @$uids_gids;
	if(! $group) {
		$group = {id => ++$last_uid_gid, name => $group_name};
		$uids_gids->upsert({ id => $group->{id} }, $group );
		printf "new owner group added (unix gid %d, name %s, internal gid %d)\n", $gid, $group_name, $group->{id};
	}
	$gid = $group->{id};
	
	return $uid, $gid;
}

sub Create {
	my($options, $state) = @_;
	
	my($backups, $files, $parts, $blocks) = @{ $state->{db} }{qw(backups files parts blocks)};
	
	die "Backup '$options->{\"backup-name\"}' already exists" if grep { $backups->unpack($_)->{name} eq $options->{'backup-name'} } @$backups;
	
	$state->{$_} = 0 foreach qw(last_backup_id last_file_id last_block_id bytes_processed bytes_in_last_backup total_weight);
	
	print "Preparing to backup: ";
	$state->{profile}->{init_ids} = -time;
	foreach (@$backups) {
		my $id = $backups->unpack($_)->{id};
		$state->{last_backup_id} = $id if ! $state->{last_backup_id} or $state->{last_backup_id} < $id;
		
	}
	print "last backup id $state->{last_backup_id}, ";
	foreach (@$files) {
		my $file = $files->unpack($_);
		$state->{last_file_id} = $file->{id} if ! $state->{last_file_id} or $state->{last_file_id} < $file->{id};
		$state->{bytes_in_last_backup} += $file->{versions}->[-1]->{size} if $file->{versions} and @{ $file->{versions} };
	}
	print "last file id $state->{last_file_id}, ";
	foreach (@$blocks) {
		my $id = $blocks->unpack($_)->{id};
		$state->{last_block_id} = $id if ! $state->{last_block_id} or $state->{last_block_id} < $id;
	}
	print "last block id $state->{last_block_id}, ";
	$state->{profile}->{init_ids} += time;
	
	print "total weight ";
	$state->{total_weight} += $parts->unpack($_)->{size} foreach @$parts;
	print fmt_weight($state->{total_weight}).", ";
	
	my $cur_backup = {name => $options->{'backup-name'}, id => ++$state->{last_backup_id}, files_cnt => 0, max_files_cnt => 0};
	$backups->upsert({ id => $cur_backup->{id} }, $cur_backup);
	
	{
		print "blocks stack to delete...";
		_block_deletion_info($options, $state, \my %block_info, 0, '/', 0);
		$state->{blocks_stack2delete} = [
			map {[ $_, @{ $block_info{$_}->[2] } ]} sort {
				$block_info{$a}->[0] <=> $block_info{$b}->[0]
				or $block_info{$b}->[1] <=> $block_info{$a}->[1]
			} grep {$_} map { $blocks->unpack( $_ )->{id} } @$blocks
		];
		print " OK\n";
	}
	
	_print_progress($state);
	
	
	my %files_queues_by_priority;
	while(my($mask, $priority) = each %{ $options->{files} }) {
		next if ! $priority;
		foreach my $path (glob $mask) {
			if(grep { ~index($path, $_ =~ s/(?!\/)$/\//r) } map {@$_} values %files_queues_by_priority) {
				next;
			}
			
			# Remove child paths
			foreach my $tasks (values %files_queues_by_priority) {
				my $tasks_cnt = @$tasks;
				@$tasks = grep { ! ~index($_->[0], $path =~ s/(?!\/)$/\//r) } @$tasks;
			}
			
			my $file_id = 0; {
				my @path = split(/\//, $path, -1);
				pop @path if @path and $path[-1] eq '';
				pop @path;
				
				my @cur_path;
				foreach my $path_node (@path) {
					push @cur_path, $path_node;
					
					my $file = $files->find_by_parent_id_name($file_id, $path_node);
					if(! $file) {
						my @stat = lstat(join('/', @cur_path) || '/');
						my($uid, $gid) =_proc_uid_gid($stat[4], $stat[5], $state->{db}->{uids_gids});
						$file = {
							parent_id	=> $file_id,
							id			=> ++$state->{last_file_id},
							name		=> $path_node,
							versions	=> [
								{
									backup_id_min	=> $state->{last_backup_id},
									backup_id_max	=> $state->{last_backup_id},
									uid				=> $uid,
									gid				=> $gid,
									size			=> $stat[7],
									mode			=> $stat[2],
									mtime			=> $stat[9],
									block_id		=> 0,
									symlink_to		=> undef,
									parts			=> [],
								}
							],
						};
						$files->upsert({ id => $file->{id}, parent_id => $file->{parent_id} }, $file);
					}
					$file_id = $file->{id};
				}
			}
			
			push @{ $files_queues_by_priority{$priority} }, [ $path, $priority, $file_id ];
		}
	}
	delete $files_queues_by_priority{ $_ } foreach grep {! @{ $files_queues_by_priority{ $_ } }} keys %files_queues_by_priority;
	
	while(%files_queues_by_priority) {
		my($priority) = sort {$b <=> $a} keys %files_queues_by_priority;
		my $task = shift @{ $files_queues_by_priority{$priority} };
		delete $files_queues_by_priority{$priority} if ! @{ $files_queues_by_priority{$priority} };
		my @next = _file_proc( $task, $options, $state );
		unshift @{ $files_queues_by_priority{ $_->[1] } }, $_ foreach reverse @next;
	}
	
	my $db_file = App::SimpleBackuper::RegularFile->new($options->{db}, $options);
	$db_file->data_ref( $state->{db}->dump() );
	
	$db_file->compress();
	$db_file->write();
	
	my($key, $iv) = $db_file->gen_keys();
	$db_file->encrypt( $key, $iv );
	
	$state->{storage}->put(db => $db_file->data_ref);
	
	my $db_key = $state->{rsa}->encrypt(pack("a32a16", $key, $iv));
	
	$state->{storage}->put('db.key' => \$db_key);
	
	_print_progress($state, 1);
}

sub _print_progress {
	state $last_print_time = 0;
	return if time - $last_print_time < 60 and ! $_[1];
	
	printf "Progress: processed %s of %s in last backup, total backups weight %s.\n",
		fmt_weight($_[0]->{bytes_processed}), fmt_weight($_[0]->{bytes_in_last_backup}), fmt_weight($_[0]->{total_weight});
	$last_print_time = time;
}

use Text::Glob qw(match_glob);
use Fcntl ':mode'; # For S_ISDIR & same
use App::SimpleBackuper::RegularFile;

sub _file_proc {
	my($task, $options, $state) = @_;
	
	_print_progress($state);
	
	confess "No task" if ! $task;
	confess "No filepath" if ! $task->[0];
	
	my @next;
	
	print "$task->[0]\n";
	print "\tparent #$task->[2], priority $task->[1]";
	
	my $priority = $task->[1];
	while(my($mask, $p) = each %{ $options->{files} }) {
		if(match_glob( $mask, $task->[0] )) {
			$priority = $p;
			print ", priority $priority by rule '\"$mask\": $p'";
		}
	}
	
	if(! $priority) { # Excluded by user
		print " -> skip\n";
		return;
	}
	
	$state->{profile}->{fs} -= time;
	$state->{profile}->{fs_lstat} -= time;
	my @stat = lstat($task->[0]);
	$state->{profile}->{fs} += time;
	$state->{profile}->{fs_lstat} += time;
	if(! @stat) {
		print ". Not exists\n";
		return;
	}
	else {
		printf ", stat: %s:%s %o %s modified at %s", scalar getpwuid($stat[4]), scalar getgrgid($stat[5]), $stat[2], fmt_weight($stat[7]), fmt_datetime($stat[9]);
	}
	
	
	my($backups, $blocks, $files, $parts, $uids_gids) = @{ $state->{db} }{qw(backups blocks files parts uids_gids)};
	
	
	my($uid, $gid) = _proc_uid_gid($stat[4], $stat[5], $uids_gids);
	
	
	my($file); {
		my($filename) = $task->[0] =~ /([^\/]+)\/?$/;
		$file = $files->find_by_parent_id_name($task->[2], $filename);
		if($file) {
			print ", is old file #$file->{id}";
		} else {
			$file = {
				parent_id	=> $task->[2],
				id			=> ++$state->{last_file_id},
				name		=> $filename,
				versions	=> [],
			};
			print ", is new file #$file->{id}";
		}
	}
	
	my %version = (
		backup_id_min	=> $state->{last_backup_id},
		backup_id_max	=> $state->{last_backup_id},
		uid				=> $uid,
		gid				=> $gid,
		size			=> $stat[7],
		mode			=> $stat[2],
		mtime			=> $stat[9],
		block_id		=> undef,
		symlink_to		=> undef,
		parts			=> [],
	);
	
	$state->{bytes_processed} += $version{size};
	
	if(S_ISDIR $stat[2]) {
		print ", is directory.\n";
		my $dh;
		
		$state->{profile}->{fs} -= time;
		$state->{profile}->{fs_read_dir} -= time;
		if(! opendir($dh, $task->[0])) {
			$state->{profile}->{fs} += time;
			$state->{profile}->{fs_read_dir} += time;
			push @{ $state->{fails}->{$!} }, $task->[0];
			print ", can't read: $!\n";
			return;
		}
		my @files;
		while(my $f = readdir($dh)) {
			next if $f eq '.' or $f eq '..';
			push @files, $f;
		}
		closedir($dh);
		$state->{profile}->{fs} += time;
		$state->{profile}->{fs_read_dir} += time;
		
		$version{block_id} = 0;
		
		push @next, map { [$task->[0].($task->[0] =~ /\/$/ ? '' : '/').$_, $priority, $file->{id}] } sort @files;
	}
	elsif(S_ISLNK $stat[2]) {
		$state->{profile}->{fs} -= time;
		$state->{profile}->{fs_read_symlink} -= time;
		$version{symlink_to} = readlink($task->[0]);
		$state->{profile}->{fs} += time;
		$state->{profile}->{fs_read_symlink} += time;
		if(defined $version{symlink_to}) {
			print ", is symlink to $version{symlink_to}.\n";
			$version{block_id} = 0;
		} else {
			push @{ $state->{fails}->{$!} }, $task->[0];
			print ", can't read: $!\n";
			return;
		}
	}
	elsif(S_ISREG $stat[2]) {
		
		print ", is regular file";
		
		$state->{profile}->{fs} -= time;
		$state->{profile}->{fs_read} -= time;
		my $reg_file = try {
			App::SimpleBackuper::RegularFile->new($task->[0], $options, $state);
		} catch {
			1 while chomp;
			push @{ $state->{fails}->{$_} }, $task->[0];
			print ", can't read: '$_'\n";
			0;
		};
		$state->{profile}->{fs} += time;
		$state->{profile}->{fs_read} += time;
		return if ! $reg_file;
		
		if(@{ $file->{versions} } and $file->{versions}->[-1]->{mtime} == $version{mtime}) {
			$version{parts} = $file->{versions}->[-1]->{parts}; # If mtime not changed then file not changed
			$version{block_id} = $file->{versions}->[-1]->{block_id};
			
			my $block = $blocks->find_row({ id => $version{block_id} });
			confess "File has lost block #$version{block_id} in backup "
				.$backups->find_row({ id => $version{backup_id_min} })->{name}
				."..".$backups->find_row({ id => $version{backup_id_max} })->{name}
				if ! $block;
			$block->{last_backup_id} = $state->{last_backup_id};
			$blocks->upsert({ id => $block->{id} }, $block);
			
			print ", mtime is not changed.\n";
		} else {
			print @{ $file->{versions} } ? ", mtime changed.\n" : "\n";
			my $part_number = 0;
			my %block_ids;
			while(1) {
				$state->{profile}->{fs} -= time;
				$state->{profile}->{fs_read} -= time;
				my $read = try {
					$reg_file->read($part_number);
				} catch {
					1 while chomp;
					push @{ $state->{fails}->{$_} }, $task->[0];
					print ", can't read: $_\n";
				};
				$state->{profile}->{fs} += time;
				$state->{profile}->{fs_read} += time;
				return if ! defined $read;
				last if ! $read;
				
				print "\tpart #$part_number: ";
				#print fmt_weight($read)." read, ";
				
				my %part = (
					hash	=> undef,
					size	=> undef,
					aes_key	=> undef,
				);
				$state->{profile}->{math} -= time;
				$state->{profile}->{math_hash} -= time;
				$part{hash} = $reg_file->hash();
				$state->{profile}->{math} += time;
				$state->{profile}->{math_hash} += time;
				print "hash ".fmt_hex2base64($part{hash}).", ";
				
				
				# Search for part with this hash
				if(my $part = $parts->find_row({ hash => $part{hash} })) {
					$block_ids{ $part->{block_id} }++ if $part->{block_id};
					$part{size} = $part->{size};
					$part{aes_key} = $part->{aes_key};
					$part{aes_iv} = $part->{aes_iv};
					print "backuped earlier (".fmt_weight($read)." -> ".fmt_weight($part->{size}).");\n";
				} else {
					$state->{profile}->{math} -= time;
					$state->{profile}->{math_compress} -= time;
					my $ratio = $reg_file->compress();
					$state->{profile}->{math} += time;
					$state->{profile}->{math_compress} += time;
					print 'compressed ('.fmt_weight($read).' -> '.fmt_weight($reg_file->size).")";
					
					($part{aes_key}, $part{aes_iv}) = $reg_file->gen_keys();
					$state->{profile}->{math} -= time;
					$state->{profile}->{math_encrypt} -= time;
					$reg_file->encrypt($part{aes_key}, $part{aes_iv});
					$state->{profile}->{math} += time;
					$state->{profile}->{math_encrypt} += time;
					print ', encrypted';
					
					$state->{total_weight} += $part{size} = $reg_file->size;
					
					if($state->{total_weight} > $options->{space_limit}) {
						print "freeing up space by ".fmt_weight($state->{total_weight} - $options->{space_limit})."\n";
						while($state->{total_weight} > $options->{space_limit}) {
							_free_up_space($options, $state, \%block_ids);
						}
						print "\t... ";
					}
					
					$state->{profile}->{storage} -= time;
					$state->{storage}->put(fmt_hex2base64($part{hash}), $reg_file->data_ref);
					$state->{profile}->{storage} += time;
					
					print " and stored;\n";
					
					$parts->upsert({ hash => $part{hash} }, \%part);
				}
				
				push @{ $version{parts} }, \%part;
				
				$part_number++;
				
				last if $read < 1;
			}
			
			
			my $block;
			if(1 == %block_ids) {
				$block = $blocks->find_row({ id => keys %block_ids });
				die "Block #".join(', ', keys %block_ids)." wasn't found" if ! $block;
			}
			elsif(%block_ids) {
				# Search for block with highest parts count
				my $block_parts_cnt = 0;
				foreach my $bi ( keys %block_ids ) {
					my $b = $blocks->find_row({ id => $bi });
					if(! $block_parts_cnt or $block_parts_cnt < $b->{parts_cnt}) {
						$block_parts_cnt = $b->{parts_cnt};
						$block = $b;
					}
				}
				
				# Merge blocks to highest one
				foreach my $bi ( keys %block_ids ) {
					next if $bi == $block->{id};
					$state->{profile}->{db_find_version_by_block} -= time;
					for my $block_file_index ( 0 .. $#$files ) {
						my $block_file = $files->unpack( $files->[ $block_file_index ] );
						foreach my $version ( @{ $block_file->{versions} } ) {
							next if $version->{block_id} != $bi;
							$version->{block_id} = $block->{id};
							$block->{parts_cnt} += @{ $version->{parts} };
						}
						$files->[ $block_file_index ] = $files->pack( $block_file );
					}
					$state->{profile}->{db_find_version_by_block} += time;
					$blocks->delete({ id => $bi });
				}
			} else {
				$block = {
					id				=> ++$state->{last_block_id},
					parts_cnt		=> scalar @{ $version{parts} },
				};
			}
			
			foreach my $part (@{ $version{parts} }) {
				$part->{block_id} //= $block->{id};
				$parts->upsert({ hash => $part->{hash} }, $part);
			}
				
			
			$block->{last_backup_id} = $state->{last_backup_id};
			$blocks->upsert({ id => $block->{id} }, $block);
			
			$version{block_id} = $block->{id};
		}
	}
	else {
		print ", skip not supported file type\n";
		return;
	}
	
	
	# If file version not changed, use old version with wider backup ids range
	if(	@{ $file->{versions} }
		and (
			$file->{versions}->[-1]->{backup_id_max} + 1 == $state->{last_backup_id}
			or $file->{versions}->[-1]->{backup_id_max} == $state->{last_backup_id}
		)
		and $file->{versions}->[-1]->{uid}	== $version{uid}
		and $file->{versions}->[-1]->{gid}	== $version{gid}
		and $file->{versions}->[-1]->{size}	== $version{size}
		and $file->{versions}->[-1]->{mode}	== $version{mode}
		and $file->{versions}->[-1]->{mtime}== $version{mtime}
		and ( defined $file->{versions}->[-1]->{symlink_to} == defined $version{symlink_to} or ( defined $version{symlink_to} and $file->{versions}->[-1]->{symlink_to} eq $version{symlink_to} ) )
		and join(' ', map { $_->{hash} } @{ $file->{versions}->[-1]->{parts} }) eq join(' ', map { $_->{hash} } @{ $version{parts} })
	) {
		$file->{versions}->[-1]->{backup_id_max} = $state->{last_backup_id};
	} else {
		push @{ $file->{versions} }, \%version;
	}
	
	$files->upsert({ parent_id => $file->{parent_id}, id => $file->{id} }, $file );
	
	my $backup = $backups->find_row({ id => $state->{last_backup_id} });
	$backup->{files_cnt}++;
	$backup->{max_files_cnt}++;
	$backups->upsert({ id => $state->{last_backup_id} }, $backup );
	
	return @next;
}

sub _free_up_space {
	my($options, $state, $protected_block_ids) = @_;
	
	my($backups, $files, $blocks, $parts) = @{ $state->{db} }{qw(backups files blocks parts)};
	
	my $deleted = 0;
	while ( @{ $state->{blocks_stack2delete} } ) {
		my($block_id, @files) = @{ shift @{ $state->{blocks_stack2delete} } };
		my $block = $blocks->find_row({ id => $block_id });
		next if ! $block;
		next if exists $protected_block_ids->{$block_id};
		next if $block->{last_backup_id} == $state->{last_backup_id};
		
		my %parts2delete;
		
		# Delete all from block
		$state->{profile}->{db_delete_all_from_block} -= time;
		
		while(@files) {
			my $parent_id = shift @files;
			my $id = shift @files;
			my $full_path = shift @files;
			my $file = $files->find_all({parent_id => $parent_id, id => $id})->[0];
			
			foreach my $version ( @{ $file->{versions} } ) {
				next if $version->{block_id} != $block_id;
				
				print "\t\t\tDeleting $full_path from ".
					(
						$version->{backup_id_min} == $version->{backup_id_max}
						? "backup ".$backups->find_row({ id => $version->{backup_id_max} })->{name}
						: "backups ".$backups->find_row({ id => $version->{backup_id_min} })->{name}
							."..".$backups->find_row({ id => $version->{backup_id_max} })->{name}
					)."\n";
				
				$parts2delete{ $_->{hash} } = $_ foreach @{ $version->{parts} };
				
				
				foreach my $backup_id ( $version->{backup_id_min} .. $version->{backup_id_max} ) {
					my $backup = $backups->find_row({ id => $backup_id });
					next if ! $backup;
					$backup->{files_cnt}--;
					if( $backup->{files_cnt} ) {
						$backups->upsert({ id => $backup_id }, $backup);
					} else {
						$backups->delete({ id => $backup_id });
					}
				}
			}
			
			# Delete version
			@{ $file->{versions} } = grep {$_->{block_id} != $block_id} @{ $file->{versions} };
			
			if( @{ $file->{versions} } ) {
				$files->upsert({parent_id => $parent_id, id => $id}, $file);
			} else {
				$files->delete({parent_id => $parent_id, id => $id});
			}
		}
		$state->{profile}->{db_delete_all_from_block} += time;
		
		$blocks->delete({ id => $block_id });
		
		foreach my $part (values %parts2delete) {
			$state->{storage}->remove(fmt_hex2base64($part->{hash}));
			$parts->delete({hash => $part->{hash}});
			$state->{total_weight} -= $part->{size};
			$deleted++;
			print "\t\t\tpart ".fmt_hex2base64($part->{hash})." deleted (".fmt_weight($part->{size})." of space freed)\n";
		}
		
		last if $deleted;
	}
	
	die "Nothing to delete from storage for free space" if ! $deleted;
}

1;
