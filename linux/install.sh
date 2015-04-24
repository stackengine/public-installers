#!/usr/bin/env bash

TAB='  '
ECHO="/bin/echo -e "
HELP="
StackEngine Installation Script
    Environment Variables:
        CURL_OPTS           Pass flags to curl to use for proxy or outbound redirect.
        LEADER              Set the IP/hostname of the leader node to connect to.
        STACKENGINE_ARGS    Pass any other args to be set in the StackEngine config file.

    Flags:
        -leaderip=<IP/host> Explicitly define the leader's address.
        -follower           Designates the host as a member of leadership ring.
        -client             Designates the host as a dependent of the leadership ring.
        -bind=<IP>          IP attached to host to bind StackEngine controller to.
        -net=<eth device>   Network device attached to host to bind StackEngine controller to.
"

for ARG in $@; do
    [[ "${ARG}" =~ "-help" ]] && ${ECHO} "${HELP}" && exit 0
    [[ "${ARG}" =~ "-leaderip" ]] && LEADER="$(echo ${ARG} | cut -d'=' -f2)"
    [[ "${ARG}" =~ "-bind" || "${ARG}" =~ "-net" ]] && NIC=${ARG}
    [[ "${ARG}" == "-follower" ]] && MESH="join"
    [[ "${ARG}" == "-client" ]] && MESH="mesh"
done

# Variables used by installer
INSTALL_DIR=${INSTALL_DIR:-/usr/local/stackengine}
BINFILE=${INSTALL_DIR}/stackengine
#
LOG_DIR=${LOG_DIR:-/var/log/stackengine}
LOG_FILENAME="stackengine.log"
LOG_PATHNAME="${LOG_DIR}/${LOG_FILENAME}"

INSTALL_LOG="stackengine_install.log" && echo > ${INSTALL_LOG}

DATA_DIR=${DATA_DIR:-/var/lib/stackengine}
CONFIG_FILE="${DATA_DIR}/config"
COMPONENTS_FILE="${DATA_DIR}/templates.json"

# curl is used to fetch binary and md5 info
CURL_BIN=$(which curl)
CURL_OPTS=${CURL_OPTS}
CURL_ERROR_MSG="

May have failed due to firewall or proxy setup of your network.
If you are behind a proxy please set the HTTP_PROXY, HTTPS_PROXY,
and NO_PROXY environment variables as well as in the docker config.
curl accepts options passed by CURL_OPTS environment variable.

"

# md5sum is used to validate binary
MD5_BIN=$(which md5sum)
MD5_OPTS=
MD5_INFOFILE=/tmp/stackengine.md5

# validate access to curl(1)
[[ -z "${CURL_BIN}" ]] && Error 60 "unable to locate curl(1)"
# validate access to md5suml(1)
[[ -z "${MD5_BIN}" ]] && Error 62 "unable to locate md5sum(1)"

