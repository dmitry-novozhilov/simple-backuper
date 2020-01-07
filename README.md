# What's this
**Simple-backuper** is a few short plain scripts just for backuping files and restoring it from backups.

# Benefits
- Simplicity and transparency. One short and plain script for each task. Most programmers can understand it.
- Efficient use of disk space (incremental backup):
  - Automatic deduplication of parts of files (most modified files differ only partially).
  - All files can be compressed with archivator (compression program and options may be configured).
  - Incremental backup format doesn't require initial data snapshot.
- Security:
  - All files can be encrypted with any crypt program (ex: gpg).
  - Encryption doing before data send to storage host.
  - You can chose crypt algorythm, requires additional secret for decrypting (see [Installing](#installing)).
- You can specify different priorities for any files.
- For recover your backup you need only: access to storage host, your crypting keys and some backup options (see [Backuping](#backuping)).
- Requires on storage host: ssh-server with support of standard commands (cat, mkdir, rm, etc...).
- Requires on backuper host: perl, ssh-client, your favorite compress and crypt program (any linux distribution supports it, and cygwin too!).

# Installing

- Get a code: `git clone https://github.com/dmitry-novozhilov/simple-backuper.git`
- If you want to use gpg encryption, you need to create key: `gpg --full-generate-key` (but gpg4win configuring via GUI).
- Create config file like this and save in somewhere on disk (ex: `~/.simple-backuper.conf.json`):
```javascript
{
	// Where to be placed database file.
	db_file:		"~/path/to/database-with-metainfo-about-backuped-files.db",
	// Command to prepare data to store.
	// It must fetch source data in stdin and put ready-to-store data to stdout.
	data_proc_before_store_cmd: "xz --compress -9 --stdout --memlimit=1GiB | gpg --encrypt -z 0 --recipient YOUR_KEY_NAME_HERE",
	// If backup fails with memory error. But with this option backup will be longer time.
	// "low_memory": 1,
	// Paths to backup with priorities.
	// For equal other conditions, files with a higher priority will be stored longer.
	// Zero priority deprecate to backup files.
	source: {
		// For example:
		"~":					5,
		"~/docs":				20,
		"~/.cache":				0,
		"~/.local/share/Trash":	0,
		"~/.thumbnails":		0,
	},
	// Where to store backups
	destination: {
		// It's optional. Without this option backups will be stored to path on local machine.
		// Ssh client must be configured to login on this ssh server by private key without password, because this name will be used in ssh commands.
		// And for speedup uploading many little files from linux machine you can configure ControlMaster, ControlPersist and ControlPath in ssh client.
		host: 'my-backup-ssh-server',
		// Where to place backup data
		path: '~/backup/',
		// Disk usage limit in Gb
		weight_limit_gb: 1000,
	},
}
```
- Example `~/.ssh/config`, if you need:
```
Host my-backup-ssh-server
  Hostname 1.2.3.4
  ControlMaster auto
  ControlPersist 1m
  ControlPath /tmp/ssh-control-master/%r@%h:%p
```
- Backup manually a gpg keys, if you use gpg encryption!

# Backuping
- Create initial backup:
  - `perl ./backuper.pl ~/.simple-backuper.conf.json initial`
  - `~/.simple-backuper.conf.json` - is a path to your config;
  - `initial` - is a name of first backup;
  - Initial backup will take a lot of time.
- Make a cron job (`crontab -e`) like this:
```
0 2 * * * perl /path/to/simple-backuper/backuper.pl /path/to/your-config.conf.json `date -Idate`
```
# Recovering
- Ensure a gpg key aviability if you using gpg encryption.
- Install backuper if your machine have not it (see [Installing](#installing)).
- Configore ssh client for access by private key without password.
- Download from storage host a database. It placed to file `db` in backup path.
(ex: `scp my-backup-ssh-server:backup/db ./simple-backuper.db`)
- Decrypt or/and decompress a database if you use encryption or/and compression. (ex: `mv ./simple-backuper.db ./simple-backuper.db.xz.enc; gpg --decrypt ./simple-backuper.db.xz.enc | xz --decompress > ./simple-backuper.db`)
- List the backup content: `perl ./restore.pl --db ./simple-backuper.db`
- You can chose any folder in backups for listing or for restoring ny specifying `--from`: `perl ./restore.pl --db ./simple-backuper.db --from YOUR_PATH`
- Select one of backup dirs
- Start restoring: `pelr ./restore.pl --db ./simple-backuper.db --from YOUR_PATH --name BACKUP_NAME --restore --to PATH_ON_LOCAL_FILESYSTEM --storage-path my-backup-ssh-server:backup --proc-cmd 'gpg --decrypt 2>/dev/null | xz --decompress'`

# Setup on cygwin
- Install cygwin packages `git`, `xz` and `perl-Text-Glob`.
- If you will using gpg, install gpg4win (you can find link on official gnupg site: https://gnupg.org/download/index.html).  
When recovering you must serve running "kleopatra" - is a part of gpp4win.

