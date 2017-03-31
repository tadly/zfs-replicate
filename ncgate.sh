#!/bin/bash
#
#   Send stdin via netcat to some target
#   This is an UNENCRYPTED stream, use with caution!
#
#   This script will ssh to the target to start a netcat
#   server to than send the data.
#

COMMAND=""
TARGET=""
PORT=2222

usage() {
    printf "usage: $0 -t [user@target] -c [command] -p [port [2222]]\n"
    printf "  -t  target ip/host\n"
    printf "  -c  command used to handle receiving data (data will be piped into it)\n"
    printf "      e.g. \"> /tmp/file\" would create a file containing the sent content.\n"
    printf "  -p  port used to start the remote server\n"
    printf "\n\n"
    printf "Examples\n"
    printf "========\n"
    printf "Sending a file:\n"
    printf "  $0 -t <target> -c \"> /tmp/test.file\" < /tmp/test.file\n"
    printf "\n"
    printf "Sending/Receiving a zfs snapshot:\n"
    printf "  zfs send tank/dana@snap1 | $0 -t <target> -c \"| zfs recv newtank/dana\"\n"

}
while [ $# -gt 0 ]; do
    case $1 in
        "-t")
            TARGET="$2"
            ;;
        "-p")
            PORT="$2"
            ;;
        "-c")
            COMMAND="$2"
            ;;
        **)
            usage
            exit 1
            ;;
    esac

    shift;shift
done

if [ -z "${COMMAND}" ] || [ -z "${TARGET}" ] || [ -z "${PORT}" ]; then
    usage
    exit 1
fi

REMOTE_LOG="/tmp/${0}-server.log"
REMOTE_CODE="/tmp/${0}-server.code"

printf "Spawning remote server...\n"
(ssh ${TARGET} "nc -l ${PORT} ${COMMAND} 2>&1" > "${REMOTE_LOG}"; echo $? > "${REMOTE_CODE}") &
pid=$!

printf "Server running with pid: ${pid}\n"
sleep 1.5

printf "Sending data...\n"
cat - | nc -N ${TARGET} ${PORT}
sleep 1.5

# remote output
if [ -f "${REMOTE_LOG}" ]; then
    log=$(cat "${REMOTE_LOG}")
    rm "${REMOTE_LOG}"
fi

# remote exit code
if [ -f "${REMOTE_CODE}" ]; then
    code=$(cat "${REMOTE_CODE}")
    rm "${REMOTE_CODE}"
fi

if [ $code != 0 ]; then
    printf "$log\n" 1>&2
else
    printf "$log\n"
fi

exit $code
