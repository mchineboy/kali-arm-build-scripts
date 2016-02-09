#!/bin/bash

########################################################################
## Script          : build-kali-diskimage.sh
## Author          : Tyler Hardison <tyler@seraph-net.net>
## Acknowledgments : Offensive Security is the original author. I'm
##                 : just taking their original work and making it 
##                 : more modular.
## Changelog       : <2016.2.9-TH> Creation of original script.
##                 :
##                 :
##                 :
##                 :
## Description     : Builds a disk image on loop. Allows for encryption
########################################################################

function usage 
{
	echo "usage: build-kali-diskimage.sh -a architecture -e"
	echo 
	echo "-a architecture (required) armel,armhf,..."
	echo "-e encryption (optional) Build an encrypted image?"
}

encrypted=0
magic=0

# parse arguments

while [ "$1" != "" ]; do
   case $1 in 
     -a | --architecture ) shift
	                       architecture=$1
						   ;;
	 -e | --encryption   ) encrypted=1
						   ;;
	 -m | --rnsmagic     ) shift
						   magic=$1
	                       ;;
	 -b | --buildpath    ) shift
	                       basedir=$1
						   ;;
	 -s | --size         ) shift
	                       size=$1
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

if [ ${encrypted} -gt 0 ] 
then

	if [ "X${magic}" != "X" ]
	then
		
		# Create a local key, and then get a remote encryption key.
		mkdir -p kali-${architecture}/etc/initramfs-tools/root

		openssl rand -base64 128 | sed ':a;N;$!ba;s/\n//g' > kali-${architecture}/etc/initramfs-tools/root/.mylocalkey
		cheatid=`date "+%y%m%d%H%M%S"`;
		authorizeKey=`cat kali-${architecture}/etc/initramfs-tools/root/.mylocalkey`

		echo '{"cheatid":"${cheatid}","authorizeKey":"${authorizeKey}"}' > kali-${architecture}/root/.curlpacket
		
		encryptKey=""
		nukeKey=""
		abort=0

		while [ "X$encryptKey" = "X" ]
		do
		   curl -k -d `cat kali-${architecture}/root/.curlpacket` https://${magic}/api/registerDevice > ../.keydata${cheatid}

		   encryptKey=`jq ".Response.YourKey" ../.keydata${cheatid}`
		   nukeKey=`jq ".Response.NukeKey" ../.keydata${cheatid}`

		   if [ ${abort} -gt 30 ]
		   then
			 echo "Bailing.. Can't get proper encryption key"
			 exit 255;
		   fi
		   sleep 10;
		   abort=$(expr $abort + 1);
		done
		echo -n ${nukeKey} > .nukekey
	else 
		encryptKey=`openssh rand -base64 32 | sed ':a;N;$!ba;s/\n//g'`
		echo ${encryptKey} > ~/.encryptKey
	fi

	echo -n ${encryptKey} > .tempkey
	
fi

# Create the disk and partition it
dd if=/dev/zero of=${basedir}/kali-${architecture}.img bs=1M count=${size}
parted kali-${architecture}.img --script -- mklabel msdos
parted kali-${architecture}.img --script -- mkpart primary fat32 0 64
parted kali-${architecture}.img --script -- mkpart primary ext4 64 -1

