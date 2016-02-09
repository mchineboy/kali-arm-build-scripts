#!/bin/bash

#######################################################################
## Script          : build-arm-kernel.sh
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
	 -d | --device       ) shift
						   device=$1
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
git clone --depth 1 https://github.com/raspberrypi/linux -b rpi-4.1.y ${basedir}/root/usr/src/kernel
git clone --depth 1 https://github.com/raspberrypi/tools ${basedir}/tools

cd ${basedir}/root/usr/src/kernel
git rev-parse HEAD > ../kernel-at-commit
#patch -p1 --no-backup-if-mismatch < ${basedir}/../patches/kali-wifi-injection-4.0.patch
touch .scmversion
export ARCH=arm
export CROSS_COMPILE=${basedir}/tools/arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian/bin/arm-linux-gnueabihf-
#cp ${basedir}/../kernel-configs/rpi-4.0.config .config
#cp ${basedir}/../kernel-configs/rpi-4.0.config ../rpi-4.0.config

make bcmrpi_defconfig
make -j 3 zImage modules dtbs
make modules_install INSTALL_MOD_PATH=${basedir}/root

cp .config ../rpi-4.0.config

git clone --depth 1 https://github.com/raspberrypi/firmware.git rpi-firmware
cp -rf rpi-firmware/boot/* ${basedir}/bootp/
scripts/mkknlimg arch/arm/boot/zImage ${basedir}/bootp/kernel.img

mkdir -p ${basedir}/bootp/overlays/

cp arch/arm/boot/dts/*.dtb ${basedir}/bootp/
cp arch/arm/boot/dts/overlays/*.dtb* ${basedir}/bootp/overlays/

make mrproper
cp ../rpi-4.0.config .config
make oldconfig modules_prepare
cd ${basedir}

# Create cmdline.txt file
cat << EOF > ${basedir}/bootp/cmdline.txt
dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 elevator=deadline root=/dev/mapper/crypt_sdcard cryptdevice=/dev/mmcblk0p2:crypt_sdcard rootfstype=ext4 rootwait
EOF

cat << EOF > ${basedir}/bootp/config.txt
initramfs initramfs.gz 0x00f00000
EOF

mkdir -p ${basedir}/root/root/.ssh
chmod 700 ${basedir}/root/root ${basedir}/root/root/.ssh

ssh-keygen -t rsa -N "" -f ${basedir}/root/root/.ssh/id_rsa 
mv ${basedir}/root/root/.ssh/id_rsa ~/rpi${cheatid}.id_rsa
cp ${basedir}/root/root/.ssh/id_rsa.pub ~/rpi${cheatid}.authorized_keys
mv ${basedir}/root/root/.ssh/id_rsa.pub ${basedir}/root/root/.ssh/authorized_keys

cat << EOF > ${basedir}/root/etc/initramfs-tools/root/.ssh/authorized_keys
command="/scripts/local-top/cryptroot && kill -9 \`ps | grep-m 1 'cryptroot' | cut -d ' ' -f 3\`"
EOF
cat ~.ssh/authorized_keys >> ${basedir}/root/etc/initramfs-tools/root/.ssh/authorized_keys

# Let's add a link for curl.

cat << EOF > ${basedir}/root/usr/share/initramfs-tools/hooks/curl
#!/bin/sh -e
PREREQS=""
case $1 in 
   prereqs) echo "${PREREQS}"; exit 0;;
esac

./usr/share/initramfs-tools/hook-functions
copy_exec /usr/bin/curl /bin
EOF

# Let's add a link for jq.

cat << EOF > ${basedir}/root/usr/share/initramfs-tools/hooks/jq
#!/bin/sh -e
PREREQS=""
case $1 in
   prereqs) echo "${PREREQS}"; exit 0;;
esac

./usr/share/initramfs-tools/hook-functions
copy_exec /usr/bin/jq /bin
EOF

cat << EOF > ${basedir}/root/usr/share/initramfs-tools/hooks/curlpacket
#!/bin/sh -e
PREREQS=""
case $1 in 
   prereqs) echo "${PREREQS}"; exit 0;;
esac

./usr/share/initramfs-tools/hook-functions

mkdir -p ${DESTDIR}/etc/keys
cp -pnL /etc/initramfs-tools/root/.curlpacket ${DESTDIR}/etc/keys/
chmod 600 ${DESTDIR}/etc/keys
EOF


# systemd doesn't seem to be generating the fstab properly for some people, so
# let's create one.
# TH 2016/2/3 - Make this for the encrypted method.

cat << EOF > ${basedir}/root/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc /proc proc nodev,noexec,nosuid 0  0
#/dev/mmcblk0p2  / ext4 errors=remount-ro,noatime 0 1
# Change this if you add a swap partition or file
#/dev/SWAP none swap sw 0 0
/dev/mmcblk0p1 /boot vfat defaults 0 2
/dev/mapper/crypt_sdcard / ext4 defaults,noatime 0 1
EOF

cat << EOF > ${basedir}/root/etc/crypttab
crypt_sdcard /dev/mmcblk0p2 none luks
EOF

cat << EOF > ${basedir}/root/usr/share/initramfs-tools/scripts/init-premount/rns_crypt
#!/bin/sh

PREREQ="lvm udev"

prereqs()
{
	echo "$PREREQ"
}

case $1 in 
prereqs)
  prereqs
  exit 0-9 
  ;;
esac

continue="No"

while [ $continue = "No" ]
do

	serverReady="No"

	while [ $serverReady = "No" ]
	do
	  serverReady=\`curl -k -q https://$1/api/ping | jq '.Response.Ping'\`
	  sleep 10
	done

	curl -k -q -d \`cat /etc/keys/.curlpacket\` https://$1/api/authorizeServer | jq '.Response.decryptKey' > /tmp/.keyfile

	cryptsetup luksOpen --key-file /tmp/.keyfile /dev/mmcblk0p2 crypt_sdcard

	if [ $? -gt 0 ]
	then
	  echo "Hmm"
	  sleep 10
	else 
	  continue="Yes"
	fi

done	
EOF

rm -rf ${basedir}/root/lib/firmware
cd ${basedir}/root/lib
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git firmware
rm -rf ${basedir}/root/lib/firmware/.git

# rpi-wiggle
mkdir -p ${basedir}/root/scripts
wget https://raw.github.com/dweeber/rpiwiggle/master/rpi-wiggle -O ${basedir}/root/scripts/rpi-wiggle.sh
chmod 755 ${basedir}/root/scripts/rpi-wiggle.sh

cd ${basedir}

cp ${basedir}/../misc/zram ${basedir}/root/etc/init.d/zram
chmod +x ${basedir}/root/etc/init.d/zram

# Create the initramfs
mount -t proc proc root/proc
mount -o bind /dev/ root/dev/
mount -o bind /dev/pts root/dev/pts
mount -o bind /sys root/sys
mount -o bind /run root/run

cat << EOF > ${basedir}/root/mkinitram
#!/bin/bash -x
mkinitramfs -o /boot/initramfs.gz \`ls /lib/modules/ | grep 4 | head -n 1\`
EOF

chmod +x root/mkinitram
LANG=C chroot root /mkinitram

mv ${basedir}/root/boot/initramfs.gz $basedir/bootp/

# Unmount partitions
umount -R ${basedir}/bootp
umount -R ${basedir}/root

cryptsetup luksClose /dev/mapper/crypt_sdcard

kpartx -dv $loopdevice
losetup -d $loopdevice

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Cleaning up the temporary build files..."
#rm -rf ${basedir}/kernel ${basedir}/bootp ${basedir}/root ${basedir}/kali-$architecture ${basedir}/boot ${basedir}/tools ${basedir}/patches

# If you're building an image for yourself, comment all of this out, as you
# don't need the sha1sum or to compress the image, since you will be testing it
# soon.
echo "Generating sha1sum for kali-rolling-rpi.img"
sha1sum kali-rolling-rpi.img > ${basedir}/kali-rolling-rpi.img.sha1sum
# Don't pixz on 32bit, there isn't enough memory to compress the images.
MACHINE_TYPE=`uname -m`
if [ ${MACHINE_TYPE} == 'x86_64' ]; then
echo "Compressing kali-rolling-rpi.img"
pixz ${basedir}/kali-rolling-rpi.img ${basedir}/kali-rolling-rpi.img.xz
echo "Generating sha1sum for kali-rolling-rpi.img.xz"
sha1sum kali-rolling-rpi.img.xz > ${basedir}/kali-rolling-rpi.img.xz.sha1sum
fi
