#!/bin/bash

install_docker()
{
	echo "Installing Docker"
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
	echo $md5
	echo $expected_md5
	if [ "$expected_md5" != "$md5" ]
	then
		echo "MD5 sums mismatch, cannot proceed"
		exit 0
	else
		echo "MD5 sum check verified"
	fi
	sudo chmod +x /usr/local/stackengine/stackengine
	#startup the leader
	sudo /usr/local/stackengine/stackengine -admin=true -debug=all -logfile=/var/log/stackengine/stackengine.log &
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

install_stackengine