#!/usr/bin/env bash

################################################################################
# File: install.sh
# Purpose: Determin the role of the StackEngine controller and then start it.
################################################################################

#
# Configuration parameters
#

# Set the size of the leadership ring.  This should be an odd number and 
# typically will not be bigger than three.
RING_SIZE=3

# Set the Docker interface to the typical unless there is a positional 
# parameter set
if [[ -z $1 ]]; then 

    # We are expecting the docker interface to the be the standard default
    DOCKER_INTERFACE="172.17.42.1"

else

    # The interface has been set to something else matching the users 
    # particular needs
    DOCKER_INTERFACE=$1

fi

echo "DOCKER_INTERFACE=${DOCKER_INTERFACE}"

# If a namespace for StackEngine does not exist create one. Etcd sees this
# as a directory.  We are going to be sloppy in that curl will always return
# success here even if the directory already existing. 
KEYCHECK=$(curl -L http://${DOCKER_INTERFACE}:4001/v2/keys/stackengine/leadership-ring -XPUT -d dir=true)

# Get the number of hosts in the leadership ring
curl -L http://${DOCKER_INTERFACE}:4001/v2/keys/stackengine/leadership-ring/ > /tmp/seinstall-ring-count
CURRENT_COUNT=$(echo "/tmp/seinstall-ring-count" | awk -f JSON.awk | grep value | wc -l)

# set up the correct start parameters
# Really it is less than ideal that we are setting the etcd key/values before
# a successful start, but this is quick and dirty.
if [[ $(echo $KEYCHECK | grep errorCode) ]]; then

    # We need a member of the leadership ring to connect to. (Not necessarily
    # the leader, but a ring member.)
    RING_IP=$(echo "/tmp/seinstall-ring-count" | awk -f JSON.awk | grep value | awk '{print $2}' | head -1 | sed s/\"//g)

    # If we don't have a full leadership ring then this is a follower, 
    # otherwise it's a client 
    if [[ $CURRENT_COUNT < $RING_SIZE ]]; then

        # This is a follower so the `-join` flag is used to say "join as a 
        # follower"
        STARTUP_PARAMS="-admin -bind=${COREOS_PUBLIC_IPV4} -debug=all -data=/stackenginedata -join=${RING_IP}"
        
        # Place a key/value in the leadership-ring 
        curl -L http://${DOCKER_INTERFACE}:4001/v2/keys/stackengine/leadership-ring/$DOCKER_HOSTNAME -XPUT -d value="${COREOS_PUBLIC_IPV4}"

    else

        # This is a client so we use the `-mesh` switch to say "just join the
        # mesh but don't participate in consensus".  No entry need occur to the 
        # leadership ring.
        STARTUP_PARAMS="-bind=${COREOS_PUBLIC_IPV4} -debug=all -data=/stackenginedata -mesh=${RING_IP}"   

    fi

else

    # This is a leader
    STARTUP_PARAMS="-admin -bind=${COREOS_PUBLIC_IPV4} -debug=all -data=/stackenginedata"

    # Place a key/value in the leadership-ring 
    curl -L http://${DOCKER_INTERFACE}:4001/v2/keys/stackengine/leadership-ring/$DOCKER_HOSTNAME -XPUT -d value="${COREOS_PUBLIC_IPV4}"

fi

# Finally, start the controller
exec /stackengine/stackengine $STARTUP_PARAMS