# urls to cool stuff
STACKENGINE_ARGS=${STACKENGINE_ARGS}
STACKENGINE_URL=${STACKENGINE_URL:-https://s3.amazonaws.com/stackengine-controller/linux64/stackengine}
STACKENGINE_MD5_URL=${STACKENGINE_URL}.md5
STACKENGINE_COMPONENTS_URL=${STACKENGINE_COMPONENTS_URL:-https://s3.amazonaws.com/stackengine-installers/components/templates.json}

if [[ -n "${NIC}" ]]; then
    STACKENGINE_ARGS="${STACKENGINE_ARGS} ${NIC}"
else
    IP=$(ip route get 8.8.8.8 2> /dev/null | awk 'NR==1 {print $NF}' | grep '[0-9]\{1\}')
    IP=${IP:-127.0.0.1}
    [[ "${IP}" == "127.0.0.1" ]] && STACKENGINE_ARGS="${STACKENGINE_ARGS} -bind=${IP}"
fi

if [[ -n "${LEADER}" && "${LEADER}" != "$(hostname)" ]]; then
    MESH=${MESH:-join}
    STACKENGINE_ARGS="${STACKENGINE_ARGS} -${MESH}=${LEADER}"
else
    LEADER=${LEADER:-$(hostname)}
fi

ID=${ID:-"unset"}

#
# use arg 1 as the return code and emit remaining args as error message
#
Error() {
    local ec=$1
    shift
    ${ECHO} "\nError[${ec}]: $*"
    exit 23
}

command_exists() {
    command -v "$*" > /dev/null 2>&1
}

ensure_directory() {
    printf "${TAB}Preparing dirs:"
    for DIR in "$@"; do
        printf " %s" ${DIR}

        [[ $(mkdir -p ${DIR}) ]] && Error 106 "Failed mkdir ${DIR}"
        [[ $(chown -R stackengine:stackengine ${DIR}) ]] && Error 107 "Failed chown ${DIR}"
    done
    echo
}

detect_os() {
    printf "${TAB}Detecting OS and services type: "

    # check that we are on linux.
    INSTALL_SYS="$(uname -s)"
    [[ "${INSTALL_SYS}" != "Linux" ]] && Error 117 "Currently stackengine only installs on Linux systems"
    export INSTALL_SYS

    # now figure out Distribution
    [[ -z "${INSTALL_DISTRO}" && -e "/etc/os-release" ]] && INSTALL_DISTRO="$(source /etc/os-release; echo ${NAME})"
    [[ -z "${INSTALL_DISTRO}" && -e "/etc/lsb-release" ]] && INSTALL_DISTRO="$(source /etc/lsb-release; echo ${DISTRIB_ID})"
    [[ -e "/etc/redhat-release" ]] && INSTALL_DISTRO="RHEL"
    [[ -z "$(grep -o Amazon /etc/issue)" ]] || INSTALL_DISTRO='Amazon'

    # last ditch attempt to grep out a distro name
    [[ -e "/etc/issue" ]] && LINUX_DIST=( $(grep -o '[a-zA-Z]* [0-9][0-9]*\.*[0-9]*' /etc/issue) )
    if [[ -z "${INSTALL_DISTRO}" && -n "${LINUX_DIST}" ]]; then
        INSTALL_DISTRO=${LINUX_DIST[0]}
        DISTRO_VER=${LINUX_DIST[1]}
    fi

    [[ -z "${INSTALL_DISTRO}" ]] && Error 133 "Unable to determine the Distribution for this ${INSTALL_SYS} system"
    export INSTALL_DISTRO

    # override config file location if needed (if it's not upstart)
    case ${INSTALL_DISTRO} in
        Debian|Ubuntu)
            export SVC_TYPE='upstart'
            ;;
        Amazon|Fedora|RHEL|CentOS)
            [ -e "/sbin/initctl" -a -e "/etc/init" ] || export CONFIG_FILE='/etc/sysconfig/stackengine'
            export SVC_TYPE='sys5'
            [[ -e "/etc/init/rc.conf" ]] && export SVC_TYPE='upstart'
            ;;
        openSUSE)
            export CONFIG_FILE='/etc/sysconfig/stackengine'
            export SVC_TYPE='systemd'
            ;;
        *)
            Error 151 "Unable to determine distro type on ${INSTALL_DISTRO}"
            ;;
    esac

    # override if systemd detected
    if [[ "${SVC_TYPE}" != "systemd" && "$(systemctl --version > /dev/null 2>&1; echo $?)" == 0 ]]; then
        export CONFIG_FILE='/etc/sysconfig/stackengine'
        export SVC_TYPE='systemd'
    fi
    ${ECHO} "${INSTALL_DISTRO} family distro found, using ${SVC_TYPE}"
    ${ECHO} "${TAB}Config file location: ${CONFIG_FILE}"
}

# abstract services start/stop/restart cli
control_service() {
    local SERVICE=$1
    local ACTION=$2
    local IGNORE=$3
    local CMD=''
    if [[ "${SVC_TYPE}" == "systemd" ]]; then
        CMD="systemctl ${ACTION} ${SERVICE}.service"
    elif [[ -e "/etc/init/${SERVICE}.conf" ]]; then
        # upstart
        CMD="${ACTION} ${SERVICE}"
    elif [[ -e "/etc/init.d/${SERVICE}" ]]; then
        # sys5
        CMD="/etc/init.d/${SERVICE} ${ACTION}"
    fi

    ${CMD} >> ${INSTALL_LOG} 2>&1
    local RETVAL=$?

    if [[ "${RETVAL}" != 0 && "${IGNORE}" == "" ]]; then
        Error 184 "\"${CMD}\" Failed with error code: ${RETVAL}"
    fi
}

