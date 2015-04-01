#!/usr/bin/env bash

tabs 2
# Variables used by installer
INSTALL_DIR=${INSTALL_DIR:-/usr/local/stackengine}
BINFILE=${INSTALL_DIR}/stackengine
COMPONENTSFILE=${INSTALL_DIR}/PrebakedComponents.json
#
LOG_DIR=${LOG_DIR:-/var/log/stackengine}
LOG_FILENAME=stackengine.log
LOG_PATHNAME=${LOG_DIR}/${LOG_FILENAME}

INSTALL_LOG="stackengine_install.log" && echo > ${INSTALL_LOG}

DATA_DIR=${DATA_DIR:-/var/lib/stackengine}
CONFIG_FILE=${DATA_DIR}/config

# curl is used to fetch binary and md5 info
CURL_BIN=$(which curl)
CURL_OPTS=

# md5sum is used to validate binary
MD5_BIN=$(which md5sum)
MD5_OPTS=
MD5_INFOFILE=/tmp/stackengine.md5

# validate access to curl(1)
[[ -z "${CURL_BIN}" ]] && Error 27 "unable to locate curl(1)"
# validate access to md5suml(1)
[[ -z "${MD5_BIN}" ]] && Error 29 "unable to locate md5sum(1)"

# urls to cool stuff
STACKENGINE_URL=${STACKENGINE_URL:-https://s3.amazonaws.com/stackengine-controller/linux64/stackengine}
STACKENGINE_MD5_URL=${STACKENGINE_URL}.md5
STACKENGINE_COMPONENTS_URL=${STACKENGINE_COMPONENTS_URL:-https://s3.amazonaws.com/stackengine-installers/components/PrebakedComponents.json}

LEADER=${LEADER:-$(hostname)}

ID=${ID:-"unset"}
#
ECHO="/bin/echo -e "

#
# use arg 1 as the return code and emit remaining args as error message
#
Error() {
    ec=$1
    shift
    ${ECHO} "\nError[${ec}]: $*"
    exit 99
}

command_exists() {
    command -v "$*" > /dev/null 2>&1
}

ensure_directory() {
    printf "\tPreparing"
    for DIR in "$@"; do
        printf " %s" ${DIR}
        [[ -d ${DIR} ]] && rm -fr ${DIR}

        [[ $(mkdir -p ${DIR}) ]] && Error 61 "Failed mkdir ${DIR}"
        [[ $(chown -R stackengine:stackengine ${DIR}) ]] && Error 62 "Failed chown ${DIR}"
    done
    echo
}

detect_os() {
    printf "\tDetecting OS and services type: "

    # check that we are on linux.
    INSTALL_SYS="$(uname -s)"
    [[ ${INSTALL_SYS} != "Linux" ]] && Error 80 "Currently stackengine only installs on Linux systems"
    export INSTALL_SYS

    # now figure out Distribution
    LINUX_DIST=( $(grep -o '[a-zA-Z]* [0-9][0-9]*\.*[0-9]*' /etc/issue) )
    INSTALL_DISTRO=${LINUX_DIST[0]}
    DISTRO_VER=${LINUX_DIST[1]}

    [[ -z ${INSTALL_DISTRO} ]] && Error 89 "Unable to figure out the Distribution for this linux system"

    [[ -e "/etc/redhat-release" ]] && INSTALL_DISTRO="RHEL"
    export INSTALL_DISTRO

    # override config file location if needed (if it's not upstart)
    case ${INSTALL_DISTRO} in
        Debian|Ubuntu)
            ${ECHO} "Debian family distro found, using upstart"
            export SVC_TYPE='upstart'
            ;;
        Amazon|Fedora|RHEL|CentOS)
            ${ECHO} "Redhat family distro found, using init"
            [ -e /sbin/initctl -a -e /etc/init ] || export CONFIG_FILE=/etc/sysconfig/stackengine
            export SVC_TYPE='sys5'
            ;;
        openSUSE)
            ${ECHO} "SUSE family distro found, using systemd"
            export CONFIG_FILE=/etc/sysconfig/stackengine
            export SVC_TYPE='systemd'
            ;;
        *)
            Error 111 "Unable to determine distro type on ${INSTALL_DISTRO}"
            ;;
    esac

    # override if systemd detected
    if [[ "${SVC_TYPE}" != "systemd" && "$(systemctl --version > /dev/null 2>&1; echo $?)" == 0 ]]; then
        ${ECHO} "\tOverriding service type, systemd found."
        export CONFIG_FILE=/etc/sysconfig/stackengine
        export SVC_TYPE='systemd'
    fi
}

