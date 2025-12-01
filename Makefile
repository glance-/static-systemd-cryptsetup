MAKEFLAGS += --no-default-rules

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(patsubst %/,%,$(dir $(mkfile_path)))

include versions.inc

all: systemd-cryptsetup systemd-cryptenroll veritysetup systemd-dissect

# TPM2-TSS

tpm2-tss: versions.inc
	rm -rf $@
	git clone --depth 1 --branch $(TSS2_VERSION) https://github.com/tpm2-software/tpm2-tss $@

tpm2-tss/.git/HEAD: tpm2-tss

tpm2-tss/configure: tpm2-tss/.git/HEAD
	cd tpm2-tss && ./bootstrap

%-build:
	mkdir -p $@

tpm2-tss-build/Makefile: tpm2-tss/configure | tpm2-tss-build
	cd tpm2-tss-build && ../tpm2-tss/configure --prefix=$(current_dir)/install --disable-shared --enable-static CFLAGS='-Os -fdebug-prefix-map=$(current_dir)=. -ffunction-sections -fdata-sections' --disable-fapi --enable-nodl --disable-tcti-mssim --disable-tcti-swtpm --disable-policy --with-crypto=mbed

install/lib/libtss2-esys.a install/lib/libtss2-policy.a install/lib/libtss2-sys.a install/lib/libtss2-tcti-device.a install/lib/libtss2-tcti-pcap.a install/lib/libtss2-mu.a install/lib/libtss2-rc.a install/lib/libtss2-tcti-cmd.a install/lib/libtss2-tctildr.a install/lib/libtss2-tcti-spi-helper.a: tpm2-tss-build/Makefile
	+make -C tpm2-tss-build install

# LVM2

lvm2: versions.inc
	rm -rf $@
	git clone --depth 1 --branch $(LVM2_VERSION) https://gitlab.com/lvmteam/lvm2.git $@

lvm2-build/Makefile: lvm2 | lvm2-build
	cd lvm2-build && ../lvm2/configure CFLAGS='-Os -fdebug-prefix-map=$(current_dir)=. -ffunction-sections -fdata-sections' --enable-static_link --disable-selinux --enable-pkgconfig --prefix=$(current_dir)/install --with-confdir=$(current_dir)/install/etc --disable-systemd-journal --disable-notify-dbus --disable-app-machineid --without-systemd-run
	# Patch out a build path from being compiled in
	perl -pi -e 's,#define LVRESIZE_FS_HELPER_PATH.*,#define LVRESIZE_FS_HELPER_PATH "/bin/false",' lvm2-build/include/configure.h

install/lib/libdevmapper.a install/lib/pkgconfig/devmapper.pc: lvm2-build/Makefile
	+make -C lvm2-build/ install


# CRYPTSETUP

cryptsetup: versions.inc
	rm -rf $@
	git clone --depth 1 --branch $(CRYPTSETUP_VERSION) https://gitlab.com/cryptsetup/cryptsetup.git $@

cryptsetup/.git/HEAD: cryptsetup

cryptsetup/configure: cryptsetup/.git/HEAD install/lib/pkgconfig/devmapper.pc
	cd $(dir $@) && ./autogen.sh

cryptsetup-build/Makefile: cryptsetup/configure install/lib/pkgconfig/devmapper.pc | cryptsetup-build
	cd $(dir $@) && ../cryptsetup/configure --disable-asciidoc --disable-ssh-token --with-crypto_backend=kernel --disable-udev --enable-static-cryptsetup --enable-static --disable-shared --disable-external-tokens --prefix=$(current_dir)/install --with-tmpfilesdir=$(current_dir)/install/usr/lib/tmpfiles.d PKG_CONFIG_PATH=$(current_dir)/install/lib/pkgconfig/ CFLAGS='-Os -ULOCALEDIR -fdebug-prefix-map=$(current_dir)=. -ffunction-sections -fdata-sections -I$(current_dir)/install/include'

