#!/bin/bash

# Variables used by installer
INSTALL_DIR=/usr/local/stackengine
BINFILE=${INSTALL_DIR}/stackengine
#
LOG_DIR=/var/log/stackengine
LOG_FILENAME=stackengine.log
LOG_PATHNAME=${LOG_DIR}/${LOG_FILENAME}

DATA_DIR=/var/lib/stackengine
CONFIG_FILE=${DATA_DIR}/config

# curl is used to fetch binary and md5 info
CURL_BIN=$(which curl)
CURL_OPTS=

# md5sum is used to validate binary 
MD5_BIN=$(which md5sum)
MD5_OPTS=
MD5_INFOFILE=/tmp/stackengine.md5

# urls to cool stuff
STACKENGINE_URL=https://s3.amazonaws.com/stackengine-controller/linux64/stackengine
STACKENGINE_MD5_URL=https://s3.amazonaws.com/stackengine-controller/linux64/stackengine.md5

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
    # there are more files we can look at but for now just look at /etc/issue 
    INSTALL_DISTRO=$(awk 'NR==1{print $1}' /etc/issue)
    [[ -z ${INSTALL_DISTRO} ]] && Error 9 "Unable to figureout the Distribution for this linux system"
    export INSTALL_DISTRO
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
    ${ECHO} "\tInstalling upstart init script"
    # remove any previous scripts
    rm -f /etc/init/stackengine.conf

    # upstart create
    cat <<EOF > /etc/init/stackengine.conf
# Ubuntu upstart file at /etc/init/stackengine.conf

description "StackEngine Controller"

start on runlevel [2345]
stop on runlevel [06]

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

install_docker() {
    ${ECHO} "\tChecking and optionally installing current Docker (may take a while)"
    case ${INSTALL_DISTRO} in
        Debian|Ubuntu)
            (apt-get update && apt-get install -y --upgrade lxc-docker) >/dev/null
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

	# create stackengine required directories
	ensure_directory ${INSTALL_DIR}
	ensure_directory ${LOG_DIR}
	ensure_directory ${DATA_DIR}

    # for now just create an empty config file
    >${CONFIG_FILE}

	download_and_verify
    ensure_ownership

    # install an init script 
    case ${INSTALL_DISTRO} in
        Debian|Ubuntu)
            install_upstart_init
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

install_stackengine

${ECHO} "Install completed: $(date)\n"
