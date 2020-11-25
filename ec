#!/bin/bash

# Command line script for adding OpenVSwitch networking to Docker containers
# Copyright(C) 2014-2020, all rights reserved
# Author: Jeroen van Bemmel <jvb127@gmail.com>
# Version: 1.2

#
# 2020-11-25 Fixed some issues on CentOS7
#

VERSION="1.2"

# Exit upon errors
set -e
# set -x # debug

log_info() {
	if [ "$QUIET" == "" ]; then
	 echo -e "`basename $0`: [\e[32mINFO\e[0m] " $1
	fi
}

log_warn() {
	echo -e "`basename $0`: [\e[33mWARN\e[0m] " $1
}

log_fatal() {
	echo -e "`basename $0`: [\e[31mFATAL\e[0m] " $1
	exit 1
}

#
# Checks for docker and OpenVSwitch
#
function check_dependencies() {
# Check that docker is running
if [ "`pidof dockerd`" == "" ]; then
  log_fatal "Error: 'docker' is not running, please correct this and try again"
fi

# Check for OpenVSwitch
OVS_VSCTL=`which ovs-vsctl || true`
OVS_OFCTL=`which ovs-ofctl || true`
if [ "$OVS_VSCTL" == "" ] || [ "$OVS_OFCTL" == "" ]; then
  log_fatal "Error: please make sure 'ovs-vsctl' and 'ovs-ofctl' are in your PATH (OpenVSwitch)"
fi

# Check that OVS processes are running, try to restart them if not
if [ "`pidof ovsdb-server`" == "" ]; then
  log_warn "ovsdb-server not running, trying to restart it..."
  OVS_BASE="`dirname $OVS_VSCTL`/.."
  OVSDB_SERVER="$OVS_BASE/sbin/ovsdb-server"
  
  $OVSDB_SERVER --remote=punix:${OVS_BASE}/var/run/openvswitch/db.sock --pidfile --detach
fi
if [ "`pidof ovs-vswitchd`" == "" ]; then
  log_warn "ovs-vswitchd not running, trying to restart it..."
  OVS_BASE="`dirname $OVS_VSCTL`/.."
  OVS_VSWITCHD="$OVS_BASE/sbin/ovs-vswitchd"
  
  $OVS_VSWITCHD --pidfile --detach 
fi

log_info "Docker and OpenVSwitch dependencies OK"
}

#
# Installs Docker and OpenVSwitch packages
#
function install() {

# Allow override of default parameters
if ! [ -e /etc/default/ecDock ]; then
cat > /etc/default/ecDock << EOF
# Default settings for ecDock

# The name of the default vswitch to operate on
DEFAULT_VSWITCH=${DEFAULT_VSWITCH}

# The default slot to use when not specified with "-s" or "--slot="
DEFAULT_SLOT=${DEFAULT_SLOT} 

# Default IPV6 prefix
DEFAULT_IPV6_PREFIX=${DEFAULT_IPV6_PREFIX}

EOF
fi

log_fatal "TODO: install docker and openvswitch"
}

#
# Creates a new vswitch
# @ENV VSWITCH <name>
# @param <IP SUBNET>
# @param <device >
function create_vswitch() {
 IP=$1 
 DEV=$2
 MAC=`echo "$IP" | awk -F. '{printf("52:00:%02x:%02x:%02x:%02x",$1,$2,$3,$4)}'`
 
 log_info "create vswitch: NAME=$VSWITCH IP=$IP MAC=$MAC optional DEV=$DEV"
 
 if [ "$VSWITCH" == "" ] || [ "$IP" == "" ]; then
  log_fatal "create-vswitch: Please provide a name ($VSWITCH, default $DEFAULT_VSWITCH), IP address ($IP) and optional physical device to connect to ($DEV)"
 fi
 
 if [ "$USERMODE" == "1" ]; then
  DP_TYPE="datapath_type=netdev"
 else
  modprobe openvswitch
 fi

 check_dependencies

 $OVS_VSCTL add-br ${VSWITCH} -- set bridge ${VSWITCH} ${DP_TYPE} other-config:hwaddr=${MAC}
# TODO set port to last octet of IP address
 if [ "$DEV" != "" ]; then
   log_info "Adding device $DEV as port with ID '0xfeed'..."
   $OVS_VSCTL add-port ${VSWITCH} ${DEV} -- set interface ${DEV} ofport_request=65261
 fi
 ifconfig ${VSWITCH} ${IP}
 ifconfig ${VSWITCH} inet6 add ${IPV6_PREFIX}::${IP4}/64 || true
 
 log_info "New vswitch '$VSWITCH' created with IP $IP and MAC $MAC"
 exit 0
}

