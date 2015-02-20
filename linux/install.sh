#!/bin/bash

#Variables used by installer
INSTALL_ROOT="/usr/local/stackengine"
LOG_ROOT="/var/log/stackengine"
LOG_FILE_NAME="stackengine.log"

install_docker()
{
	echo "Checking to see if docker was installed"
}

start_stackengine()
{
	#startup the stackengine leader
	sudo /usr/local/stackengine/stackengine -admin=true -debug=all -logfile=/var/log/stackengine/stackengine.log &
}

install_stackengine()
{
	#install stackengine
	#create stackengine install directory
	sudo mkdir /usr/local/stackengine
	#create stackengine log directory
	sudo mkdir /var/log/stackengine
	#download and install the binary
	echo "Fetching the stackengine controller from s3"
	sudo curl -s -o /usr/local/stackengine/stackengine https://s3.amazonaws.com/stackengine-controller/linux64/stackengine
	sudo curl -s -o /usr/local/stackengine/stackengine.md5 https://s3.amazonaws.com/stackengine-controller/linux64/stackengine.md5
	#check MD5
	md5=`md5sum /usr/local/stackengine/stackengine | awk '{ print $1 }'`
	expected_md5=$(</usr/local/stackengine/stackengine.md5)
	echo "Verifying MD5 matches"
	if [ "$expected_md5" != "$md5" ]
	then
		echo "MD5 sums mismatch, cannot proceed"
		exit 0
	else
		echo "MD5 sum check verified"
	fi
	sudo chmod +x /usr/local/stackengine/stackengine
}

generate_license()
{
	echo "Generating a license"
}

uninstall_stackengine()
{
	sudo rm -rf /usr/local/stackengine
	sudo rm -rf /var/log/stackengine
}
############################################
############################################
## 		End functions 		   ##
############################################
############################################

echo
echo

# Check to see if you're root
if [ "`id -u`" != "0" ]; then
cat <<EOF >&2

You must be root (or use sudo) in order to run the stackengine installer!

EOF
    exit 1
fi

install_docker
install_stackengine
start_stackengine