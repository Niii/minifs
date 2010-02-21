#!/bin/bash

# prerequisites : 
# libtool, bison, flex, genext2fs, squashfs, svn -- probably more
# u-boot-mkimage -- for the arm targets

# NOTE default root password for sshing in is "biff"

# This script generates a minimal root filesystems ready to use
# + It downloads a kernel, crosstools and busybox and does
# + Uncompress the lot, patches if necessary
# + Builds the kernel modules
# + Installs the headers and modules in build/
# + Builds crosstools + uClibc
# + Builds and install busybox into rootfs/
# Then
# + Generates a ext3 base filesystem, ready to put on a SD/USB
# 	It is created small, but you can always use resize2fs to "fit"
# 	it to your partition size afterward.
# + Generates a compact squashfs filesystem
# Then
# + Builds the kernel proper.
# + Builds the "ramdisk" CPIO filesystem using the kernel method
# + Install the kernel+initrd combo file in build
# 
# The resulting kernel + initrd containing a pretty usefull system is 1.4MB
# Next step is to load it! Only way for the moment is to use a SD card
# 
# (C) Michel Pollet <buserror@gmail.com>
# 

# this is the board we are making. Several boards can co-exist, the toolchains
# are "compatible" and live in the toolchain/ subdirectory. Several board of the
# same arch can also coexist, sharing the same toolchain
TARGET_BOARD="mini2440"

COMMAND=$1

BASE="$(pwd)"

BUILD="$BASE/build-${TARGET_BOARD}"
PATCHES="$BASE/patches"
STAGING="$BUILD/staging"
KERNEL="$BUILD/kernel"
ROOTFS="$BUILD/rootfs"
CONFIG="$PATCHES/conf-$TARGET_BOARD"

source "$PATCHES"/minifs-script-utils.sh
source "$CONFIG"/minifs-script.sh

TOOLCHAIN="$BASE/toolchain"
CROSS="$TOOLCHAIN/bin/$TARGET_FULL_ARCH"
GCC="${CROSS}-gcc"

TUNEFS=/sbin/tune2fs
WGET=wget
MAKE=make

# tell host pkgcomfig to find it's files there, not on the host
export PKG_CONFIG_PATH="$STAGING/lib/pkgconfig"

mkdir -p download "$KERNEL" "$ROOTFS" "$STAGING" toolchain

