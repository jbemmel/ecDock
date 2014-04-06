#!/bin/bash

if [ "$1" != "ssh-login" ]; then # remote install via ssh?
 GW_IP=`route -n | awk '/^0.0.0.0/ { print $2 }'`
 echo "Performing remote install to root@$GW_IP (requires PermitRootLogin=yes in sshd config)..."
 ls -Al /install/
 ssh root@$GW_IP 'bash -s ssh-login ' < $0
 exit
fi

DOCKER='/usr/bin/docker'

# Running over SSH; figure out where the install container is running, and copy over its files to /tmp
CONTAINER=`$DOCKER ps | awk '/ecdock\/install/ { print $1 }'` 
if [ "$CONTAINER" == "" ]; then
  echo "Error: Unable to locate running container?"
  exit 1
fi
echo "Found running install container: $CONTAINER"

# Install required packages, only supporting Ubuntu for now
apt-get install -y ethtool build-essential fakeroot debhelper dpkg-dev make autoconf libtool dkms

mkdir -p /tmp/install/
$DOCKER cp $CONTAINER:/install /tmp/
dpkg -i /tmp/install/openvswitch*.deb
cp /tmp/install/ec /usr/bin/
rm -rf /tmp/install

echo "ecDock installation completed. Run '/usr/bin/ec' for instructions"
exit 0
