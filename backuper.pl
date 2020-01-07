#!/usr/bin/perl

use strict;
use warnings;
use Fcntl ':mode';
use POSIX qw(strftime);
use Carp;
use Digest::SHA qw(sha512_base64);
use Text::Glob qw(match_glob);
use Time::HiRes qw(time);
use Try::Tiny;
use Readonly;


STDOUT->autoflush(1);

Readonly my %SIZE_TYPE => (	# Файлы делим на типоразмеры
	'0-1m'		=> [0,				1024*1024],
	'1m-10m'	=> [1024*1024,		10*1024*1024],
	'10m-100m'	=> [10*1024*1024,	100*1024*1024],
	'100m+'		=> [100*1024*1024,	undef],
);

Readonly my $CONFIG => init_config( shift || usage() );
Readonly my $BACKUP_NAME => shift || usage();
Readonly my $DB_FILE => glob($CONFIG->{db_file});
Readonly my $WEIGHT_LIMIT => $CONFIG->{destination}->{weight_limit_gb} * 1_000_000_000;
Readonly my $FILE_PARTS_BLOCK_VALUE_FORUMULA_SQL => "1000000000 * priorities / ( ? - last_backup_num + 1 ) / ( weight + 1 )";

my $dbh = init_dbh();
my($total_weight) = $dbh->selectrow_array("SELECT sum(packed_size) FROM (SELECT distinct sha512, packed_size FROM file_parts)");
$total_weight ||= 0;
$total_weight += -s $DB_FILE if -e $DB_FILE; # Вес БД тоже учитываем, хоть и без учёта очередных изменений

my %report;
$SIG{INT} = sub {print_report(); exit;};
my $last_report_print = time;

prepare_storage();

my $backup_num; {
	$dbh->do("INSERT OR IGNORE INTO backups (name) VALUES (?)", undef, $BACKUP_NAME);
	$backup_num = $dbh->sqlite_last_insert_rowid();
	if(! $backup_num) {
		warn "Backup named '$BACKUP_NAME' already exists!";
		exit -2;
	}
	print "backup_num = $backup_num\n";
}

{
	print "deleting empty blocks from failed backups...";
	prof_run(db_del_empty_blocks => sub { $dbh->do("DELETE FROM file_parts_blocks WHERE weight = 0") });
	print "done\n";
}

{ # Обновление ценности всех блоков частей файлов в связи с появлением нового бекапа
	print "updating file_parts_blocks value for...";
	prof_run(upd_blocks_value => sub { $dbh->do("UPDATE file_parts_blocks SET value = $FILE_PARTS_BLOCK_VALUE_FORUMULA_SQL",
		undef, $backup_num) });
	print "done\n";
}