# Allways regenerate the rootfs
rm -rf "$ROOTFS"/* 

TARGET_INITRD=1
TARGET_FS_SQUASH=1
TARGET_FS_EXT=1
# only set this if you /know/ the parameters for your NAND
# TARGET_FS_JFFS2="-q -l -p -e 0x20000 -s 0x800"

# 
# Download stuff, decompresses, install and patch
pushd download

VERSION_busybox=1.16.0
VERSION_linux=2.6.32.2
VERSION_crosstools=1.5.3

# in minifs-script
board_prepare

url=(
	"http://busybox.net/downloads/busybox-${VERSION_busybox}.tar.bz2" 
	"http://www.kernel.org/pub/linux/kernel/v2.6/linux-${VERSION_linux}.tar.bz2" 
	"http://ymorin.is-a-geek.org/download/crosstool-ng/crosstool-ng-${VERSION_crosstools}.tar.bz2" 
	# useful and needed
	"http://www.zlib.net/zlib-1.2.3.tar.gz" 
	# screen doesn't work, work in progress
	#"http://ftp.gnu.org/gnu/screen/screen-4.0.3.tar.gz" 
	"http://dl.lm-sensors.org/i2c-tools/releases/i2c-tools-3.0.2.tar.bz2"
	# this can get compiled and installed im staging
	"http://kent.dl.sourceforge.net/project/libusb/libusb-0.1%20%28LEGACY%29/0.1.12/libusb-0.1.12.tar.gz"
	"http://www.intra2net.com/en/developer/libftdi/download/libftdi-0.16.tar.gz"
	#"http://ffmpeg.org/releases/ffmpeg-0.5.tar.bz2"
	"http://www.oberhumer.com/opensource/lzo/download/lzo-2.03.tar.gz"
	"http://heanet.dl.sourceforge.net/project/e2fsprogs/e2fsprogs/1.41.9/e2fsprogs-libs-1.41.9.tar.gz"
	"http://git.infradead.org/mtd-utils.git/snapshot/a67747b7a314e685085b62e8239442ea54959dbc.tar.gz#mtd_utils.tgz"
)
board_prepare

for fil in "${url[@]}" ; do
	proto=${fil/+*}
	fil=${fil/*+}
	base=${fil/*\//}
	typ=${fil/*.}
	url=${base/\#*}
	loc=${base/*#/}
	if [ ! -f "$loc" ]; then
		$WGET "$fil" -O "$loc"
	fi
	baseroot=${loc/-*/}
	baseroot=${baseroot/.*/}	
	if [ ! -d "$BUILD/$baseroot" ]; then
		echo "####  Extracting $loc to $BUILD/$baseroot ($typ)"
		mkdir -p "$BUILD/$baseroot"

		case "$typ" in
			bz2)
				tar jx -C "$BUILD/$baseroot" --strip 1 -f "$loc"
				;;
			gz|tgz)
				tar zx -C "$BUILD/$baseroot" --strip 1 -f "$loc"
				;;
			*)
				echo ### error file format '$typ' ($base) not supported"
				exit 1
		esac
		for pd in "$CONFIG/$baseroot" "$PATCHES/$baseroot" ; do
			if [ -d "$pd" ]; then
				echo "#### Patching $base"
				pushd "$BUILD/$baseroot"
				cat "$pd/"/*.patch | patch -t -p1
				popd
			fi
		done
	fi
done
popd

echo "#### Configuring kernel"
mkdir -p "$BUILD/linux-obj"
# Installing default kernel config
cp "$CONFIG/config_kernel.conf"  "$BUILD/linux-obj"/.config
package linux
	PACKAGE="linux-headers"
	if [ "$COMMAND" = "kernel_menuconfig" ] ; then
		$MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
			CROSS_COMPILE="${CROSS}-" \
				menuconfig
		cp "$BUILD/linux-obj/.config" "$CONFIG/config_kernel.conf"
		rm -f ._*
		exit
	fi
	configure echo Done
	compile $MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
		CROSS_COMPILE="${CROSS}-" \
			oldconfig  &&
	install $MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
		CROSS_COMPILE="${CROSS}-" \
		INSTALL_HDR_PATH="$KERNEL" \
			headers_install
end_package

#######################################################################
## Build toolchain
#######################################################################

if [ ! -f "$GCC" ]; then 
	# configuring crosstools
	echo "####  Configuring crosstools"
	unset LD_LIBRARY_PATH
	# this patch is needed on newer host kernels
	for pd in "$PATCHES/uclibc" "$PATCHES/uclibc-${TARGET_BOARD}"; do
		if [ -d $pd ]; then
			echo "##### Installing $pd patches"
			cp $pd/*.patch "$BUILD"/crosstool/patches/uClibc/0.9.30.1/
		fi
	done

	pushd "$BUILD"/crosstool
		./configure --prefix="$STAGING" &&
			$MAKE &&
			$MAKE install
	popd

	mkdir -p "$BUILD"/toolchain
	if [ ! -f "$BUILD/toolchain/.config" ]; then
		for cf in "$CONFIG/config_crosstools.conf" "$CONFIG/config_uclibc.conf" ; do
			dst=$(basename $cf)
			cat $cf | sed \
				-e "s|MINIFS_TOOLCHAIN|$BUILD/toolchain|g" \
				-e "s|MINIFS_ROOT|$BASE|g" \
				-e "s|MINIFS_STAGING|$STAGING|g" \
				-e "s|MINIFS_KERNEL|$KERNEL|g" \
				 >"$BUILD"/toolchain/$dst
		done
	fi
	pushd "$BUILD"/toolchain
		cp config_crosstools.conf .config
		"$STAGING"/bin/ct-ng build
		#"$STAGING"/bin/ct-ng build.4
	popd
fi

if [ ! -f "$GCC" ]; then 
	echo "GCC doesn't exists!!"
	exit 1
fi

export PATH="$TOOLCHAIN/bin:$STAGING/bin:$PATH"
export CC="$TARGET_FULL_ARCH-gcc"
export CXX="$TARGET_FULL_ARCH-g++"

export CPPFLAGS="-I$STAGING/include" 
export LDFLAGS="-L$STAGING/lib -static"
export CFLAGS="-Os $TARGET_CFLAGS" 
export CXXFLAGS="$CFLAGS" 

echo "#### Building kernel modules [if any]"
package linux
	PACKAGE="linux-modules"
	rm -rf "$KERNEL"/lib 
	configure echo Done &&
	compile $MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
		CROSS_COMPILE="${CROSS}-" \
			modules -j4 &&
	install $MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
		CROSS_COMPILE="${CROSS}-" \
		INSTALL_HDR_PATH="$KERNEL" INSTALL_MOD_PATH="$KERNEL" \
			modules_install 
end_package

# the count parameter can't be used because of mksquashfs 
# name    	type mode uid gid major minor start inc count
cat << EOF | tee "$BUILD"/special_file_table.txt |\
	awk '{nod=$2=="c"||$2=="b";print nod?"nod":"dir",$1,"0"$3,$4,$5, nod? $2" "$6" "$7:"";}' \
	>"$BUILD"/special_file_table_kernel.txt 
/dev		d    755  0    0    -    -    -    -    -
/dev/console	c    600  0    0    5    1    0    0    -
/dev/ptmx	c    666  0    0    5    2    0    0    -
/dev/null	c    666  0    0    1    3    0    0    -
/dev/mem	c    640  0    0    1    1    0    0    -
/dev/tty0	c    666  0    0    4    0    0    -    -
/dev/tty1	c    666  0    0    4    1    0    -    -
/dev/tty2	c    666  0    0    4    2    0    -    -
/dev/tty3	c    666  0    0    4    3    0    -    -
/dev/tty4	c    666  0    0    4    4    0    -    -
/dev/tty5	c    666  0    0    4    5    0    -    -
/config		d    700  0    0    -    -    -    -    -
/root		d    700  0    0    -    -    -    -    -
/tmp		d    777  0    0    -    -    -    -    -
/sys		d    755  0    0    -    -    -    -    -
/proc		d    755  0    0    -    -    -    -    -
/mnt		d    755  0    0    -    -    -    -    -
/var		d    755  0    0    -    -    -    -    -
/var/log	d    755  0    0    -    -    -    -    -
/var/run	d    755  0    0    -    -    -    -    -
EOF

package busybox
	BUSY_CFLAGS="-Os -static $TARGET_CFLAGS"

	if [ -f "$CONFIG"/config_busybox.conf ]; then
		echo "#### Install default busybox config"
		configure cp -a  "$CONFIG"/config_busybox.conf .config
	else
		configure $MAKE CROSS_COMPILE="${CROSS}-" CFLAGS="$BUSY_CFLAGS" CONFIG_PREFIX="$ROOTFS" defconfig
		COMMAND="busybox_menuconfig"
	fi
	if [ "$COMMAND" = "busybox_menuconfig" ]; then
		$MAKE CROSS_COMPILE="${CROSS}-" CFLAGS="$BUSY_CFLAGS" CONFIG_PREFIX="$ROOTFS" menuconfig

		echo busybox config done, copying it back
		cp .config "$CONFIG"/config_busybox.conf
		rm ._*
		exit 0
	fi
			
	compile $MAKE CROSS_COMPILE="${CROSS}-" CFLAGS="$BUSY_CFLAGS" CONFIG_PREFIX="$ROOTFS" -j8 &&
	install $MAKE CROSS_COMPILE="${CROSS}-" CFLAGS="$BUSY_CFLAGS" CONFIG_PREFIX="$ROOTFS" install
end_package

echo "#### Generating Bare Kernel"
package linux
	PACKAGE="linux-bare"
	# make sure the default source of initrd is not set, make a "noinitrd" kernel
	configure echo Done
	sed -i "s/CONFIG_INITRAMFS_SOURCE=.*/CONFIG_INITRAMFS_SOURCE=\"\"/" \
		"$BUILD"/linux-obj/.config 
	compile $MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
		CROSS_COMPILE="${CROSS}-" \
			$TARGET_KERNEL_NAME -j4 &&
	install $MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
		CROSS_COMPILE="${CROSS}-" \
		INSTALL_PATH="$KERNEL" INSTALL_MOD_PATH="$KERNEL" \
			install
		
	if [ -f "$BUILD"/linux-obj/arch/$TARGET_ARCH/boot/bzImage ]; then
		cp "$BUILD"/linux-obj/arch/$TARGET_ARCH/boot/bzImage "$BUILD"/vmlinuz-bare.bin
	elif [ -f "$BUILD"/linux-obj/arch/$TARGET_ARCH/boot/uImage ]; then
		dd if="$BUILD"/linux-obj/arch/arm/boot/uImage \
			of="$BUILD"/kernel.ub \
			bs=128k conv=sync \
				>>"$LOGFILE" 2>&1
	fi
