#!/usr/bin/env bash
## zfs-replicate.sh
## file revision $Id$
##
## Exit codes:
##  0 Success (obviously)
##  1 No config given
##  2 Sanity check failed (snap keep count below 2)
##  3 lock exists
##  4 Remote health check failed
##  5 zfs snapshot failed
##  10 partial success
##

############################################
##### warning gremlins live below here #####
############################################

## check log count and delete old
check_old_log() {
    ## declare log array
    declare -a logs=()
    ## initialize index
    local index=0
    ## find existing logs
    for log in $(${FIND} ${LOGBASE} -maxdepth 1 -type f -name autorep-\*); do
        ## get file change time via stat (platform specific)
        case "$(uname -s)" in
            Linux|SunOS)
                local fstat=$(stat -c %Z ${log})
            ;;
            *)
                local fstat=$(stat -f %c ${log})
            ;;
        esac
        ## append logs to array with creation time
        logs[$index]="${fstat}\t${log}\n"
        ## increase index
        let "index += 1"
    done
    ## set log count
    local lcount=${#logs[@]}
    ## check count ... if greater than keep loop and delete
    if [ $lcount -gt ${LOG_KEEP} ]; then
        ## build new array in descending age order and reset index
        declare -a slogs=(); local index=0
        ## loop through existing array
        for log in $(echo -e ${logs[@]:0} | sort -rn | cut -f2); do
            ## append log to array
            slogs[$index]=${log}
            ## increase index
            let "index += 1"
        done
        ## delete excess logs
        printf "deleting old logs: %s ...\n" "${slogs[@]:${LOG_KEEP}}"
        rm -rf ${slogs[@]:${LOG_KEEP}}
    fi
}

## delete old log files and exit
exit_clean() {
    ## check log files
    check_old_log

    ## clear our lockfile
    clear_lock "${LOGBASE}/.snapshot.lock"
    clear_lock "${LOGBASE}/.send.lock"

    ## exit with the code given or 0 if empty
    printf "Exiting...\n"
    if [ -z ${1} ]; then
        exit 0
    else
        exit ${1}
    fi
}

## lockfile creation and maintenance
check_lock () {
    ## check our lockfile status
    if [ -f "${1}" ]; then
        ## get lockfile contents
        local lpid=$(cat "${1}")
        ## see if this pid is still running
        local ps=$(ps auxww|grep $lpid|grep -v grep)
        if [ "${ps}x" != 'x' ]; then
            ## looks like it's still running
            printf "ERROR: This script is already running as: %s\n" "${ps}" 1>&2
        else
            ## well the lockfile is there...stale?
            printf "ERROR: Lockfile exists: %s\n" "${1}" 1>&2
            printf "However, the contents do not match any " 1>&2
            printf "currently running process...stale lockfile?\n" 1>&2
        fi
        ## tell em what to do...
        printf "To run script please delete: %s\n" "${1}" 1>&2
        ## compress log and exit...
        exit_clean 3
    else
        ## well no lockfile..let's make a new one
        printf "Creating lockfile: %s\n" "${1}"
        echo $$ > "${1}"
    fi
}

## delete lockiles
clear_lock() {
    ## delete lockfiles...and that's all we do here
    if [ -f "${1}" ]; then
        printf "Deleting lockfile: %s\n" "${1}"
        rm "${1}"
    fi
}

## check remote system health
check_remote() {
    ## do we have a remote check defined
    if [ ! -z "${REMOTE_CHECK}" ]; then
        ## run the check
        $REMOTE_CHECK > /dev/null 2>&1
        ## exit if above returned non-zero
        if [ $? != 0 ]; then
            printf "ERROR: Remote health check '%s' failed!\n" "${REMOTE_CHECK}" 1>&2
            exit_clean 4
        fi
    fi
}

## main replication function
do_send() {
    ## check our send lockfile
    check_lock "${LOGBASE}/.send.lock"
    ## create initial send command based on arguments
    ## if first snapname is NULL we do not generate an inremental
    if [ "${1}" == "NULL" ]; then
        local sendargs="-R"
    else
        local sendargs="-R -I ${1}"
    fi
    local command=$(printf "${RECEIVE_PIPE}" "${3}")
    printf "Sending snapshots...\n"
    printf "RUNNING: %s send %s %s | %s\n" "${ZFS}" "${sendargs}" "${2}" "${command}"
    ${ZFS} send ${sendargs} ${2} | eval ${command}
    ## get status
    local send_status=$?
    ## clear lockfile
    clear_lock "${LOGBASE}/.send.lock"
    ## return status
    return ${send_status}
}

## small wrapper around zfs destroy
do_destroy() {
    ## get file set argument
    local snapshot="${1}"
    ## check settings
    if [ $RECURSE_CHILDREN -ne 1 ]; then
        local destroyargs=""
    else
        local destroyargs="-r"
    fi
    ## call zfs destroy
    ${ZFS} destroy ${destroyargs} ${snapshot}
}

