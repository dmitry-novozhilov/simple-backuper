#!/usr/bin/perl

use strict;
use warnings;
use Readonly;
use Carp;
use DBI;
use Data::Dumper;
use Getopt::Long;
use Fcntl ':mode';

GetOptions(\my %ARGS, 'db=s', 'from=s', 'to=s', 'name=s', 'restore', 'storage-path=s', 'proc-cmd=s') or usage();
Readonly %ARGS => %ARGS;

usage("Option 'db' is required\n") if ! exists $ARGS{db};
my $dbh = DBI->connect("dbi:SQLite:$ARGS{db}", "", "", { RaiseError => 1, HandleError => sub { croak "$_[0]; statement $_[1]->{Statement}" } });

Readonly my %BACKUPS => map {@$_} $dbh->selectcol_arrayref("SELECT rowid, name FROM backups", {Columns=>[1,2]});
Readonly my $BACKUP_NUM => exists $ARGS{name}
	? ((grep {$BACKUPS{$_} eq $ARGS{name}} keys %BACKUPS)[0]) || usage("Backup named '$ARGS{name}' wasn't found!\n")
	: undef
	;

my $file_info;
if($ARGS{from}) {
	($file_info) = $dbh->selectrow_hashref("SELECT rowid, * FROM files
		WHERE filepath = ?".($BACKUP_NUM ? " AND backup_num = $BACKUP_NUM" : ''), undef, $ARGS{from});
	die "Path '$ARGS{from}' wasn't found in ".($BACKUP_NUM ? 'this backup' : 'all backups') if ! $file_info;
}

my $subfiles = listing($file_info ? $file_info->{rowid} : 0);
my $max_subfile_length = 0;
$max_subfile_length = length($_->{filepath}) > $max_subfile_length ? length($_->{filepath}) : $max_subfile_length foreach @$subfiles;

print join('/', map {print_fs_name($_)} split(/\//, $ARGS{from} || '<roots>', -1));
print ''.($BACKUP_NUM ? " (in backup '$ARGS{name}'):" : ":	oldest backup .. newest backup")."\n";
foreach my $subfile ( @$subfiles ) {
	printf "% ".$max_subfile_length."s".($BACKUP_NUM ? '' : "\t%s .. %s")."\n",
		join('/', map {print_fs_name($_)} split(/\//, $subfile->{filepath})),
		$BACKUP_NUM ? () : ($BACKUPS{$subfile->{min_backup_num}}, $BACKUPS{$subfile->{max_backup_num}}),
		;
}

if($ARGS{to}) {
	
	if($BACKUP_NUM) {
		
		if($ARGS{restore}) {
			usage("Please specify a storage path\n") if ! $ARGS{'storage-path'};
			usage("Please specify a process cmd\n") if ! $ARGS{'proc-cmd'};
			
			my $fetch_cmd; {
				my(@storage_path) = split(/:/, $ARGS{'storage-path'}, 2);
				$fetch_cmd = "cat ".pop(@storage_path);
				$fetch_cmd = join(' ', ssh => @storage_path, $fetch_cmd) if @storage_path;
			}
			
			print "Starting restoring from '$ARGS{from}' of backup '$ARGS{name}' to '$ARGS{to}'\n";
			
			my @next = ($file_info, $ARGS{to});
			
			while(@next) {
				
				my $from = shift @next;
				my $to = shift @next;
				
				print "$to ";
				
				if(S_ISDIR $from->{mode}) {
					mkdir($to) or -d $to or die "Can't mkdir '$to': $!";
					
					foreach my $sub_file_info ( map {@$_} listing($from->{rowid}) ) {
						my($filename) = $sub_file_info->{filepath} =~ /([^\/]+)\/?$/;
						push @next, $sub_file_info, "$to/$filename";
					}
				}
				elsif(S_ISLNK $from->{mode}) {
					unlink($to) or die "Can't remove symlink before restore it: $!" if -e $to;
					symlink($from->{symlink_to}, $to) or die "Can't create symlink '$to' to '$from->{symlink_to}': $!";
				}
				elsif(S_ISREG $from->{mode}) {
					my $parts = $dbh->selectall_arrayref("SELECT * FROM file_parts WHERE backup_num = ? AND filepath = ?
						ORDER BY num_in_file", {Slice=>{}}, $BACKUP_NUM, $from->{filepath});
					
					open(my $sh, ">", $to) or die "Can't write to '$to': $!";
					foreach my $part (@$parts) {
						my $cmd = "$fetch_cmd/$part->{size_type}/$part->{sha512} | $ARGS{'proc-cmd'}";
						open(my $fh, "$cmd |")
							or die "Can't fetch & proc file '$from->{filepath}' part # $part->{num_in_file} via command '$cmd': $!";
						print $sh (<$fh>);
						close($fh);
						print '.';
					}
					close($sh);
				}
				else {
					die "Unknown file '$from->{filepath}' mode $from->{mode}";
				}
				
				chmod($from->{mode} & 07777, $to) or die "Can't chmod '$to': $!";
				my $uid = getpwnam($from->{user}) or die "Can't chown to user '$from->{user}': user doesn't exists";
				my $gid = getgrnam($from->{group}) or die "Can't chown to group '$from->{group}': group doesn't exists";
				chown($uid, $gid, $to) or die "Can't chown '$to' to $from->{user}:$from->{group}: $!";
				
				print "\n";
			}
		}
	}
}



exit;

sub usage {
	print @_ if @_;
	print <<USAGE;
Usage: restore --db=path/to/db/file [--from path/in/backup [--name backup_name [--restore --to path/in/filesystem --storage-path host:path --proc-cmd 'cmd']]
	--db           - path to file with database (decrypted!). In config it's in 'db_file' key.
		           It because in situation without data and with backup you have database and you have no config.
	--from         - source path in the backup. Default is /.
	--name         - name of the backup (you can got it in files listing).
	--restore      - do start recovering.
	--to           - destination path in the local file system.
	--storage-path - for local backup storage is path to it. For remote backup storage is ssh-host:path.
	--proc-cmd     - command to process data from storage (must getting data to STDIN and putting result to STDOUT).
	               (for example: 'gpg --decrypt 2>/dev/null | xz --decompress')
USAGE
	exit -1;
}

sub print_fs_name {
	my $text = shift;
	$text =~ s{([ \\'])}{\\$1}g;
	return $text;
}

sub listing {
	return $dbh->selectall_arrayref("SELECT rowid, *, min(backup_num) AS min_backup_num, max(backup_num) AS max_backup_num
		FROM files WHERE parent_id = ? GROUP BY filepath", {Slice=>{}}, shift);
}