#
# Derives IP and MAC parameters for a given SLOT and VSWITCH
#
function getSlotNetworkConfig() {
  GWIPMASK=`ip a show ${VSWITCH} | awk '/inet / { print $2 }'`
  IFS='/' read -ra IPMASK <<< "$GWIPMASK"
  
  GWIP=${IPMASK[0]}
  MASK=${IPMASK[1]}
  IPBASE=`echo $GWIP | cut -d "." -f1-3`
  
  IP4="${IPBASE}.${SLOT}"
  IP="${IP4}/${MASK}"
  # MAC base prefix hardcoded to "52:00"
  MAC=`echo "${IPBASE}.${SLOT}" | awk -F. '{printf("52:00:%02x:%02x:%02x:%02x",$1,$2,$3,$4)}'`
}

#
# Starts a new container
# @env $VSWITCH
# @env $SLOT
# @param <image name>
# @param <arguments to pass to container>
#
function start() {
  IMAGE=$1; shift
  
  log_info "start: VSWITCH=$VSWITCH SLOT=$SLOT IMAGE=$IMAGE, parameters for container: $*"
  
  if [ "$SLOT" == "" ]; then
   log_fatal "start: Please provide an explicit slot to use using '--slot=n' (TODO: Automatic slot selection)"
  fi
  
  if [ "$IMAGE" == "" ]; then
   log_fatal "start: Please provide an image name ( use 'docker images' to list available options )"
  fi
  
  check_dependencies
  SLOTNAME=`printf "$VSWITCH-s%02d" $SLOT`
  HOST="`hostname`-${SLOTNAME}"
 
  # Try to create OVS port first, to catch any errors without creating the container
  if [ "$INTERNAL" == "1" ]; then
   $OVS_VSCTL add-port ${VSWITCH} ${SLOTNAME} -- set Interface ${SLOTNAME} type=internal ofport_request=${SLOT}
  else
   ip link add c-${SLOTNAME} type veth peer name ${SLOTNAME}
   $OVS_VSCTL add-port ${VSWITCH} ${SLOTNAME} -- set Interface ${SLOTNAME} ofport_request=${SLOT}
  fi 

  # TODO create ports for eth1..eth3 if defined
 
  # Start interactive shell without standard docker networking
  # Use -privileged to allow some more flexibility
  # Can use --lxc-conf="lxc.network.script.up = $SELF ${VSWITCH} ${SLOT}"
  # Can use --lxc-conf="lxc.cgroup.cpuset.cpus = $SLOT" to pin container to CPU
  # For multi-threaded containers, may need multiple CPUs
  # but then container isn't running yet in callback, and so we cannot find its NSPID yet
  CID=`docker run -d --sysctl net.ipv6.conf.all.disable_ipv6=0 --privileged --network=none --name="${SLOTNAME}" -h ${HOST} -t -i ${IMAGE} $*`
  log_info "New container started in slot $SLOTNAME with ID=$CID"

  # Use docker inspect instead of looking in Linux FS
  NSPID=`docker inspect --format='{{ .State.Pid }}' $CID`
  log_info "Found NSPID=$NSPID for container in slot $SLOTNAME"

  # Prepare working directory  
  mkdir -p /var/run/netns
  rm -f /var/run/netns/$NSPID
  ln -s /proc/$NSPID/ns/net /var/run/netns/$NSPID

  if [ "$INTERNAL" == "1" ]; then
   # Associate OVS port with the container's network namespace
   ip link set $SLOTNAME netns $NSPID || (log_warn "ip link command failed (INTERNAL); docker logs:" && docker logs ${SLOTNAME})
   ip netns exec $NSPID ip link set $SLOTNAME name eth0
   $OVS_OFCTL mod-port ${VSWITCH} ${SLOTNAME} up
  else
   ip link set c-${SLOTNAME} netns $NSPID || (log_warn "ip link command failed; docker logs:" && docker logs ${SLOTNAME})
   ip netns exec $NSPID ip link set c-$SLOTNAME name eth0
   ip link set dev ${SLOTNAME} up
  fi
    
  getSlotNetworkConfig
  
  ip netns exec $NSPID ifconfig eth0 hw ether $MAC
 
  # Use explicit forwarding for the port, instead of the 'normal' action.
  # This avoids issues with learning the wrong MAC address on the wrong port
  $OVS_OFCTL add-flow ${VSWITCH} "dl_dst=${MAC} actions=${SLOT}"
 
  # For dual-NIC create a second port; the container can create a bridge if needed 
  if [ "$DUAL_NIC" == "1" ]; then
    OUTNAME=`printf "$VSWITCH-o%02d" $SLOT`
    log_info "Creating second NIC $OUTNAME..."
    $OVS_VSCTL add-port ${VSWITCH} ${OUTNAME} -- set Interface ${OUTNAME} type=internal ofport_request=$((30000+$SLOT))
    ip link set $OUTNAME netns $NSPID || (log_warn "ip link command failed for NIC2")
   
    MAC2=`echo "$IPBASE.$SLOT" | awk -F. '{printf("52:80:%02x:%02x:%02x:%02x",$1,$2,$3,$4)}'`
    ip netns exec $NSPID ip link set $OUTNAME name eth1
    ip netns exec $NSPID ifconfig eth1 hw ether $MAC2
    # Could disable ARP on eth1
   
    # Disable flooding on the IN port, allow only explicit forwarding
    $OVS_OFCTL mod-port ${VSWITCH} ${SLOTNAME} noflood
 
    # Disable flooding on the upstream-port too
    log_info "Disabling flooding on second NIC..."   
    # $OVS_OFCTL mod-port ${VSWITCH} ${OUTNAME} noforward
    $OVS_OFCTL mod-port ${VSWITCH} ${OUTNAME} noflood
    $OVS_OFCTL mod-port ${VSWITCH} ${OUTNAME} up
    
    # Create bridge and add both ports
    ip netns exec $NSPID brctl addbr br0
    ip netns exec $NSPID brctl addif br0 eth0
    ip netns exec $NSPID brctl addif br0 eth1
    ip netns exec $NSPID ip link set eth1 up
    DEV="br0"
  else
    DEV="eth0"
  fi
  
  ip netns exec $NSPID ifconfig $DEV $IP
  ip netns exec $NSPID ifconfig $DEV inet6 add $IPV6_PREFIX::${IP4}/64 || true
  
  # Make gateway point to host 
  ip netns exec $NSPID ip route add default via $GWIP 
 
  # Set the eth0 link up last, so container can synchronize by waiting on this event
  ip netns exec $NSPID ip link set lo up
  ip netns exec $NSPID ip link set eth0 up
    
  log_info "New container up and running in slot $SLOTNAME, IP=$IP and MAC=$MAC with gateway $GWIP ( dual NIC: $DUAL_NIC )"
  exit 0
}