my %files_queues_by_priority; {
	
	sub path_is_sub_path {
		my($path, $subpath) = @_;
		my @path = split(/\//, $path);
		my @subpath = split(/\//, $subpath);
		for my $q (0 .. $#path) {
			next if $subpath[$q] and $path[$q] eq $subpath[$q];
			return 0;
		}
		return 1;
	}
	
	while(my($mask, $priority) = each  %{ $CONFIG->{source} }) {
		next if ! $priority;
		foreach my $path (glob($mask)) {
			# Если есть корень, из которого растёт данный путь, пусть так и остаётся
			next if grep { path_is_sub_path($_, $path) } map {@$_} values %files_queues_by_priority;
			
			# Если есть корни, растущие из данного пути, уберём их, т.к. добавляем данный путь как корень
			while(my($pr, $tasks) = each %files_queues_by_priority) {
				my %to_filter = map {$_ => 1} grep { path_is_sub_path($path, $_->[0]) } @$tasks;
				@$tasks = grep {! $to_filter{ $_->[0] } } @$tasks;
			}
			
			push @{ $files_queues_by_priority{$priority} }, [$path, $priority, 0];
		}
	}
}

try {
	while(%files_queues_by_priority) {
		my($priority) = sort {$b <=> $a} keys %files_queues_by_priority;
		my $task = shift @{ $files_queues_by_priority{$priority} };
		delete $files_queues_by_priority{$priority} if ! @{ $files_queues_by_priority{$priority} };
		my @next = proc_file( @$task );
		push @{ $files_queues_by_priority{ $_->[1] } }, $_ foreach @next;
	}
} catch {
	warn report(error => "Backup failed: $_");
};

if($CONFIG->{low_memory}) {
	$dbh->do("VACUUM");
	$dbh->do("REINDEX");
} else {
	$dbh->sqlite_backup_to_file($DB_FILE);
}

{ # копируем шифрованный архив sqlite базы в папку с бекапами
	my $cmd = join(' | ',
		"cat $DB_FILE",
		$CONFIG->{data_proc_before_store_cmd},
		ssh_cmd("cat >$CONFIG->{destination}->{path}/db")
	);
	print "Compressing, encrypting and storing database...\t";
	print `$cmd`;
	print "Done\n";
}

print_report();

exit 0; ###############

sub proc_file {
	my($filepath, $priority, $parent_file_id) = @_;
	
	print_report() if time - $last_report_print > 60;
	
	print "$filepath\t";
	
	my @next;
	
	while(my($mask, $p) = each %{ $CONFIG->{source} }) {
		$mask =~ s/^~([^\/]*)/(getpwuid($1 ? getpwnam($1) : $<))[7]/e;
		if(match_glob( $mask, $filepath )) {
			$priority = $p;
			print "priority $priority by rule '\"$mask\": $p'\t";
		}
	}
	
	if(! $priority) { # Исключено пользователем
		print "skip\n";
		return;
	}
	
	my @stat = prof_run(lstat => sub { lstat($filepath) });
	
	if(! @stat) {
		print "not exists\n";
		return;
	}
	
	my %file = (
		parent_id	=> $parent_file_id,
		backup_num	=> $backup_num,
		filepath	=> $filepath,
		mode		=> $stat[2],
		size		=> $stat[7],
		user		=> scalar getpwuid($stat[4]),
		group		=> scalar getgrgid($stat[5]),
		atime		=> $stat[8],
		mtime		=> $stat[9],
		ctime		=> $stat[10],
	);
	
	{
		my($new_file_rowid) = prof_run( db_check_for_file_aready => sub { $dbh->selectrow_array("SELECT rowid FROM files
			WHERE backup_num = ? AND filepath = ?", undef, $backup_num, $filepath) } );
		
		if($new_file_rowid) {
			print "already done\n";
			return;
		}
	}
	
	
	if(S_ISDIR $stat[2]) {
		print "is directory\n";
		my $dh;
		if(! opendir($dh, $filepath)) {
			warn report(error => "Can't read dir '$filepath': $!");
			return;
		}
		my @files;
		while(my $f = readdir($dh)) {
			next if $f eq '.' or $f eq '..';
			push @files, $f;
		}
		closedir($dh);
		
		push @next, map { [$filepath.($filepath =~ /\/$/ ? '' : '/').$_, $priority] } sort @files
		
	}
	elsif(S_ISLNK $stat[2]) {
		my $link_target = readlink($filepath);
		print "is symlink to $link_target\n";
		$file{symlink_to} = $link_target; # save $link_target to db
	}
	elsif(S_ISREG $stat[2]) {
		print "is regular file\t";
		
		$dbh->{AutoCommit} = 0 if $CONFIG->{low_memory};
		
		if($stat[7]) {
			my $size_type;
			while(my($st, $sizes) = each %SIZE_TYPE) {
				$size_type = $st if $stat[7] >= $sizes->[0] and (! defined $sizes->[1] or $stat[7] < $sizes->[1]);
			}
			print "$size_type ($stat[7]b)\t";
			
			my $old_file = prof_run(db_select_old_file => sub { $dbh->selectrow_hashref("SELECT * FROM files
				WHERE backup_num < ? AND filepath = ?", undef, $backup_num, $filepath) });
			
			my $weight_added = 0;
			my $priorities_added = $priority;
			
			my @new_file_parts;
			# если mtime такой же, как в БД, сохраняем файл со старыми частями (находим в БД части этого файла из прошлого бекапа, и сохраняем как нынешние)
			if($old_file and $old_file->{mtime} == $file{mtime}) {
				@new_file_parts = map {@$_}
					prof_run(db_select_old_parts => sub {
						$dbh->selectall_arrayref("SELECT ? as backup_num, filepath, num_in_file, sha512, size_type, packed_size, block_id 
							FROM file_parts WHERE backup_num = ? and filepath = ?",
							{Slice=>{}}, $backup_num, $old_file->{backup_num}, $filepath,
						)
					});
				if(! @new_file_parts) {
					print "File info corrupted! Erase it and retry file processiong...";
					$dbh->do("DELETE FROM files WHERE filepath = ? AND backup_num = ?", undef, $filepath, $old_file->{backup_num});
					print "OK\n";
					return proc_file(@_)
				}
				print "\tnot changed, use old block#$new_file_parts[0]->{block_id}";
			} else { # если mtime изменился, идём по частям файла:
				
				if($old_file) {
					print "+ ".($file{mtime} - $old_file->{mtime})."s mtime:\n";
				} else {
					print "new file:\n";
				}
				
				my $parts_size = $SIZE_TYPE{ $size_type }->[0] || $SIZE_TYPE{ $size_type }->[1];
				my $parts_count = int($file{size} / $parts_size) + !!($file{size} % $parts_size);
				
				if(open(my $fh, '<', $filepath)) {
					
					for my $num_in_file (0 .. $parts_count - 1) {
						print "\tpart#$num_in_file\t";
						
						my $part_size = $num_in_file == ($parts_count - 1) ? ($file{size} % $parts_size) : $parts_size;
						
						
						# Считаем контрольную сумму в перле, а не внешней утилитой, для того, чтобы не читать потом повторно файл с диска
						my $part_body;
						prof_run(read_file => sub { read($fh, $part_body, $parts_size)
							// die "Can't read part#$num_in_file of file $filepath: $!" });
						prof_run(read_file => undef, length($part_body));
						
						my $sha512 = prof_run(sha512 => sub { sha512_base64($part_body) }, length($part_body));
						$sha512 =~ s{/}{-}g;
						print "$sha512\t";
						
						# Если такая часть есть в БД, значит она и в хранилище есть, просто будем использовать её метаинфу
						my($packed_size, $block_id) = prof_run(db_select_part_by_hash => sub {
							$dbh->selectrow_array("SELECT packed_size, block_id FROM file_parts
								WHERE sha512 = ? AND size_type = ?", undef, $sha512, $size_type)
						});
						if($packed_size) {
							print "dup in block#$block_id\n";
						}
						# А если нету, то: сжимаем, шифруем, заливаем в хранилище попутно считая вес сжатого
						else {
							
							my $weight_stored_cmd = ssh_cmd("stat --format=%s $CONFIG->{destination}->{path}/$size_type/$sha512 2>/dev/null");
								
							# Освободим столько места, сколько в почти худшем случае займёт эта часть
							while($total_weight + $part_size > $WEIGHT_LIMIT) {
								$total_weight -= prof_run(free_space => \&free_space);
							}
							
							# Тут можно было бы прямо в коде обслуживать потоки ввода-вывода всех этих процессов, а заодно и более эффективно передавать файлы с заметно меньшей задержкой на каждый файл.
							# В предыдущей версии так и было. Но нынешняя реализация проще, а значит лучше.
							prof_run(part_proc => sub {
								local $?;
								
								my $cmd = "| $CONFIG->{data_proc_before_store_cmd} | "
									.ssh_cmd("cat >$CONFIG->{destination}->{path}/$size_type/$sha512");
								open(my $h, $cmd) or die "Can't proc file part (cmd $cmd): $!";
								print($h $part_body) or die "Processing or storing file ($size_type/$sha512) failed: $!";
								close($h);
								die "Processing or storing file ($size_type/$sha512) failed!" if $?;
								
								$packed_size = `$weight_stored_cmd`;
								die "Weighting stored file ($size_type/$sha512) failed!" if $?;
								chomp $packed_size;
							}, $part_size);
							
							print "processed & stored\n";
							
							$total_weight += $packed_size;
							$weight_added += $packed_size;
							
						}
						
						push @new_file_parts, {
							backup_num	=> $backup_num,
							filepath	=> $filepath,
							num_in_file	=> $num_in_file,
							sha512		=> $sha512,
							size_type	=> $size_type,
							packed_size	=> $packed_size,
							block_id	=> $block_id,
						};
					}
				} else {
					warn report(warn => "Can't read '$filepath': $!");
					print "read failed\n";
				}
			}
			
			
			if(@new_file_parts) {
				# Если есть части, для которых ещё не определён блок
				if(grep {! defined $_->{block_id}} @new_file_parts) {
					# Если хотя бы для одной части данного файла определён блок, остальные части должны быть в нём
					# Это удовлетворяет обоим правилам нахождения части в блоке:
					#	1. Части одного файла внутри одного бекапа не могут быть в разных блоках
					#	2. Части одного типоразмера с одним sha512 не могут быть в разных блоках
					if(my($first_defined_block_id) = map {$_->{block_id}} grep {defined $_->{block_id}} @new_file_parts) {
						$_->{block_id} //= $first_defined_block_id foreach @new_file_parts;
						print "\tadd to old block#$first_defined_block_id";
					}
					# Если же блок не определён для всех частей файла, придётся создавать новый 
					else {
						prof_run(db_add_blocks => sub {
							$dbh->do("INSERT INTO file_parts_blocks (last_backup_num, weight, priorities, value)
								VALUES (?, 0, 0, 0)", undef, $backup_num, 0, 0)
						});
						my $new_block_id = $dbh->sqlite_last_insert_rowid();
						$_->{block_id} = $new_block_id foreach @new_file_parts;
						print "\tadd to new block#$new_block_id";
					}
				}
				
				{ # Если блоки выпали разные (например, какая-то часть файла начала совпадать с частью другого файла),
				# то нарушается правило на счёт неделимости файла. И тогда надо объединять блоки.
					my %block_ids = map {$_->{block_id} => undef} @new_file_parts;
					if(keys(%block_ids) > 1) {
						my($acceptor_block, @donor_blocks) = keys %block_ids;
						
						prof_run(db_merge_blocks => sub {
							my($weight, $priorities, $value) = $dbh->selectrow_array("SELECT sum(weight), sum(priorities), sum(value)
								FROM file_parts_blocks WHERE rowid IN(".join(',', map {'?'} @donor_blocks).")",
								undef, @donor_blocks);
							
							$dbh->do("UPDATE file_parts_blocks SET weight = ?, priorities = ?, value = ? WHERE rowid = ?",
								undef, $weight, $priorities, $value, $acceptor_block);
							$dbh->do("DELETE FROM file_parts_blocks WHERE rowid IN(".join(',', map {'?'} @donor_blocks).")",
								undef, @donor_blocks);
							$dbh->do("UPDATE file_parts SET block_id = ? WHERE block_id IN(".join(',', map {'?'} @donor_blocks).")",
								undef, $acceptor_block, @donor_blocks);
						});
						
						$_->{block_id} = $acceptor_block foreach @new_file_parts;
					}
				}
				
				
				# записываем в БД инфу об этой части (от какого файла, какой sha512, какой № части, size_type и сжатый вес
				# (для расчёта стоимости))
				{
					my @fields = keys %{$new_file_parts[0]};
					my @values;
					foreach my $new_file_part (@new_file_parts) {
						push @values, map { $new_file_part->{$_} } @fields;
					}
					prof_run(db_add_parts => sub {
						$dbh->do("INSERT INTO file_parts (".join(', ', map { $dbh->quote_identifier($_) } @fields).") VALUES
							".join(",\n", ('('.join(', ', ('?') x @fields).')') x @new_file_parts),
							undef, @values)
					});
				}
				
				print "\t(+$weight_added weight, +$priorities_added priority, =$backup_num last_backup_num)\n";
				prof_run(db_upd_blocks => sub {
					$dbh->do("UPDATE file_parts_blocks
						SET weight = weight + ?, priorities = priorities + ?, last_backup_num = ?
						WHERE rowid = ?", undef, $weight_added, $priorities_added, $backup_num, $new_file_parts[0]->{block_id}
					);
					$dbh->do("UPDATE file_parts_blocks SET value = $FILE_PARTS_BLOCK_VALUE_FORUMULA_SQL 
						WHERE rowid = ?", undef, $backup_num, $new_file_parts[0]->{block_id});
				});
			}
		}
		else {
			print "\tempty\n";
		}
		
	} else {
		warn report(warn => "Unknown file mode $stat[2] of file $filepath, skipped.");
	}
	
	my $file_id;
	{ # save file to db
		my @f = keys %file;
		prof_run(db_add_file => sub { $dbh->do("INSERT INTO files (".join(', ', map {$dbh->quote_identifier($_)} @f).")
			VALUES (".join(', ', map {'?'} @f).')', undef, map { $file{$_} } @f) });
		$file_id = $dbh->sqlite_last_insert_rowid();
	}
	
	$dbh->{AutoCommit} = 1 if $CONFIG->{low_memory};
	
	$_->[2] = $file_id foreach @next;
	return @next;
}


sub usage {
	print @_ if @_;
	print "Usage: backuper <configfile> <backup_name>\n";
	exit -1;
}


use JSON::PP;
use Try::Tiny;
use Data::Dumper;
sub init_config {
	my($filepath) = @_;
	open(my $fh, '<', $filepath) or usage "Can't read file '$filepath': $!";
	my $CONFIG = join('', <$fh>);
	close($fh);
	try {
		$CONFIG = JSON::PP->new()
			->relaxed(1)
			->allow_singlequote(1)
			->allow_barekey(1)
			->utf8(1)
			->decode($CONFIG)
			;
	} catch {
		usage "Can't parse config: $_";
	};
	
	return $CONFIG;
}

use DBI;
sub init_dbh {
	$dbh = DBI->connect("dbi:SQLite:".($CONFIG->{low_memory} ? $DB_FILE : ':memory:'), "", "", {
		RaiseError => 1,
		HandleError=> sub {
			my($error_msg, $hdl, $failed) = @_;
			croak $error_msg.($hdl->{Statement} ? "; statement $hdl->{Statement}" : '');
		},
	});
	
	$dbh->sqlite_backup_from_file($DB_FILE) if ! $CONFIG->{low_memory} and -e $DB_FILE;
	
	$dbh->do("CREATE TABLE IF NOT EXISTS `backups` ( `name` TEXT NOT NULL, PRIMARY KEY(`name`) )");
	$dbh->do("CREATE TABLE IF NOT EXISTS `files` (
		`parent_id`		INTEGER NOT NULL,
		`backup_num`	INTEGER NOT NULL,
		`filepath`		TEXT NOT NULL,
		`mode`			INTEGER NOT NULL,
		`size`			INTEGER NOT NULL,
		`user`			TEXT NOT NULL,
		`group`			TEXT NOT NULL,
		`atime`			INTEGER NOT NULL,
		`mtime`			INTEGER NOT NULL,
		`ctime`			INTEGER NOT NULL,
		`symlink_to`	TEXT,
		PRIMARY KEY(`filepath`,`backup_num`)
	)");
	$dbh->do("CREATE INDEX IF NOT EXISTS `parent_id` ON `files` (`parent_id` ASC)");
	$dbh->do("CREATE TABLE IF NOT EXISTS `file_parts` (
		`backup_num`	INTEGER NOT NULL,
		`filepath`		TEXT NOT NULL,
		`num_in_file`	INTEGER NOT NULL,
		`sha512`		TEXT NOT NULL,
		`size_type`		TEXT NOT NULL,
		`packed_size`	INTEGER NOT NULL,
		`block_id`		INTEGER NOT NULL,
		PRIMARY KEY(`backup_num`,`filepath`,`num_in_file`)
	)");
	$dbh->do("CREATE INDEX IF NOT EXISTS `sha512_size_type` ON `file_parts` (`sha512` ASC,`size_type` ASC)");
	$dbh->do("CREATE TABLE IF NOT EXISTS `file_parts_blocks` (
		`last_backup_num`	INTEGER NOT NULL,
		`weight`			INTEGER NOT NULL,
		`priorities`		INTEGER NOT NULL,
		`value`				INTEGER NOT NULL
	)");
	
	return $dbh;
}

sub report {
	my($level, $msg) = @_;
	push @{ $report{$level} }, $msg;
	return $msg."\n";
}

sub free_space {
	# находим блок частей минимальным value
	my($worst_block_id, $weight) = $dbh->selectrow_array("SELECT rowid, weight FROM file_parts_blocks ORDER BY value LIMIT 1"); # TODO: не выбирать блоки с last_backup_num = текущий
	die "Nothing to delete for freeing space!" if ! $worst_block_id;
	
	printf "(del block#%d total weight (%d/%d) -%db) ", $worst_block_id, $total_weight, $WEIGHT_LIMIT, $weight;
	
	# удаляем все части блока с диска, из БД и сам блок из БД
	my($file_parts) = $dbh->selectall_arrayref("SELECT * FROM file_parts WHERE block_id = ?", {Slice=>{}}, $worst_block_id);
	foreach my $file_part ( @$file_parts ) {
		my $cmd = ssh_cmd("rm $CONFIG->{destination}->{path}/$file_part->{size_type}/$file_part->{sha512}");
		print `$cmd`;
		die "Deleting $file_part->{size_type}/$file_part->{sha512} failed!" if $?;
		
		$dbh->do("DELETE FROM file_parts WHERE size_type = ? AND sha512 = ?", undef, $file_part->{size_type}, $file_part->{sha512});
		$dbh->do("DELETE FROM files WHERE backup_num = ? AND filepath = ?", undef, $file_part->{backup_num}, $file_part->{filepath});
	}
	$dbh->do("DELETE FROM file_parts_blocks WHERE rowid = ?", undef, $worst_block_id);
	
	return $weight;
}

sub print_report {
	
	print "Times:\n";
	print "   total     avg    cnt      Mb/s   what\n";
	foreach my $key (sort {$report{time}->{$b} <=> $report{time}->{$a}} grep {$_ !~ /_(cnt|bytes)$/} keys %{ $report{time} }) {
		printf "% 10.3f ", $report{time}->{$key};
		if($report{time}->{$key.'_cnt'}) {
			printf "% 5.3f % 7d ", $report{time}->{$key} / $report{time}->{$key.'_cnt'}, $report{time}->{$key.'_cnt'};
		} else {
			print "              ";
		}
		if($report{time}->{$key.'_bytes'}) {
			printf "% 9.3f ", $report{time}->{$key.'_bytes'} / $report{time}->{$key} / 1024 / 1024;
		} else {
			print "          ";
		}
		print "$key\n";
	}
	
	$last_report_print = time;
}

sub prof_run {
	my($name, $code_ref, $bytes_cnt) = @_;
	
	my @result;
	if($code_ref) {
		$report{time}->{$name} -= time;
		if(wantarray) {
			@result = $code_ref->();
		} else {
			$result[0] = $code_ref->();
		}
		$report{time}->{$name} += time;
		$report{time}->{$name.'_cnt'}++;
	}
	$report{time}->{$name.'_bytes'} += $bytes_cnt if defined $bytes_cnt;
	
	return wantarray ? @result : $result[0];
}

sub ssh_cmd {
	my($cmd) = @_;
	if(exists $CONFIG->{destination}->{host}) {
		return "ssh $CONFIG->{destination}->{host} '$cmd'";
	} else {
		return $cmd;
	}
}

sub prepare_storage {
	print "prepare storage:\n";
	my $cmd = ssh_cmd("mkdir -p ".join(' ', map {"$CONFIG->{destination}->{path}/$_"} keys %SIZE_TYPE));
	print `$cmd`;
	my $size_types = join('|', keys %SIZE_TYPE);
	$cmd = ssh_cmd('find -H '.$CONFIG->{destination}->{path}.' -printf "%P\\n"');
	foreach my $file ( split /\n/, `$cmd` ) {
		next if ! ~index($file, '/');
		my $delete = 1;
		if($file =~ /^($size_types)\/([^\/]{86})$/) {
			my($cnt) = $dbh->selectrow_array("SELECT count(*) FROM file_parts WHERE size_type = ? AND sha512 = ?",
				undef, $1, $2);
			$delete = 0 if $cnt;
		}
		if($delete) {
			warn report(error => "Extra file found in storage: $file. Deleting");
			my $cmd = ssh_cmd("rm -rf $CONFIG->{destination}->{path}/$file");
			`$cmd`;
		}
	}
	print "done\n";
}