## create and manage our zfs snapshots
do_snap() {
    ## make sure we aren't ever creating simultaneous snapshots
    check_lock "${LOGBASE}/.snapshot.lock"
    ## set our snap name
    local sname="autorep-${NAMETAG}"
    ## will be true if one of the sets doesn't succeed 
    local partial=false
    ## generate snapshot list and cleanup old snapshots
    for foo in $REPLICATE_SETS; do
        ## split dataset into local and remote parts and trim trailing slashes
        local local_set=$(echo $foo|cut -f1 -d:|sed 's/\/*$//')
        local remote_set=$(echo $foo|cut -f2 -d:|sed 's/\/*$//')
        ## check for root datasets
        if [ $ALLOW_ROOT_DATASETS -ne 1 ]; then
            if [ "${local_set}" == $(basename "${local_set}") ] && \
                [ "${remote_set}" == $(basename "${remote_set}") ]; then
                printf "WARNING: Replicating root datasets can lead to data loss.\n" 1>&2
                printf "To allow root dataset replication and disable this warning " 1>&2
                printf "set ALLOW_ROOT_DATASETS=1 in this script.  Skipping: %s\n\n" "${foo}" 1>&2
                partial=true
                ## skip this set
                continue
            fi
        fi
        ## get current existing snapshots that look like
        ## they were made by this script
        if [ $RECURSE_CHILDREN -ne 1 ]; then
            local temps=$($ZFS list -Hr -o name -s creation -t snapshot -d 1 ${local_set}|\
                grep "${local_set}\@autorep-")
        else
            local temps=$($ZFS list -Hr -o name -s creation -t snapshot ${local_set}|\
                grep "${local_set}\@autorep-")
        fi
        ## just a counter var
        local index=0
        ## our snapshot array
        declare -a snaps=()
        ## to the loop...
        for sn in $temps; do
            ## while we are here...check for our current snap name
            if [ "${sn}" == "${local_set}@${sname}" ]; then
                ## looks like it's here...we better kill it
                ## this shouldn't happen normally
                printf "Destroying DUPLICATE snapshot %s@%s\n" "${local_set}" "${sname}"
                do_destroy ${local_set}@${sname}
            else
                ## append this snap to an array
                snaps[$index]=$sn
                ## increase our index counter
                let "index += 1"
            fi
        done
        ## set our snap count and reset our index
        local scount=${#snaps[@]}; local index=0
        ## set our base snap for incremental generation below
        if [ $scount -ge 1 ]; then
            local base_snap=${snaps[$scount-1]}
        fi
        ## how many snapshots did we end up with..
        if [ $scount -ge $SNAP_KEEP ]; then
            ## oops...too many snapshots laying around
            ## we need to destroy some of these
            while [ $scount -ge $SNAP_KEEP ]; do
                ## snaps are sorted above by creation in
                ## ascending order
                printf "Destroying OLD snapshot %s\n" "${snaps[$index]}"
                do_destroy ${snaps[$index]}
                ## decrease scount and increase index
                let "scount -= 1"; let "index += 1"
            done
        fi
        ## come on already...make that snapshot
        printf "Creating ZFS snapshot %s@%s\n" "${local_set}" "${sname}"
        ## check if we are supposed to be recurrsive
        if [ $RECURSE_CHILDREN -ne 1 ]; then
            printf "RUNNING: %s snapshot %s@%s\n" "${ZFS}" "${local_set}" "${sname}"
            $ZFS snapshot ${local_set}@${sname}
        else
            printf "RUNNING: %s snapshot -r %s@%s\n" "${ZFS}" "${local_set}" "${sname}"
            $ZFS snapshot -r ${local_set}@${sname}
        fi
        ## check return
        if [ $? -ne 0 ]; then
            ## oops...that's not right
            local exit_code=$?
            printf "ERROR: Failed creating snapshot, " 1>&2
            printf "exited with: %s\n" "${exit_code}" 1>&2
            exit_clean 5
        fi
        ## send incremental if snap count 1 or more
        ## otherwise send a regular stream
        if [ $scount -ge 1 ]; then
            do_send ${base_snap} ${local_set}@${sname} ${remote_set}
        else
            do_send "NULL" ${local_set}@${sname} ${remote_set}
        fi
        ## check return of do_send
        if [ $? != 0 ]; then
            local exit_code=$?
            printf "ERROR: Failed to send snapshot %s@$%s\n" "${local_set}" "${sname}" 1>&2
            printf "send command exited with: %s\n" "${exit_code}" 1>&2
            printf "Deleting the local snapshot %s@$%s\n" "${local_set}" "${sname}" 1>&2
            do_destroy ${local_set}@${sname}
            partial=true
        fi
    done

    ## one or more failed
    if ${partial}; then
        exit_clean 10
    fi
}

## it all starts here...
init() {
    ## sanity check
    if [ $SNAP_KEEP -lt 2 ]; then
        printf "ERROR: You must keep at least 2 snaps for incremental sending.\n" 1>&2
        printf "Please check the setting of 'SNAP_KEEP' in the script.\n" 1>&2
        exit_clean 2
    fi
    ## check remote health
    printf "Checking remote system...\n"
    check_remote
    ## do snapshots and send
    printf "Creating snapshots...\n"
    do_snap
    ## that's it...sending called from do_snap
    printf "Finished all operations for ...\n"
    ## show a nice message and exit...
    exit_clean 0
}

## attempt to load configuration
if [ -f "${1}" ]; then
    ## source passed config
    printf "Sourcing configuration from %s\n" "${1}"
    source "${1}"
elif [ -f "config.sh" ]; then
    ## source default config
    printf "Sourcing configuration from config.sh\n"
    source "config.sh"
elif [ -f "$(dirname ${0})/config.sh" ]; then
    ## source script path config
    printf "Sourcing configuration from $(dirname ${0})/config.sh\n"
    source "$(dirname ${0})/config.sh"
else
    ## display error
    printf "ERROR: Cannot continue without a valid configuration file!\n" 1>&2
    printf "Usage: %s <config>\n" "${0}" 1>&2
    ## exit
    exit 1
fi

## make sure our log dir exits
mkdir -p "${LOGBASE}"

check_lock "${LOGBASE}/.zfs-replicate.lock"

## this is where it all starts
## we use tee and process substitution to
##  1. write informative message to stdout
##  2. write error message to stderr
##  3. write both, stdout and stderr to the logfile
init > >(tee "${LOGFILE}") 2> >(tee "${LOGFILE}" >&2)

clear_lock "${LOGBASE}/.zfs-replicate.lock"