# abstract services start/stop/restart cli
control_service() {
    SERVICE=$1
    ACTION=$2
    IGNORE=$3
    if [[ "${SVC_TYPE}" == "systemd" ]]; then
        CMD="systemctl ${ACTION} ${SERVICE}.service"
    elif [[ "${SVC_TYPE}" == "upstart" ]]; then
        CMD="${ACTION} ${SERVICE}"
    elif [[ "${SVC_TYPE}" == "sys5" ]]; then
        CMD="/etc/init.d/${SERVICE} ${ACTION}"
    fi

    ${CMD} >> ${INSTALL_LOG} 2>&1
    RETVAL=$?

    if [[ "${RETVAL}" != 0 && "${IGNORE}" == "" ]]; then
        Error 140 "\"${CMD}\" Failed with error code: ${RETVAL}"
    fi
}

download_and_verify() {
    ${ECHO} "\tFetching stackengine binary"

    cd ${INSTALL_DIR} || Error 147 "Unable to change directory to: ${INSTALL_DIR}"

    # get the binary file
    ${CURL_BIN} ${CURL_OPTS} -s -o ${BINFILE} ${STACKENGINE_URL} || Error 150 "Failed to fetch stackengine binary"
    chown stackengine:stackengine ${BINFILE}
    chmod 755 ${BINFILE}

    # and it's md5 file
    ${ECHO} "\tFetching stackengine md5 information"
    ${CURL_BIN} ${CURL_OPTS} -s -o ${MD5_INFOFILE} ${STACKENGINE_MD5_URL} || Error 156 "Failed to fetch md5 information for stackengine binary"

    printf "\tValidating.. "
    # check MD5
    [[ "$(grep -o '[a-z0-9]\{32\}*' ${MD5_INFOFILE})" == "$(${MD5_BIN} ${BINFILE} | grep -o '[a-z0-9]\{32\}*')" ]] || Error 160 "stackengine binary failed match"
    ${ECHO} "MD5 verified"
    # get the stackengine components
    add_stackengine_components
}

add_stackengine_user() {
    ${ECHO} "\tAdding Stackengine user and group"
    groupadd stackengine 2> /dev/null
    useradd -g stackengine --system stackengine 2> /dev/null

    DOCKER_GROUP=$(grep -o 'docker[a-z0-9]*' /etc/group)

    ## add stackengine to docker group
    ${ECHO} "\tAdding Stackengine to docker group"
    usermod -aG ${DOCKER_GROUP:-docker} stackengine 2> /dev/null

    # bypass adding docker group to docker.sock if its already done
    if [[ "$(stat -c %G /var/run/docker.sock)" != "${DOCKERGROUP}" ]]; then
        if [[ "$(grep -q ${DOCKER_GROUP} /etc/sysconfig/docker)" == "" ]]; then
            ${ECHO} "\tDocker socket permissions adjusted to allow ${DOCKER_GROUP} group access."
            DOCKER_OPT=$(grep OPTIONS /etc/sysconfig/docker)
            NEW_OPT="$(echo $DOCKER_OPT | sed "s/'$//") -G ${DOCKER_GROUP}'"
            sed -i "s/$DOCKER_OPT/$NEW_OPT/" /etc/sysconfig/docker
        fi
        control_service "docker" "stop"
        control_service "docker" "start"
        sleep 2
        check_docker
    fi
}


