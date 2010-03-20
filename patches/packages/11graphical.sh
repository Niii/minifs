
PACKAGES+=" libpng"
hset url libpng "ftp://ftp.simplesystems.org/pub/libpng/png/src/libpng-1.2.42.tar.bz2"
hset depends libpng "zlib"

PACKAGES+=" libfreetype"
hset url libfreetype "http://mirrors.aixtools.net/sv/freetype/freetype-2.3.12.tar.bz2"

PACKAGES+=" font-bitstream-vera"
hset url font-bitstream-vera "http://ftp.gnome.org/pub/GNOME/sources/ttf-bitstream-vera/1.10/ttf-bitstream-vera-1.10.tar.bz2"
hset phases font-bitstream-vera "deploy"

deploy-font-bitstream-vera() {
	local path="$ROOTFS"/usr/share/fonts/truetype/ttf-bitstream-vera
	mkdir -p $path
	cp *.ttf "$path"/
}

PACKAGES+=" libfontconfig"
hset url libfontconfig "http://www.fontconfig.org/release/fontconfig-2.8.0.tar.gz"

configure-libfontconfig-local() {
	export LDFLAGS="$LDFLAGS_RLINK"
	autoreconf;libtoolize;automake --add-missing
	configure-generic-local \
		--with-arch=$TARGET_FULL_ARCH \
		--disable-docs 
	# fixes cross compilation
	sed -i -e 's:^CFLAGS = -.*$:CFLAGS =:g' \
		fc-case/Makefile \
		fc-cache/Makefile \
		fc-lang/Makefile \
		fc-glyphname/Makefile \
		fc-arch/Makefile
	export LDFLAGS="$LDFLAGS_BASE"
}
configure-libfontconfig() {
	configure configure-libfontconfig-local
}

compile-libfontconfig() {
	export LDFLAGS="$LDFLAGS_RLINK -lfreetype -lz -lexpat"
	compile-generic V=1
	export LDFLAGS="$LDFLAGS_BASE"
}
deploy-libfontconfig-local() {
	cp "$STAGING_USR"/bin/fc-* \
		"$ROOTFS"/usr/bin/
	rsync -av \
		"$STAGING_USR"/etc/fonts \
		"$ROOTFS"/usr/etc/ \
			&>> "$LOGFILE" 
}
deploy-libfontconfig() {
	deploy deploy-libfontconfig-local
}

PACKAGES+=" libpixman"
hset url libpixman "http://xorg.freedesktop.org/archive/individual/lib/pixman-0.17.6.tar.bz2"

configure-libpixman() {
	local extras=""
	if [ "$TARGET_ARCH" == "arm" ]; then
		# won't work in thumb
		export CFLAGS="${CFLAGS//-mthumb[^-]/-marm }"
		extras+=" --disable-arm-simd --disable-arm-neon"	
	fi
	configure-generic \
		--disable-gtk "$extras"
	export CFLAGS="$TARGET_CFLAGS"
}

PACKAGES+=" libts"
hset url libts "http://download2.berlios.de/tslib/tslib-1.0.tar.bz2"

configure-libts-local() {
	configure-generic-local \
		--disable-linear-h2200 \
		--disable-ucb1x00 \
		--disable-corgi \
		--disable-collie \
		--disable-h3600 \
		--disable-mk712 \
		--disable-arctic2
	sed -i -e 's:^#define malloc rpl_malloc:// #define malloc rpl_malloc:g' config.h
}
configure-libts() {
	configure configure-libts-local
}
deploy-libts() {
	ROOTFS_PLUGINS+="$STAGING_USR/lib/ts:"
	deploy-generic
}