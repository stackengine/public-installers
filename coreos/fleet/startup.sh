#!/usr/bin/env bash

################################################################################
# File: install.sh
# Purpose: Determin the role of the StackEngine controller and then start it.
################################################################################

#
# Configuration parameters
#
ECHO="/bin/echo -e "
SEPATH='/opt/bin'
SEBIN="${SEPATH}/stackengine"
LOG_DIR='/var/log/stackengine'
DATA_DIR='/var/lib/stackengine'
CURL="$(which curl) -s -L"
LOGFILE="${LOG_DIR}/stackengine.log"
BASE_OPTS="-bind=${COREOS_PRIVATE_IPV4} -logfile=${LOGFILE}"
CONFIG_FILE='/etc/stackengine.conf'
STACKENGINE_BIN_URL='https://s3.amazonaws.com/stackengine-controller/linux64/stackengine'

# Set the size of the leadership ring.  This should be an odd number and
# typically will not be bigger than three.
RING_SIZE=3

Error() {
	ec=$1
	shift
	${ECHO} "\nError: " $*
	exit $ec
}

install_systemd_init() {
	${ECHO}
	${ECHO} "Creating StackEngine systemd service"
	rm -f /etc/systemd/system/stackengine.service
	cat <<EOF > /etc/systemd/system/stackengine.service
[Unit]
Description=StackEngine Service
Documentation=http://docs.stackengine.com
After=network.target
After=docker.target

[Service]
User=stackengine
Group=stackengine
EnvironmentFile=${CONFIG_FILE}
ExecStart=${SEBIN} \$STACKENGINE_ARGS

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

install_stackengine_conf() {
	ARGS=$1
	cat <<EOF  >${CONFIG_FILE}
# A generated lic ID
export ID=${ID}

#
# Optional args to start stackengine controller
#
STACKENGINE_ARGS="${ARGS}"

export SE_LICENSE_SERVER=https://lic.stackengine.com
EOF
}

add_stackengine_user() {
	${ECHO}
	${ECHO} "Adding Stackengine user and group"
	groupadd stackengine 2> /dev/null
	useradd -g stackengine --system stackengine 2> /dev/null

	DOCKER_GROUP=$(grep -o 'docker[a-z0-9]*' /etc/group)

	## add stackengine to docker group
	${ECHO} "Adding Stackengine to ${DOCKER_GROUP} group"
	usermod -aG ${DOCKER_GROUP:-docker} stackengine 2> /dev/null
}

control_service() {
	SERVICE=$1
	ACTION=$2
	CMD="systemctl ${ACTION} ${SERVICE}.service"

	${CMD}
	RETVAL=$?

	[[ "${RETVAL}" == 0 ]] || Error 89 "\"${CMD}\" Failed with error code: ${RETVAL}"
}

wait_to_start() {
	MSG=$1
	ACTION=$2
	MAX=${3:-15}
	C=0
	printf "${MSG}:"
	while [[ -z $(${ACTION} 2> /dev/null) ]]; do
		[[ ${C} -lt ${MAX} ]] || Error 100 "${ACTION} failed."
		printf "."
		C=$C+1
		sleep 2
	done
	printf " Success\n"
}

########################################################################
##  BEGIN INSTALL
########################################################################

${ECHO} "Install StackEngine"

# start docker and check its accessible
[[ $(pgrep docker) ]] || control_service "docker" "start"
wait_to_start "Waiting for docker to start" "docker ps"

# start etcd and check its accessible
[[ $(pgrep etcd) ]] || control_service "etcd" "start"
wait_to_start "Waiting for etcd to start" "etcdctl ls"

# Set the Docker interface to the typical unless there is a positional
# parameter set
DOCKER_INTERFACE="$(ifconfig docker0 | awk '/\<inet\>/ { print $2}')"
[[ -z $1 ]] || DOCKER_INTERFACE=$1
echo "DOCKER_INTERFACE=${DOCKER_INTERFACE}"
DOCKER_URL="http://${DOCKER_INTERFACE}:4001/v2/keys/stackengine/leadership-ring"

# create key dir regardless if it exists
KEYCHECK=$(${CURL} ${DOCKER_URL} -XPUT -d dir=true)

# Get the number of hosts in the leadership ring
${CURL} ${DOCKER_URL} -o /tmp/seinstall-ring-count
CURRENT_COUNT=$(grep -o '"value":"' /tmp/seinstall-ring-count | wc -l)

# set up the correct start parameters
# Really it is less than ideal that we are setting the etcd key/values before
# a successful start, but this is quick and dirty.
STARTUP_PARAMS="-admin ${BASE_OPTS}"
if [[ $(echo \"${KEYCHECK}\" | grep -q errorCode) ]]; then
	# We need a member of the leadership ring to connect to. (Not necessarily
	# the leader, but a ring member.)
	RING_IP=$(grep -o "\"value\":\".[a-zA-Z0-9.]*\"" /tmp/seinstall-ring-count | sed 's/\"//g' | cut -d: -f2)
	STARTUP_PARAMS="${BASE_OPTS} -mesh=${RING_IP}"

	# If we don't have a full leadership ring then this is a follower,
	# otherwise it's a client
	[[ ${CURRENT_COUNT} > ${RING_SIZE} ]] || STARTUP_PARAMS="-admin ${BASE_OPTS} -join=${RING_IP}"
fi

# populate etcd with host ip
${CURL} ${DOCKER_URL}/${DOCKER_HOSTNAME} -XPUT -d value="${COREOS_PRIVATE_IPV4}" > /dev/null 2>&1

# install config file
install_stackengine_conf "${STARTUP_PARAMS}"

# install stackengine user
add_stackengine_user

# mkdir stackengine dir
${ECHO}
${ECHO} "Creating StackEngine paths"
[[ -d "${SEPATH}" ]] || mkdir -p ${SEPATH}
[[ -d "${LOG_DIR}" ]] || mkdir -p ${LOG_DIR} && chown -R stackengine:stackengine ${LOG_DIR}
[[ -d "${DATA_DIR}" ]] || mkdir -p ${DATA_DIR} && chown -R stackengine:stackengine ${DATA_DIR}

# Finally, start the controller
${ECHO}
${ECHO} "Downloading StackEngine"
${CURL} -o stackengine ${STACKENGINE_BIN_URL}
${CURL} -o stackengine.md5 ${STACKENGINE_BIN_URL}.md5
[[ "$(cat stackengine.md5)" == "$(md5sum stackengine)" ]] || Error 167 "StackEngine binary MD5 mismatch"
mv stackengine ${SEBIN} && chmod +x ${SEBIN}

# install systemd service for stackengine
install_systemd_init

# stop exist stackengine service if it exists
[[ $(pgrep stackengine) ]] || control_service "stackengine" "stop"
control_service "stackengine" "start"
sleep 5

SE_PID=$(pgrep stackengine)
[[ ${SE_PID} ]] || Error 134 "StackEngine does not appear to be running"
${ECHO} "StackEngine running at pid: ${SE_PID}"

wait_to_start "Verifying StackEngine is accessible" "curl -m 5 -s http://${DOCKER_INTERFACE}:8000/version |grep Release"

${ECHO} "Connect to StackEngine at http://${DOCKER_INTERFACE}:8000/"