##########################################################
install_upstart_init() {
    ${ECHO} "\t-------------------------------"
    ${ECHO} "\tInstalling upstart init script"
    ${ECHO} "\t-------------------------------"
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
    ${ECHO} "\t------------------------------"
    ${ECHO} "\tInstalling Systemd init script"
    ${ECHO} "\t------------------------------"
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
    ${ECHO} "\t----------------------------"
    ${ECHO} "\tInstalling SysV init script"
    ${ECHO} "\t----------------------------"
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
            ${ECHO} "\tRHEL distro found, but docker not running. Restarting docker service."
            control_service "docker" "stop" "ignore"
            control_service "docker" "start" "ignore"
            $(which docker) ps > /dev/null 2>&1; RET=$?
        fi

        [[ ${RET} == 0 ]] || Error 366 "Docker service not running. Check logs."
        ${ECHO} "\tDocker appears to be running."
        return 0
    else
        ${ECHO} "\tWARNING: Docker does not appear to be installed."
        return 1
    fi
}

install_docker() {
    if [[ "${INSTALL_DISTRO}" == "openSUSE" ]]; then
        zypper ar -f http://download.opensuse.org/repositories/Virtualization/openSUSE_${DISTRO_VER}/ Virtualization >> ${INSTALL_LOG} 2>&1
        [[ $? == 0 ]] || Error 378 "zypper adding virtualization repo failed"

        zypper --gpg-auto-import-keys --non-interactive install --recommends docker >> ${INSTALL_LOG} 2>&1
        [[ $? == 0 ]] || Error 381 "zypper adding docker package failed"

        control_service docker enable
        control_service docker start
    else
        DOCKLOG='/tmp/docker_install.log'
        ${ECHO} "\tInstalling current Docker (may take a while)"
        ${CURL_BIN} -sSL http://get.docker.com/ -o /tmp/docker_install.sh > ${DOCKLOG} 2>&1 || Error 388 "curl of docker installer failed. Check ${DOCKLOG}"
        sh /tmp/docker_install.sh > ${DOCKLOG} 2>&1 || Error 389 "Docker Install Failed. Check ${DOCKLOG}"
    fi

    check_docker

    ${ECHO} "\tDocker install successfull. Proceeding."
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

    [[ $? == 0 ]] || Error 422 "Service_type:${SVC_TYPE} install failed."
}

add_stackengine_components() {
    ${CURL_BIN} ${CURL_OPTS} -s -o ${COMPONENTSFILE} ${STACKENGINE_COMPONENTS_URL} || Error 151 "Failed to fetch stackengine components"
}

uninstall_stackengine() {
    rm -rf ${INSTALL_DIR}
    rm -rf ${LOG_DIR}
    rm -rf ${DATA_DIR}
}

check_stackengine() {
    OUTPUT=`curl -s "http://${HOSTNAME}:8000/public/signup.html" | grep -c 'StackEngine Controller Admin User Creation'`
    C=0
    while [[ ${OUTPUT} != "2" && ${C} -lt 10 ]]; do
        sleep 2
        OUTPUT=`curl -s "http://${HOSTNAME}:8000/public/signup.html" | grep -c 'StackEngine Controller Admin User Creation'`
        C=$[$C+1]
    done

    [[ "${OUTPUT}" == "2" ]] || Error 440 "StackEngine controller page inaccessible."
    ${ECHO} "StackEngine controller page confirmed."
}

#############################################################################################
################################  Start of installer script  ################################
#############################################################################################
${ECHO} "\nInstalling StackEngine Controller: $(date)"

# Check to see if you're root
if [ "`id -u`" != "0" ]; then
    cat <<EOF >&2
You must be root (or use sudo) to execute the stackengine installer!

During the install process a stackengine user is created and granted
access to the docker group, normal operation of stackengine binary
does not require root.
EOF

    Error 459 "Need root privilege"
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
control_service "stackengine" "start"

check_stackengine

${ECHO} "Install completed: $(date)\n"
${ECHO} "\nConnect to StackEngine Admin via: http://${LEADER}:8000\n"