#
# Stops a running container, deletes it and removes the vswitch port
# @param <slot>
#
function stop() {
 : ${SLOT:=$1}
 
 log_info "stop: VSWITCH=$VSWITCH SLOT=$SLOT"
 
 if [ "$SLOT" == "" ]; then
   log_fatal "stop: Please provide an explicit slot to stop"
 fi
 
 check_dependencies
 SLOTNAME=`printf "$VSWITCH-s%02d" $SLOT`
 log_info "Stopping container ${SLOTNAME}..."
 docker stop ${SLOTNAME} || true
 if [ "$NO_RM" == "" ]; then
   log_info "Removing container ${SLOTNAME}..."
   docker rm ${SLOTNAME} || true
 fi
 log_info "Removing OVS port ${SLOTNAME} from VSWITCH ${VSWITCH}..."
 getSlotNetworkConfig
 $OVS_OFCTL del-flows ${VSWITCH} "dl_dst=${MAC}"
 $OVS_VSCTL del-port ${VSWITCH} ${SLOTNAME}
 OUTNAME=`printf "$VSWITCH-o%02d" $SLOT`
 $OVS_VSCTL --if-exists del-port ${VSWITCH} ${OUTNAME}

 # Try to remove companion veth port? not needed, del-port above removes it
 # ip link del c-${SLOTNAME} || true

 exit 0
}

#
# Attaches to a running container
# @param <slot>
#
function attach() {
 : ${SLOT:=$1}
 
 log_info "attach: VSWITCH=$VSWITCH SLOT=$SLOT"
 
 if [ "$SLOT" == "" ]; then
   log_fatal "attach: Please provide an explicit slot to attach to"
 fi
 
 check_dependencies
 SLOTNAME=`printf "$VSWITCH-s%02d" $SLOT`
 log_info "Attaching to container in slot ${SLOTNAME}..."
 docker attach ${SLOTNAME}

 exit 0
}

#
# Restarts a running container
# @env $VSWITCH
# @env $SLOT
# @param <image name>
# @param <arguments to pass to container>
function restart() {

 log_info "restart: VSWITCH=$VSWITCH SLOT=$SLOT"
 
 if [ "$SLOT" == "" ]; then
   log_fatal "restart: Please provide an explicit slot to restart"
 fi

 check_dependencies
 SLOTNAME=`printf "$VSWITCH-s%02d" $SLOT`
 if [ "`docker ps | grep "$SLOTNAME"`" != "" ]; then
   log_info "restart: Stopping running container in slot $SLOTNAME..."
   docker stop ${SLOTNAME}
 fi
 start $*
}