# Set the partition variables
loopdevice=`losetup -f --show ${basedir}/kali-${architecture}.img`
device=`kpartx -va $loopdevice| sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

mkdir -p ${basedir}/bootp ${basedir}/root

# Create file systems
mkfs.vfat ${bootp}
mount ${bootp} ${basedir}/bootp

if [ "X${encryptKey}" = "X" ]
then
	mkfs.ext4 ${rootp}
	mount ${rootp} ${basedir}/root
else
	cryptsetup -v -q --cipher aes-cbc-essiv:sha256 luksFormat ${rootp} .tempkey
	cryptsetup -v -q --key-file .tempkey luksAddNuke $rootp .nukekey
	cryptsetup -v -q luksOpen $rootp crypt_sdcard --key-file .tempkey
	rm .tempkey
	rm .nukekey

	mkfs.ext4 /dev/mapper/crypt_sdcard
	mount /dev/mapper/crypt_sdcard ${basedir}/root
fi

echo "Rsyncing rootfs into image file"
rsync -HPav -q ${basedir}/kali-${architecture}/ ${basedir}/root/

# Enable login over serial
echo "T0:23:respawn:/sbin/agetty -L ttyAMA0 115200 vt220" >> ${basedir}/root/etc/inittab

mountpoint="/dev/mmcblk0p2  / ext4 errors=remount-ro,noatime 0 1"

if [ "X${encryptKey}" != "X" ]
then
	echo "initramfs initramfs.gz 0x00f00000" > ${basedir}/bootp/config.txt
	mountpoint="/dev/mapper/crypt_sdcard / ext4 defaults,noatime 0 1"
	
	mkdir -p ${basedir}/root/root/.ssh
	chmod 700 ${basedir}/root/root ${basedir}/root/root/.ssh

	ssh-keygen -t rsa -N "" -f ${basedir}/root/root/.ssh/id_rsa 
	mv ${basedir}/root/root/.ssh/id_rsa ~/rpi${cheatid}.id_rsa
	cp ${basedir}/root/root/.ssh/id_rsa.pub ~/rpi${cheatid}.authorized_keys
	mv ${basedir}/root/root/.ssh/id_rsa.pub ${basedir}/root/root/.ssh/authorized_keys

    cat << "    EOF" > ${basedir}/root/etc/initramfs-tools/root/.ssh/authorized_keys
    command="/scripts/local-top/cryptroot && kill -9 \`ps | grep-m 1 'cryptroot' | cut -d ' ' -f 3\`"
    EOF
	
	cat ~.ssh/authorized_keys >> ${basedir}/root/etc/initramfs-tools/root/.ssh/authorized_keys

	cat << EOF > ${basedir}/root/etc/crypttab
crypt_sdcard /dev/mmcblk0p2 none luks
EOF

fi

cat << EOF > ${basedir}/root/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc /proc proc nodev,noexec,nosuid 0  0
#
# Change this if you add a swap partition or file
#/dev/SWAP none swap sw 0 0
${mountpoint}
/dev/mmcblk0p1 /boot vfat defaults 0 2
EOF


if [ "X${magic}" != "X" ]
then 

# Let's add a link for curl.

cat << EOF > ${basedir}/root/usr/share/initramfs-tools/hooks/curl
#!/bin/sh -e
PREREQS=""
case \$1 in 
   prereqs) echo "\${PREREQS}"; exit 0;;
esac

./usr/share/initramfs-tools/hook-functions
copy_exec /usr/bin/curl /bin
EOF

# Let's add a link for jq.

cat << EOF > ${basedir}/root/usr/share/initramfs-tools/hooks/jq
#!/bin/sh -e
PREREQS=""
case \$1 in
   prereqs) echo "\${PREREQS}"; exit 0;;
esac

./usr/share/initramfs-tools/hook-functions
copy_exec /usr/bin/jq /bin
EOF

cat << EOF > ${basedir}/root/usr/share/initramfs-tools/hooks/curlpacket
#!/bin/sh -e
PREREQS=""
case \$1 in 
   prereqs) echo "\${PREREQS}"; exit 0;;
esac

./usr/share/initramfs-tools/hook-functions

mkdir -p \${DESTDIR}/etc/keys
cp -pnL /root/.curlpacket \${DESTDIR}/etc/keys/
chmod 600 \${DESTDIR}/etc/keys
EOF

cat << EOF > ${basedir}/root/usr/share/initramfs-tools/scripts/init-premount/rns_crypt
#!/bin/sh

PREREQ="lvm udev"

prereqs()
{
	echo "\$PREREQ"
}

case \$1 in 
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
	  serverReady=\`curl -k -q https://${magic}/api/ping | jq '.Response.Ping'\`
	  sleep 10
	done

	curl -k -q -d \`cat /etc/keys/.curlpacket\` https://${magic}/api/authorizeServer | jq '.Response.decryptKey' > /tmp/.keyfile

	cryptsetup luksOpen --key-file /tmp/.keyfile /dev/mmcblk0p2 crypt_sdcard

	if [ \$? -gt 0 ]
	then
	  echo "Hmm"
	  sleep 10
	else 
	  continue="Yes"
	fi

done	
EOF

fi

exit 0