end_package

#######################################################################
## Build extra packages
#######################################################################

echo "#### Copying default rootfs files"
rsync -a files/ "$ROOTFS/"
if [ -d "$CONFIG/files" ]; then
	echo "#### Installing overrides"
	(cd "$CONFIG/files"; tar cf - .)|(cd "$ROOTFS"; tar xf -)
fi

source "$PATCHES"/minifs-script-common.sh
# in minifs-script
board_compile

echo "#### Striping modules and userland tools"
if [ -d "$KERNEL"/lib/modules/ ]; then
	rsync -a "$KERNEL"/lib "$ROOTFS/"
	find "$ROOTFS"/lib/modules/ -name \*.ko | xargs "${CROSS}-strip" -R .note -R .comment --strip-unneeded
fi
"${CROSS}-strip" "$ROOTFS"/bin/* "$ROOTFS"/sbin/* "$ROOTFS"/usr/bin/* 2>/dev/null

echo "#### Generating Filesystems"

if [ $TARGET_FS_SQUASH = 1 ]; then
	if mksquashfs "$ROOTFS" "$BUILD"/minifs-full-squashfs.img \
		-all-root \
		-pf "$BUILD"/special_file_table.txt \
			>>"$BUILD/._filesystem.log" 2>&1 ; then
		echo "    " "$BUILD"/minifs-full-squashfs.img " Created"
	else
		echo "#### ERROR Generating " "$BUILD"/minifs-full-squashfs.img
	fi
fi
if [ $TARGET_FS_EXT = 1 ]; then
	if genext2fs -d "$ROOTFS" \
		-U \
		-D "$BUILD"/special_file_table.txt \
		-b 8192 \
		"$BUILD"/minifs-full-ext.img 
			>>"$BUILD/._filesystem.log" 2>&1 ; then
		$TUNEFS -j "$BUILD"/minifs-full-ext.img \
			>>"$BUILD/._filesystem.log" 2>&1
		echo "    " "$BUILD"/minifs-full-ext.img " Created"
	else		
		echo "#### ERROR Generating " "$BUILD"/minifs-full-ext.img
	fi
fi

if [ "$TARGET_FS_JFFS2" != "" ]; then
	if mkfs.jffs2 $TARGET_FS_JFFS2 \
		-r "$ROOTFS" \
		-o "$BUILD"/minifs-full-jffs2.img  \
		-D "$BUILD"/special_file_table.txt
			>>"$BUILD/._filesystem.log" 2>&1 ; then
		echo "    " "$BUILD"/minifs-full-jffs2.img " Created"
	else
		echo "#### ERROR Generating " "$BUILD"/minifs-full-jffs2.img
	fi		
fi

if [ $TARGET_INITRD = 1 ]; then
	echo "#### Generating Kernel with initrd"
	cp "$CONFIG"/config_kernel.conf  "$BUILD"/linux-obj/.config
	package linux
		PACKAGE="linux-initrd"
		configure echo Done 
		$MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
			CROSS_COMPILE="${CROSS}-" \
				oldconfig && \
		compile $MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
			CROSS_COMPILE="${CROSS}-" \
				$TARGET_KERNEL_NAME -j4 &&
		install $MAKE CFLAGS="$TARGET_CFLAGS" ARCH=$TARGET_ARCH O="$BUILD/linux-obj" \
			CROSS_COMPILE="${CROSS}-" \
			INSTALL_PATH="$KERNEL" INSTALL_MOD_PATH="$KERNEL" \
				install

		if [ -f "$BUILD"/linux-obj/arch/$TARGET_ARCH/boot/bzImage ]; then
			cp "$BUILD"/linux-obj/arch/$TARGET_ARCH/boot/bzImage \
				"$BUILD"/vmlinuz-full.bin
		elif [ -f "$BUILD"/linux-obj/arch/$TARGET_ARCH/boot/uImage ]; then
			dd if="$BUILD"/linux-obj/arch/arm/boot/uImage \
				of="$BUILD"/kernel-initrd.ub \
				bs=128k conv=sync \
					>>"$LOGFILE" 2>&1
		fi
	end_package
fi

# in minifs-script
board_finish

chmod 0644 "$BUILD"/*.img "$BUILD"/*.ub 2>/dev/null
