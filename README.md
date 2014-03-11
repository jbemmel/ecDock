ecDock
======

Elastic Cloud extension script for Docker.io, using OpenVSwitch

This project provides a script that I put together for combining Docker containers with OpenVSwitch networking.
I imagine that the Docker.io project might want to include these extensions at one point, I am sharing this
such that others can have a look and provide feedback.

Virtual networking is different from physical networking, in that there is much more freedom to set things up.
For example, physical NICs have their MAC addresses assigned in the factory, and although it would be possible
to reprogram them, few people do this in practice. With virtual containers we can choose our own MAC addresses,
using a regularly structured allocation scheme. Regular structures reduce complexity and make the resulting
system easier to understand and manage.

ecDock introduces the concept of 'slots': Each container is assigned to a slot ( #1, #2, ... ), and a slot has a
fixed MAC address ( 0x52:xxxx:01, 0x52:xxxx:02, etc. ). Likewise, each slot has a fixed IP address ( xxxx.1, xxxx.2, etc. )

New in version 1.1
------------------
+ Supports both internal OVS ports and veth based ports ( default ); the latter is the "intended" way of combining 
  OVS with Docker, and seems to work better especially in kernel mode
+ Supports creation of kernel mode vswitches by default ( use option "--usermode" to create a usermode vswitch )
+ Supports arbitrary network masks
+ 'ec cleanup' for cleaning up ghost and stopped containers

Dependencies
------------
+ OpenVSwitch version 2.0.0 (or higher)
+ A Linux 3.8 kernel (or higher) with support for network namespaces
+ Docker package

Examples of use
---------------
Create a default 'ovs0' bridge:
<br/>ec create-vswitch 10.0.0.254/24

Start a container in slot 1, with IP 10.0.0.1 and MAC 52:00:0a:00:00:01 :
<br/>ec --slot=1 start {containername} {container parameters}

Attach to a running container in slot 1 ( requires a running shell, you may have to press a key to get a prompt ):
<br/>ec attach 1
