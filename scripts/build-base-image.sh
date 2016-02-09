#!/bin/bash

#######################################################################
## Script          : build-base-image.sh
## Author          : Tyler Hardison <tyler@seraph-net.net>
## Acknowledgments : Offensive Security is the original author. I'm
##                 : just taking their original work and making it 
##                 : more modular.
## Changelog       : <2016.2.9-TH> Creation of original script.
##                 :
##                 :
##                 :
##                 :
##                 :
#######################################################################

function usage 
{
	echo "usage: build-base-image.sh -a architecture -p buildpath [-r kali-release] [-m mirror] [-n hostname]"
	echo 
	echo "-a architecture (required) armel,armhf,..."
	echo "-p buildpath (required) where are we building this?"
	echo "-r release (optional) defaults to 'rolling'"
	echo "-m mirror (optional) defaults to http.kali.org"
	echo "-n hostname (optional) defaults to 'kali'"
}

# parse arguments

while [ "$1" != "" ]; do
   case $1 in 
     -a | --architecture ) shift
	                       architecture=$1
						   ;;
	 -p | --path         ) shift
	                       buildpath=$1
						   ;;
	 -r | --release      ) shift
	                       release=$1
						   ;;
	 -m | --mirror       ) shift
	                       mirror=$1
						   ;;
	 -n | --hostname     ) shift
	                       hostname=$1
						   ;;
	 -? | -h | --help    ) usage
	                       exit
						   ;;
	 * )                   usage
	                       exit 1
   esac
   shift
done   

if [ "X${architecture}" = "X" ] 
then
	usage
	exit 1
fi

if [ "X${buildpath}" = "X" ]
then
    usage
	exit 1
fi

# Was mirror defined? If not let's set it.
if [ "X${mirror}" = "X" ]
then
  mirror=http.kali.org
fi

if [ "X${release}" = "X" ]
then
  release="rolling"
fi

if [ ! -d "${buildpath}" ]
then
	mkdir -p ${buildpath}
else 
    echo "Choosing not to overwrite a previous build."
	echo "Please move ${buildpath} out of the way."
	exit 1
fi

cd ${buildpath}

# create the rootfs - not much to modify here, except maybe the hostname.
debootstrap --foreign --arch ${architecture} kali-${release} kali-${architecture} http://${mirror}/kali

cp /usr/bin/qemu-arm-static kali-${architecture}/usr/bin/

grep -q rns-rpi kali-${architecture}/etc/hostname

LANG=C chroot kali-${architecture} /debootstrap/debootstrap --second-stage
cat << EOF > kali-${architecture}/etc/apt/sources.list
deb http://${mirror}/kali kali-rolling main contrib non-free
EOF

# Set hostname
echo ${hostname} > kali-${architecture}/etc/hostname

# So X doesn't complain, we add kali to hosts
cat << EOF > kali-${architecture}/etc/hosts
127.0.0.1       ${hostname}    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

cat << EOF > kali-${architecture}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

cp /etc/resolf.conf kali-${architecture}/etc/resolv.conf

# Base image is complete.

exit;
