
zfs-replicate.sh
================

Simple script to replicate zfs volumes between hosts (or between pools on the same host) via incremental snapshots.

Warning
-------

Replicating a root dataset to a remote will rewrite the remote pool with forced replication.  This script will create
a true 1:1 copy of the source (local) dataset in the destination (remote) dataset as currently configured.

The configuration ```REPLICATE_SETS="zpoolone:zpooltwo"``` will result in ```zpooltwo``` being a 1:1 copy of ```zpoolone```
and may result in dataloss on ```zpooltwo```.

To replicate a root dataset safely to another pool consider this configuration: ```REPLICATE_SETS="zpoolone:zpooltwo/zpoolone"```

This will result in a 1:1 copy of ```zpoolone``` in a separate data set of ```zpooltwo``` and will not affect other datasets currently present on the destination.

To Use
------

Configuration is done via a separate file that should be passed to the script on execution.  The script will attempt to locate a file called ```config.sh``` if one is not passed via the command line.

The file is very well commented and the contents of the sample config are shown below.

```bash
## datasets to replicate - use zfs paths not mount points...
## format is local_pool/local_fs:remote_pool or
## local_pool/local_fs:remote_pool/remote_fs the local name
## will be used on the remote end if not specified
REPLICATE_SETS="zpoolone/somefs:zpooltwo zpoolone/otherfs:zpooltwo"

## allow replication of root datasets - if you specify root
## datasets above and do not toggle this setting the
## script will generate a warning and skip replicating
## root datasets
## 0 - disable (default)
## 1 - enable (use at your own risk)
ALLOW_ROOT_DATASETS=0

## option to recurrsively snapshot children of
## all datasets listed above
## 0 - disable (previous behavior)
## 1 - enable
RECURSE_CHILDREN=0

## number of snapshots to keep of each dataset
## snaps in excess of this number will be expired
## oldest deleted first...must be 2 or greater
SNAP_KEEP=2

## number of logs to keep in path ... logs will be
## deleted in order of age with oldest going first
LOG_KEEP=10

## where to place log files and temporary lock files
LOGBASE=/root/logs

## path to zfs binary
ZFS=/sbin/zfs

## path to GNU find binary
##
## solaris `find` does not support the -maxdepth option, which is required
## on solaris 11, GNU find is typically located at /usr/bin/gfind
FIND=/usr/bin/find

## ip address or hostname of a remote server
## this variable may be referenced in the
## additional settings below
##
## this should not be used for local replication
## and could be commented out and ignored
REMOTE_SERVER="192.168.100.2"

## command to check health of remote host
## a return code of 0 will be considered OK
##
## this is not used for local replication
## and could be commented out and ignored
REMOTE_CHECK="ping -c1 -q -W2 ${REMOTE_SERVER}"

## command for contacting the remote host
## ssh shown below with enumerated ciphers for incraesed
## transfer speed - adjust as needed or comment out for local
## transfer without a remote system
REMOTE_CMD="ssh -c arcfour256,arcfour128,blowfish-cbc,aes128-ctr,aes192-ctr,aes256-ctr ${REMOTE_SERVER}"

## zfs receive command with arguments
## sending is calculated by logic within the script
RECEIVE_CMD="${ZFS} receive -vFd"

## mbuffer command - comment out if not used
## see the following links for more information
## http://everycity.co.uk/alasdair/2010/07/using-mbuffer-to-speed-up-slow-zfs-send-zfs-receive/
## https://dan.langille.org/2014/05/03/zfs-send-on-freebsd-over-ssh-using-mbuffer/
MBUFFER_CMD="mbuffer -s 128k -m 1G"

## get the current date info
DOW=$(date "+%a")
MOY=$(date "+%m")
DOM=$(date "+%d")
NOW=$(date "+%s")
CYR=$(date "+%Y")

## snapshot and log name tags
## ie: pool0/someplace@autorep-${NAMETAG}
NAMETAG="${MOY}${DOM}${CYR}_${NOW}"

## the log file...you need to prepend with
## autorep- in order for log cleanup to work
## using the default below is strongly suggested
LOGFILE="${LOGBASE}/autorep-${NAMETAG}.log"
```

Notes
-----

This script has been used by myself and others for well over a year, however as they say YMMV (your mileage may vary).

If you use it, let me know, also please report issues via GitHub so this may be improved.