#
# Cleans up containers that have exited
#
function cleanup() {
  log_info "Cleaning up - stopping ghosts and removing containers that have exited..."
  check_dependencies
# First stop all Ghosts
  for c in `docker ps -a | awk '/Ghost/ { print $1 }'`; do docker stop $c || true; done
  for c in `docker ps -a | awk '/Exit/ { print $1 }'`; do docker rm $c || true; done
  
  exit 0
}

#
# Prints out usage information
#
function usage() {
cat << END
Elastic Cloud control script for Docker and OpenVSwitch $VERSION
Usage: ec [ options ] COMMAND [ arguments ]

Where COMMAND is one of:
start <image> <parameters>  : Start a new container with the given image; the <parameters>
                              are passed to the init script of the container
attach <slot>               : Attach to the running container in the given slot
stop <slot>                 : Stop the container running in the given slot
restart <slot> <image> <ps> : Restart the container running in the given slot
cleanup                     : Cleanup containers that have exited

create-vswitch <name> <IP subnet/mask> [device] : Create a new vswitch connected to the given device (optional)
get-test-images             : Download test images from the ECP repository

The following options can be provided:
--install        : Install Docker and OpenVSwitch packages ( Ubuntu only for now )
-q or --quiet    : Suppress log output
--slot=<num>     : Use the given slot ( automatically selected if not provided )
--vswitch=<name> : Operate on the given vswitch ( default "$DEFAULT_VSWITCH" )

create-vswitch:
--usermode       : Setup OpenVSwitch in usermode

start:
--internal         : Use 'internal' ports instead of a veth interface
--dual-nic         : Create 2 NICs eth0(in) & eth1(out) instead of a single NIC eth0 (in/out)
--eth[0..3]=<name> : Connect the given network interface to the given vswitch

stop:
--no-rm : Do not remove the container after stopping it

END

exit 0
}

# Example input and output (from the bash prompt):
# ./parse.bash -a par1 'another arg' --c-long 'wow!*\?' -cmore -b " very long "
# Option a
# Option c, no argument
# Option c, argument `more'
# Remaining arguments:
# --> `par1'
# --> `another arg'
# --> `wow!*\?'

# Note that we use `"$@"' to let each command-line parameter expand to a 
# separate word. The quotes around `$@' are essential!
# We need TEMP as the `eval set --' would nuke the return value of getopt.
TEMP=`getopt -o hq --long install,quiet,no-rm,internal,usermode,dual-nic,help,slot:,vswitch:,eth0:,eth1:,eth2:,eth3: \
     -n 'ec' -- "$@"`

if [ $? != 0 ] ; then log_fatal "Unable to parse options, exiting..." ; fi

# Note the quotes around `$TEMP': they are essential!
eval set -- "$TEMP"

DEFAULT_VSWITCH="ovs0"
DEFAULT_SLOT=""
DEFAULT_IPV6_PREFIX="2001:db8"

# Allow override of default parameters
if [ -e /etc/default/ecDock ]; then
 . /etc/default/ecDock
fi

VSWITCH=$DEFAULT_VSWITCH
SLOT=$DEFAULT_SLOT
IPV6_PREFIX=$DEFAULT_IPV6_PREFIX

# Default: Single NIC connected to default vSwitch
ETH[0]=$VSWITCH

# Process [options]
while true ; do
    case "$1" in
        --dual-nic) DUAL_NIC=1; shift ;;
        --) shift ; break ;;
		
	-h|--help) usage;;
	--no-rm) NO_RM=1; shift ;;
	--vswitch) VSWITCH="$2"; shift 2 ;;
	--usermode) USERMODE="1"; shift ;;
	--internal) INTERNAL="1"; shift ;;
	--slot) if [ $2 -lt 1 ] || [ $2 -gt 127 ] ; then log_fatal "Slot must be between 1 and 127, inclusive"; fi; SLOT="$2"; shift 2 ;;
	-q|--quiet) QUIET=1; shift ;;
	--install) install ;;
	--eth0) ETH[0]="$2"; shift 2 ;;
	--eth1) ETH[1]="$2"; shift 2 ;;
	--eth2) ETH[2]="$2"; shift 2 ;;
	--eth3) ETH[3]="$2"; shift 2 ;;
    *) log_fatal "Internal error!" ;;
    esac
done

# Process [COMMAND]
for arg do case "$arg" in
  start) shift; start $*;;
  attach) shift; attach $*;;
  stop) shift; stop $*;;
  restart) shift; restart $*;;
  cleanup) shift; cleanup;;
  create-vswitch) shift; create_vswitch $*;;
  *) log_warn "Unknown command \"$arg\""; usage ;;
  esac
done

# execution comes here when no command was given
usage