curl_remotefile() {
    local OUTFILE=$1
    local CURL_URL=$2
    local ERRNUM=${3//Error /}
    local ERRMSG=$4
    local CURL_LOG=${5:-/dev/null}

    CURL_CMD="${CURL_BIN} ${CURL_OPTS} -s -o ${OUTFILE} ${CURL_URL}"
    ${CURL_CMD} >> ${CURL_LOG} 2>&1
    local RET=$?
    [[ ${RET} == 0 ]] || Error ${ERRNUM} "[${RET}] ${ERRMSG}\n${CURL_CMD} ${CURL_ERROR_MSG}"
}

verify_md5() {
    local MD5FILE=$1
    local FILETOCHK=$2
    local IGNORE=$2

    printf "${TAB}Validating.. "
    # check MD5
    if [[ "$(grep -o '[a-z0-9]\{32\}*' ${MD5FILE})" != "$(${MD5_BIN} ${FILETOCHK} | grep -o '[a-z0-9]\{32\}*')" ]]; then
        [[ -z "${IGNORE}" ]] || return 1
        Error 210 "StackEngine binary failed MD5 match"
    fi
    ${ECHO} "MD5 verified"
    return 0
}

download_and_verify() {
    # and it's md5 file
    ${ECHO} "${TAB}Fetching StackEngine MD5 information"

    curl_remotefile "${MD5_INFOFILE}" "${STACKENGINE_MD5_URL}" "Error 220" "Failed to fetch MD5 information for StackEngine binary"

    if [[ -s "${BINFILE}" ]]; then
        chown stackengine:stackengine ${BINFILE}
        chmod 755 ${BINFILE}
        verify_md5 "${MD5_INFOFILE}" "${BINFILE}" "ignore"
        [[ $? == 0 ]] && return
    fi

    ${ECHO} "${TAB}Fetching stackengine binary"

    # get the binary file
    curl_remotefile "${BINFILE}" "${STACKENGINE_URL}" "Error 232" "Failed to fetch StackEngine binary"
    verify_md5 "${MD5_INFOFILE}" "${BINFILE}"
    chown stackengine:stackengine ${BINFILE}
    chmod 755 ${BINFILE}
    # hardlink stackengine binary to stack for cli tool
    ln ${BINFILE} ${INSTALL_DIR}/stack

    # get the stackengine components
    curl_remotefile "${COMPONENTS_FILE}" "${STACKENGINE_COMPONENTS_URL}" "Error 240" "Failed to fetch StackEngine components"
}

add_stackengine_user() {
    ${ECHO} "${TAB}Adding StackEngine user and group"
    groupadd stackengine 2> /dev/null
    useradd -g stackengine --system stackengine 2> /dev/null

    local DOCKER_GROUP=$(grep -o 'docker[a-z0-9]*' /etc/group)

    ## add stackengine to docker group
    ${ECHO} "${TAB}Adding Stackengine to docker group"
    usermod -aG ${DOCKER_GROUP:-docker} stackengine 2> /dev/null

    # bypass adding docker group to docker.sock if its already done
    if [[ "$(stat -c %G /var/run/docker.sock)" != "${DOCKERGROUP}" ]]; then
        if [[ -e "/etc/sysconfig/docker" && "$(grep -q ${DOCKER_GROUP} /etc/sysconfig/docker)" == "" ]]; then
            ${ECHO} "${TAB}Docker socket permissions adjusted to allow ${DOCKER_GROUP} group access."
            DOCKER_OPT=$(grep OPTIONS /etc/sysconfig/docker | grep -v '^#')
            if [[ -n "${DOCKER_OPT}" ]]; then
              NEW_OPT="$(echo ${DOCKER_OPT} | sed "s/\$//") -G ${DOCKER_GROUP}"
              sed -i "s/${DOCKER_OPT}/${NEW_OPT}/" /etc/sysconfig/docker
            fi
        fi
        control_service "docker" "stop"
        control_service "docker" "start"
        sleep 2
        check_docker
    fi
}


##########################################################
install_upstart_init() {
    ${ECHO} "${TAB}-------------------------------"
    ${ECHO} "${TAB}Installing upstart init script"
    ${ECHO} "${TAB}-------------------------------"
    # remove any previous scripts
    rm -f /etc/init/stackengine.conf

    # upstart create
    cat <<EOF > /etc/init/stackengine.conf
# Ubuntu upstart file at /etc/init/stackengine.conf

description "StackEngine Controller"

start on started docker
stop on stopping docker

chdir ${DATA_DIR}
kill timeout 5

console none

script
. ${CONFIG_FILE}
exec su -s /bin/sh -c 'exec "\$0" "\$@"' stackengine -- ${BINFILE} --logfile ${LOG_PATHNAME} \${STACKENGINE_ARGS}
end script
EOF

    initctl reload-configuration
}

install_systemd_init() {
    ${ECHO}
    ${ECHO} "${TAB}------------------------------"
    ${ECHO} "${TAB}Installing Systemd init script"
    ${ECHO} "${TAB}------------------------------"
    rm -f /usr/lib/systemd/system/stackengine.service
    cat <<EOF > /usr/lib/systemd/system/stackengine.service
[Unit]
Description=StackEngine Service
Documentation=http://docs.stackengine.com
After=network.target
After=docker.target

[Service]
User=stackengine
Group=stackengine
EnvironmentFile=/etc/sysconfig/stackengine
ExecStart=/usr/local/stackengine/stackengine \$STACKENGINE_ARGS

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

install_sysv_init() {
    ${ECHO} "${TAB}----------------------------"
    ${ECHO} "${TAB}Installing SysV init script"
    ${ECHO} "${TAB}----------------------------"
    rm -f /etc/init.d/stackengine
    cat <<EOF > /etc/init.d/stackengine
#! /bin/bash
#
# stackengine    Start/Stop the stackengine Agent.
#
# chkconfig: - 95 05
# processname: stackengine

### BEGIN INIT INFO
# Provides:       stackengine
# Required-Start: docker
# Required-Stop:
# Should-Start:
# Should-Stop:
# Default-Start: 2 3 4 5
# Default-Stop:  0 1 6
# Short-Description: start and stop stackengine controller
# Description: stackengine controller
### END INIT INFO

# Source function library.
. /etc/init.d/functions

# Source optional configuration file
if [ -f ${CONFIG_FILE} ] ; then
    . ${CONFIG_FILE}
fi

RETVAL=0

# Set up some common variables before we launch
prog=stackengine
path=${BINFILE}

start() {
    echo -n \$"Starting \$prog: "
    daemon --user stackengine \$path \${STACKENGINE_ARGS}
    RETVAL=\$?
    echo
    [ \$RETVAL -eq 0 ] && touch /var/lock/subsys/\$prog
    return \$RETVAL
}

stop() {
    echo -n \$"Stopping \$prog: "
    killproc \$path
    RETVAL=\$?
    echo
    [ \$RETVAL -eq 0 ] && rm -f /var/lock/subsys/\$prog
    return \$RETVAL
}

restart() {
    stop
    start
}

reload() {
    restart
}

rh_status_q() {
    status \$prog >/dev/null 2>&1
}

case "\$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    reload)
        rh_status_q || exit 7
        reload
        ;;
    status)
        status \$path
        ;;
    condrestart)
        [ -f /var/lock/subsys/\$prog ] && restart || :
        ;;
    *)
        echo $"Usage: \$0 {start|stop|status|reload|restart|condrestart}"
        exit 1
