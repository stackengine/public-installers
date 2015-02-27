#!/bin/bash 

# Variables used by installer
INSTALL_DIR=${INSTALL_DIR:-/usr/local/stackengine}
BINFILE=${INSTALL_DIR}/stackengine
#
LOG_DIR=${LOG_DIR:-/var/log/stackengine}
LOG_FILENAME=stackengine.log
LOG_PATHNAME=${LOG_DIR}/${LOG_FILENAME}

DATA_DIR=${DATA_DIR:-/var/lib/stackengine}
CONFIG_FILE=${DATA_DIR}/config

# curl is used to fetch binary and md5 info
CURL_BIN=$(which curl)
CURL_OPTS=

# md5sum is used to validate binary 
MD5_BIN=$(which md5sum)
MD5_OPTS=
MD5_INFOFILE=/tmp/stackengine.md5

# urls to cool stuff
STACKENGINE_URL=${STACKENGINE_URL:-https://s3.amazonaws.com/stackengine-controller/linux64/stackengine}
STACKENGINE_MD5_URL=${STACKENGINE_URL}.md5

ID=${ID:-"unset"}
#
ECHO="/bin/echo -e "

#
# use arg 1 as the return code and emit remaining args as error message
#
Error() {
    ec=$1
    shift
    ${ECHO} "\nError: " $*
    exit $ec
}

Err_not_root() {
cat <<EOF >&2
You must be root (or use sudo) to execute the stackengine installer!

During the install process a stackengine user is created and granted 
access to the docker group, normal operation of stackengine binary 
does not require root.
EOF

Error 1 "Need root privilege"
}

ensure_directory() {
    [[ -d ${1} ]] && rm -fr ${1}    
    mkdir -p ${1}
}

download_and_verify() {
 	${ECHO} "\tFetching stackengine binary"

    ensure_directory ${INSTALL_DIR}
    cd ${INSTALL_DIR} || Error 3 "Unable to change directory to: ${INSTALL_DIR}"

    # get the binary file 
	${CURL_BIN} ${CURL_OPTS} -s -o stackengine ${STACKENGINE_URL} || Error 4 "Failed to fetch stackengine binary"
 	${ECHO} "\tFetching stackengine md5 information"
    # and it's md5 file
	${CURL_BIN} ${CURL_OPTS} -s -o ${MD5_INFOFILE} ${STACKENGINE_MD5_URL} || Error 5 "Failed to fetch md5 information for stackengine binary"

 	${ECHO} "\tValidating.."
	# check MD5
    ${MD5_BIN} --quiet -c ${MD5_INFOFILE} >/dev/null 2>&1 || Error 6 "Validation of stackengine binary failed"
	${ECHO} "\tMD5 verified"
}

set_install_type() {
    # check that we are on linux. 
    INSTALL_SYS=$(uname -s)
    [[ ${INSTALL_SYS} != "Linux" ]] && Error 8 "Currently stackengine only installs on Linux systems"
    export INSTALL_SYS

    # now figure out Distribution
    INSTALL_DISTRO=$(awk 'NR==1{print $1}' /etc/issue)
    [[ -z ${INSTALL_DISTRO} ]] && Error 9 "Unable to figure out the Distribution for this linux system"

    [[ -e "/etc/redhat-release" ]] && INSTALL_DISTRO="RHEL"

    export INSTALL_DISTRO

    # override config file location iff needed (if it's not upstart)
    case ${INSTALL_DISTRO} in
        Amazon|Fedora|RHEL|CentOS)
            [ -e /sbin/initctl -a -e /etc/init ] || export CONFIG_FILE=/etc/sysconfig/stackengine
            ;;
    esac
}

add_stackengine_user() {
    ${ECHO} "\tAdding Stackengine user and group"
    groupadd stackengine 2>/dev/null 
    useradd -g stackengine --system stackengine 2>/dev/null 

    ## add stackengine to docker group 
    ${ECHO} "\tAdding Stackengine to docker group"
    usermod -aG docker stackengine 2>/dev/null 
}

ensure_ownership() {
    ${ECHO} "\tChecking and setting ownership"
    chown stackengine:stackengine ${BINFILE}
    chmod 755 ${BINFILE}
    chown -R stackengine:stackengine ${LOG_DIR}
    chown -R stackengine:stackengine ${DATA_DIR}
}

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

install_docker() {
    ${ECHO} "\tChecking and optionally installing current Docker (may take a while)"
    case ${INSTALL_DISTRO} in
        Debian|Ubuntu)
            (apt-get update && apt-get install -y --upgrade lxc-docker) >/dev/null 
            service docker start
            ;;

        Amazon|Fedora|RHEL|CentOS)
            rpm -iUvh http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm
            yum install -y docker-io > /dev/null || Error 32 "Docker Install failed"
            service docker start
            ;;

        *)
            Error 10 "Unable to install Docker on ${INSTALL_DISTRO}" 
            ;;
    esac

}

generate_license() {
	echo "Generating a license"
}

install_stackengine() {
    # First see what the environment is like
    set_install_type

    # now check on docker (may upgrade)
    install_docker

    add_stackengine_user

	# create stackengine required directories
	ensure_directory ${INSTALL_DIR}
	ensure_directory ${LOG_DIR}
	ensure_directory ${DATA_DIR}

    # 
    cat <<EOF  >${CONFIG_FILE}
# A generated lic ID
export ID=${ID}

#
# Optional args to start stackengine controller
#
STACKENGINE_ARGS="${STACKENGINE_ARGS}"

#
# The following example enables ALL looging 
# (uncomment this line to open the logging flood gates)
STACKENGINE_ARGS="\${STACKENGINE_ARGS} --debug all"

# ----------- for testing remove when done
export SE_LICENSE_SERVER=https://lic-testing.stackengine.com
EOF

	download_and_verify
    ensure_ownership

    # install an init script 
    case ${INSTALL_DISTRO} in
        Debian|Ubuntu)
            install_upstart_init
            ;;

        Amazon|Fedora|RHEL|CentOS)
            [ -e /sbin/initctl -a -e /etc/init ] && install_upstart_init || install_sysv_init 
            ;;

        *)
            Error 4 "Unable to create init files on ${INSTALL_DISTRO}" 
            ;;
    esac
}

uninstall_stackengine() {
	rm -rf ${INSTALL_DIR}
	rm -rf ${LOG_DIR}
	rm -rf ${DATA_DIR}
}

###############################
#  Start of installer script  #
###############################
${ECHO} "\nInstalling StackEngine Controller: $(date)"

# Check to see if you're root
if [ "`id -u`" != "0" ]; then
    Err_not_root
    exit 1
fi

# validate access to curl(1) 
[[ -z "${CURL_BIN}" ]] && Error 2 "unable to locate curl(1)"

# validate access to md5suml(1) 
[[ -z "${MD5_BIN}" ]] && Error 2 "unable to locate md5sum(1)"

# if the stackengine controller is running stop it
# ignore any errors. 
stop stackengine 2> /dev/null

# install 
install_stackengine

start stackengine

${ECHO} "Install completed: $(date)\n"
${ECHO} "\nConnect to StackEngine Admin via: http://$(hostname):8000\n"