install/lib/pkgconfig/libcryptsetup.pc cryptsetup-build/veritysetup.static &: cryptsetup-build/Makefile
	+make -C cryptsetup-build install

# LIBMOUNT / LIBUUID / LIBBLKID

util-linux: versions.inc
	rm -rf $@
	git clone --depth 1 --branch $(UTIL_LINUX_VERSION) https://github.com/util-linux/util-linux

util-linux/.git/HEAD: util-linux

util-linux/configure: util-linux/.git/HEAD
	cd $(dir $@) && ./autogen.sh

util-linux-build/Makefile: util-linux/configure | util-linux-build
	cd $(dir $@) && ../util-linux/configure --enable-static --disable-shared --disable-all-programs --enable-libuuid --enable-libblkid --enable-libmount --prefix=$(current_dir)/install CFLAGS='-Os -fdebug-prefix-map=$(current_dir)=. -ffunction-sections -fdata-sections -I$(current_dir)/install/include'

install/lib/pkgconfig/uuid.pc install/lib/pkgconfig/mount.pc install/lib/pkgconfig/blkid.pc &: util-linux-build/Makefile
	+make -C util-linux-build install

# MAESON , needed for systemd build

meson/bin/pip:
	python3 -m venv meson

meson/bin/meson: meson/bin/pip
	meson/bin/pip install meson==$(MESON_VERSION)

# SYSTEMD

systemd: versions.inc
	rm -rf $@
	git clone --depth 1 --branch $(SYSTEMD_VERSION) https://github.com/glance-/systemd $@

# The CFLAGS are to redefine some symbols which gets exposed when doing statical libs
# to other symbol names to not conflict with other static libraries which use the same
# symbol names

# Symbols in systemd which conflicts with libblkid 2.41 vs. systemd v258
SYSTEMD_SYMBOLS_TO_RENAME=parse_size parse_range strv_free strv_length strv_extend_strv strv_consume_prepend strv_remove strv_extendf strv_reverse strv_split
# patsubst don't expand multiple % so do it in shell instead.
SYSTEMD_CLFAGS_REMAP=$(shell for s in $(SYSTEMD_SYMBOLS_TO_RENAME) ; do echo "-D$${s}=$${s}_SD" ; done)

# We use a modern meson to get --prefer-static
#
# And we turn off anyhting in systemd we don't need in this specific binary.
systemd-build/build.ninja: meson/bin/meson systemd install/lib/pkgconfig/libcryptsetup.pc install/lib/pkgconfig/uuid.pc install/lib/pkgconfig/mount.pc install/lib/pkgconfig/blkid.pc install/lib/libtss2-esys.a
	env CFLAGS='-Os -fdebug-prefix-map=$(current_dir)=. -ffunction-sections -fdata-sections $(SYSTEMD_CLFAGS_REMAP)' LDFLAGS='-Wl,--gc-sections' meson/bin/meson setup --wipe --prefer-static --pkg-config-path=$(current_dir)/install/lib/pkgconfig/ --default-library=static -Dmode=release -Dlibcryptsetup-plugins=disabled -Dstatic-binaries=true -Dstatic-libsystemd=true -Dlibcryptsetup=enabled -Dopenssl=disabled -Dp11kit=disabled -Dselinux=disabled -Dgcrypt=disabled -Dzstd=disabled -Dacl=disabled systemd $(dir $@)

systemd-build/systemd-cryptsetup.static systemd-build/systemd-cryptenroll.static systemd-build/systemd-dissect.static &: systemd-build/build.ninja
	ninja -C systemd-build systemd-cryptsetup.static systemd-cryptenroll.static systemd-dissect.static

systemd-%: systemd-build/systemd-%.static
	strip -o $@ $<

veritysetup: cryptsetup-build/veritysetup.static
	strip -o $@ $<

# Clean build and artifacts
clean:
	rm -rf *-build install systemd-cryptsetup systemd-cryptenroll veritysetup systemd-dissect

# Clean all generated
propper: clean
	rm -rf cryptsetup/ meson/ systemd/ tpm2-tss/ lvm2/ util-linux/
