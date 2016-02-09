#!/bin/bash

# This is the Raspberry Pi2 Kali ARM build script - http://www.kali.org/downloads
# A trusted Kali Linux image created by Offensive Security - http://www.offensive-security.com

basedir=`pwd`/rpi2-rolling

# Package installations for various sections.
# This will build a minimal XFCE Kali system with the top 10 tools.
# This is the section to edit if you would like to add more packages.
# See http://www.kali.org/new/kali-linux-metapackages/ for meta packages you can
# use. You can also install packages, using just the package name, but keep in
# mind that not all packages work on ARM! If you specify one of those, the
# script will throw an error, but will still continue on, and create an unusable
# image, keep that in mind.

arm="abootimg fake-hwclock ntpdate u-boot-tools"
base="e2fsprogs initramfs-tools kali-defaults kali-menu parted sudo usbutils dropbear cryptsetup busybox jq"
desktop="fonts-croscore fonts-crosextra-caladea fonts-crosextra-carlito gnome-theme-kali gtk3-engines-xfce kali-desktop-xfce kali-root-login lightdm network-manager network-manager-gnome xfce4 xserver-xorg-video-fbdev"
tools="kali-linux-full winexe"
services="apache2 openssh-server"
extras="iceweasel xfce4-terminal wpasupplicant"

size=14500 # Size of image in megabytes

packages="${arm} ${base} ${desktop} ${tools} ${services} ${extras}"
architecture="armhf"
# If you have your own preferred mirrors, set them here.
# After generating the rootfs, we set the sources.list to the default settings.
mirror=http.kali.org
./scripts/build-base-image.sh -a ${architecture} -p ${basedir} -r ${release}

# XXX I don't currently know if this is required for third stage? Or for kernel build??

export MALLOC_CHECK_=0 # workaround for LP: #520465
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

cd ${basedir}

../scripts/build-kali-root.sh -a ${architecture} -p "${packages}"

if [ $? -gt 0 ]
then
  exit 1
fi

../scripts/build-kali-diskimage.sh -a ${architecture} -e -m $1

if [ $? -gt 0 ]
then
  echo "Disk image failed to build.. Refusing the continue."
  exit 1
fi

# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section.
git clone --depth 1 https://github.com/raspberrypi/linux -b rpi-4.1.y ${basedir}/root/usr/src/kernel
git clone --depth 1 https://github.com/raspberrypi/tools ${basedir}/tools

cd ${basedir}/root/usr/src/kernel
git rev-parse HEAD > ../kernel-at-commit

touch .scmversion
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-

make bcm2709_defconfig
make -j $(grep -c processor /proc/cpuinfo) zImage modules dtbs
make modules_install INSTALL_MOD_PATH=${basedir}/root

cp .config ../rpi2-4.1.config

git clone --depth 1 https://github.com/raspberrypi/firmware.git rpi-firmware
cp -rf rpi-firmware/boot/* ${basedir}/bootp/
scripts/mkknlimg arch/arm/boot/zImage ${basedir}/bootp/kernel7.img

mkdir -p ${basedir}/bootp/overlays/

cp arch/arm/boot/dts/*.dtb ${basedir}/bootp/
cp arch/arm/boot/dts/overlays/*.dtb* ${basedir}/bootp/overlays/

make mrproper
cp ../rpi2-4.1.config .config
make oldconfig modules_prepare
cd ${basedir}

# Create cmdline.txt file
cat << EOF > ${basedir}/bootp/cmdline.txt
dwc_otg.fiq_fix_enable=2 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 elevator=deadline root=/dev/mapper/crypt_sdcard cryptdevice=/dev/mmcblk0p2:crypt_sdcard rootfstype=ext4 rootwait
EOF

cat << EOF > ${basedir}/bootp/config.txt
initramfs initramfs.gz 0x00f00000
EOF

mkdir -p ${basedir}/root/root/.ssh
chmod 700 ${basedir}/root/root ${basedir}/root/root/.ssh

ssh-keygen -t rsa -N "" -f ${basedir}/root/root/.ssh/id_rsa 
mv ${basedir}/root/root/.ssh/id_rsa ~/rpi${cheatid}.id_rsa
cp ${basedir}/root/root/.ssh/id_rsa.pub ~/rpi${cheatid}.authorized_keys
mv ${basedir}/root/root/.ssh/id_rsa.pub ${basedir}/root/root/.ssh/authorized_keys.tmp

cat << EOF > ${basedir}/root/root/.ssh/authorized_keys
command="/scripts/local-top/cryptroot && kill -9 \`ps | grep-m 1 'cryptroot' | cut -d ' ' -f 3\`"
EOF
cat ${basedir}/root/root/.ssh/authorized_keys.tmp >> ${basedir}/root/root/.ssh/authorized_keys

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
#rm -rf ${basedir}/kernel ${basedir}/bootp ${basedir}/root ${basedir}/kali-$architecture ${basedir}/boot ${basedir}/patches

# If you're building an image for yourself, comment all of this out, as you
# don't need the sha1sum or to compress the image, since you will be testing it
# soon.
echo "Generating sha1sum for kali-$1-rpi2.img"
sha1sum kali-$1-rpi2.img > ${basedir}/kali-$1-rpi2.img.sha1sum
# Don't pixz on 32bit, there isn't enough memory to compress the images.
MACHINE_TYPE=`uname -m`
if [ ${MACHINE_TYPE} == 'x86_64' ]; then
echo "Compressing kali-$1-rpi2.img"
pixz ${basedir}/kali-$1-rpi2.img ${basedir}/kali-$1-rpi2.img.xz
#rm ${basedir}/kali-$1-rpi2.img
echo "Generating sha1sum for kali-$1-rpi2.img.xz"
sha1sum kali-$1-rpi2.img.xz > ${basedir}/kali-$1-rpi2.img.xz.sha1sum
fi