esac

exit \$?
EOF

    chmod 755 /etc/init.d/stackengine

    rm -f /etc/rc*.d/*stackengine
    ln -s "../init.d/stackengine" "/etc/rc1.d/K99stackengine"
    ln -s "../init.d/stackengine" "/etc/rc2.d/S99stackengine"
    ln -s "../init.d/stackengine" "/etc/rc3.d/S99stackengine"
    ln -s "../init.d/stackengine" "/etc/rc4.d/S99stackengine"
    ln -s "../init.d/stackengine" "/etc/rc5.d/S99stackengine"
    ln -s "../init.d/stackengine" "/etc/rc6.d/K99stackengine"
}

##########################################################

check_docker() {
    if command_exists "docker" || command_exists "lxc-docker"; then
        $(which docker) ps > /dev/null 2>&1; RET=$?
        if [[ "Amazon|Fedora|RHEL|CentOS" =~ ${INSTALL_DISTRO} && ${RET} != 0 ]]; then
            ${ECHO} "${TAB}RHEL distro found, but docker not running. Restarting docker service."
            control_service "docker" "stop" "ignore"
            control_service "docker" "start"
            $(which docker) ps > /dev/null 2>&1; RET=$?
        fi

        [[ ${RET} == 0 ]] || Error 449 "Docker service not running. Check logs."
        ${ECHO} "${TAB}Docker appears to be running."
        return 0
    else
        ${ECHO} "${TAB}WARNING: Docker does not appear to be installed."
        return 1
    fi
}

install_docker() {
    if [[ "${INSTALL_DISTRO}" == "openSUSE" && -n "${DISTRO_VER}" ]]; then
        zypper ar -f http://download.opensuse.org/repositories/Virtualization/openSUSE_${DISTRO_VER}/ Virtualization >> ${INSTALL_LOG} 2>&1
        [[ $? == 0 ]] || Error 461 "zypper adding virtualization repo failed"

        zypper --gpg-auto-import-keys --non-interactive install --recommends docker >> ${INSTALL_LOG} 2>&1
        [[ $? == 0 ]] || Error 464 "zypper adding docker package failed"

        control_service "docker" "enable"
        control_service "docker" "start"
    else
        local DOCKSH='docker_install.sh'
        local DOCKLOG='docker_install.log'
        ${ECHO} "${TAB}Installing current Docker (may take a while)"
        curl_remotefile "${DOCKSH}" "http://get.docker.com/" "Error 472" "curl of docker installer failed. Check ${DOCKLOG}" "${DOCKLOG}"
        sh ${DOCKSH} > ${DOCKLOG} 2>&1 || Error 473 "Docker Install Failed $(cat ${DOCKLOG})\n\nPlease retry StackEngine installer after installing Docker\n"
    fi

    check_docker

    ${ECHO} "${TAB}Docker install successfull. Proceeding."
}

generate_license() {
    echo "Generating a license"
}

install_stackengine() {
    cat <<EOF  >${CONFIG_FILE}
# A generated lic ID
export ID=${ID}

#
# Optional args to start stackengine controller
#
STACKENGINE_ARGS="${STACKENGINE_ARGS}"

export SE_LICENSE_SERVER=https://lic.stackengine.com
EOF

    if [[ "${SVC_TYPE}" == "systemd" ]]; then
        install_systemd_init
    elif [[ "${SVC_TYPE}" == "upstart" ]]; then
        install_upstart_init
    elif [[ "${SVC_TYPE}" == "sys5" ]]; then
        install_sysv_init
    fi

    [[ $? == 0 ]] || Error 506 "Service_type:${SVC_TYPE} install failed."
}

uninstall_stackengine() {
    control_service "stackengine" "stop" "ignore"
    [[ -z "$(pgrep stackengine)" ]] && pkill stackengine
    for DAEMON in '/etc/init.d/stackengine' '/etc/init/stackengine' '/usr/lib/systemd/system/stackengine.service'; do
      [[ -e "${DAEMON}" ]] && rm -f "${DAEMON}"
    done
    for DIR in ${INSTALL_DIR} ${LOG_DIR} ${DATA_DIR}; do
        rm -rf ${DIR}
    done
}

check_stackengine() {
    local OUTPUT=$(${CURL_BIN} -s "http://${IP}:8000/public/signup.html" | grep -c "StackEngine Controller")

    C=0
    printf "${TAB}Checking StackEngine server:"
    while [[ "${OUTPUT}" != "1" && ${C} -lt 45 ]]; do
        OUTPUT=$(${CURL_BIN} -s "http://${IP}:8000/public/signup.html" | grep -c "StackEngine Controller")
        printf '.'
        sleep 2
        C=$[$C+1]
    done

    [[ "${OUTPUT}" == "1" ]] || Error 532 "StackEngine controller page inaccessible."
    ${ECHO} " StackEngine controller page confirmed."
}

#############################################################################################
################################  Start of installer script  ################################
#############################################################################################
${ECHO} "Installing StackEngine Controller: $(date)"

# Check to see if you're root
if [ "`id -u`" != "0" ]; then
    cat <<EOF >&2
You must be root (or use sudo) to execute the stackengine installer!

During the install process a stackengine user is created and granted
access to the docker group, normal operation of stackengine binary
does not require root.
EOF

    Error 551 "Need root privilege"
    exit 1
fi

detect_os

echo
${ECHO} "Docker:"
check_docker
[[ $? == 0 ]] || install_docker

echo
${ECHO} "StackEngine:"
# if the stackengine controller is running stop it, ignore any errors.
control_service "stackengine" "stop" "ignore"

add_stackengine_user

ensure_directory "${INSTALL_DIR}" "${LOG_DIR}" "${DATA_DIR}"
download_and_verify

# install stackengine service
install_stackengine

# start stackengine service
control_service "stackengine" "stop" "ignore"
control_service "stackengine" "start"

check_stackengine

${ECHO} "Install completed: $(date)\n"
${ECHO} "\nConnect to StackEngine Admin via: http://${LEADER}:8000\n"
