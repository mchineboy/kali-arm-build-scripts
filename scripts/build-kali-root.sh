#!/bin/bash

#######################################################################
## Script          : build-kali-root.sh
## Author          : Tyler Hardison <tyler@seraph-net.net>
## Acknowledgments : Offensive Security is the original author. I'm
##                 : just taking their original work and making it 
##                 : more modular.
## Changelog       : <2016.2.9-TH> Creation of original script.
##                 :
##                 :
##                 :
##                 :
## Description     : Takes a bootstrapped fs and sprinkles kali magic
#######################################################################

function usage 
{
	echo "usage: build-kali-root.sh -a architecture"
	echo 
	echo "-a architecture (required) armel,armhf,..."
}

# parse arguments

while [ "$1" != "" ]; do
   case $1 in 
     -a | --architecture ) shift
	                       architecture=$1
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

mount -t proc proc kali-${architecture}/proc
mount -o bind /proc/sys/fs/binfmt_misc kali-${architecture}/proc/sys/fs/binfmt_misc
mount -o bind /dev/ kali-${architecture}/dev/
mount -o bind /dev/pts kali-${architecture}/dev/pts
mount -o bind /sys kali-${architecture}/sys
mount -o bind /run kali-${architecture}/run

cat << EOF > ${basedir}/root/etc/apt/sources.list
deb http://http.kali.org/kali kali-rolling main non-free contrib
deb-src http://http.kali.org/kali kali-rolling main non-free contrib
EOF

cat << EOF > kali-${architecture}/debconf.set
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
EOF

cat << EOF > kali-${architecture}/third-stage
#!/bin/bash -x
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update
apt-get --yes --allow-downgrades --allow-remove-essential --allow-change-held-packages install locales-all

debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools u-boot-tools
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
export DEBIAN_FRONTEND=noninteractive
apt-get --yes --allow-downgrades --allow-remove-essential --allow-change-held-packages install $packages
apt-get --yes --allow-downgrades --allow-remove-essential --allow-change-held-packages dist-upgrade
apt-get --yes --allow-downgrades --allow-remove-essential --allow-change-held-packages autoremove

# Because copying in authorized_keys is hard for people to do, let's make the
# image insecure and enable root login with a password.

echo "Making the image insecure"
sed -i -e 's/PermitRootLogin without-password/PermitRootLogin yes/' /etc/ssh/sshd_config

update-rc.d ssh enable

rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d

rm -f /third-stage
EOF

chmod +x kali-${architecture}/third-stage
LANG=C chroot kali-${architecture} /third-stage

cat << EOF > kali-${architecture}/cleanup
#!/bin/bash -x
rm -rf /root/.bash_history
apt-get update
apt-get clean
ln -sf /run/resolvconf/resolv.conf /etc/resolv.conf
EOF

# Enable login over serial
echo "T0:23:respawn:/sbin/agetty -L ttyAMA0 115200 vt220" >> ${basedir}/root/etc/inittab

chmod +x kali-${architecture}/cleanup
LANG=C chroot kali-${architecture} /cleanup

umount kali-${architecture}/proc/sys/fs/binfmt_misc
umount kali-${architecture}/dev/pts
umount kali-${architecture}/dev/
umount kali-${architecture}/proc
umount kali-${architecture}/run
umount kali-${architecture}/sys
