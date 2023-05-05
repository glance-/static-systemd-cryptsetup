MAKEFLAGS += --no-default-rules

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(patsubst %/,%,$(dir $(mkfile_path)))

include versions.inc

all: systemd-cryptsetup

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
	cd tpm2-tss-build && ../tpm2-tss/configure --prefix=$(current_dir)/install CFLAGS='-Os -ffunction-sections -fdata-sections' --disable-fapi --enable-nodl --disable-tcti-mssim --disable-tcti-swtpm

install/lib/libtss2-esys.a install/lib/libtss2-policy.a install/lib/libtss2-sys.a install/lib/libtss2-tcti-device.a install/lib/libtss2-tcti-pcap.a install/lib/libtss2-mu.a install/lib/libtss2-rc.a install/lib/libtss2-tcti-cmd.a install/lib/libtss2-tctildr.a install/lib/libtss2-tcti-spi-helper.a: tpm2-tss-build/Makefile
	+make -C tpm2-tss-build install

# LVM2

lvm2: versions.inc
	rm -rf $@
	git clone --depth 1 --branch $(LVM2_VERSION) git://sourceware.org/git/lvm2.git $@

# TODO: lvm2 out of tree build doesn't work
#lvm2-build/Makefile: lvm2 | lvm2-build
#	cd lvm2-build && ../lvm2/configure --enable-static_link --disable-selinux --enable-pkgconfig --prefix=$(current_dir)/install --disable-systemd-journal --disable-notify-dbus --disable-app-machineid --without-systemd-run
#	cd lvm2-build && perl -pi -e 's/SUBDIRS=.*$$/SUBDIRS=/' libdm/Makefile
#	cd lvm2-build && perl -pi -e 's,-L\$$\(interfacebuilddir\),-L../libdm/ioctl -pthread,' tools/Makefile
#
#lvm2-install: lvm2-build/Makefile
#	+make -C lvm2-build/ install

#lvm2/configure: lvm2

# So we build it in tree instead
# Must be ordering dependency for in-tree-build
lvm2/Makefile: | lvm2
	cd lvm2 && ./configure --enable-static_link --disable-selinux --enable-pkgconfig --prefix=$(current_dir)/install --with-confdir=$(current_dir)/install/etc --disable-systemd-journal --disable-notify-dbus --disable-app-machineid --without-systemd-run CFLAGS='-Os -ffunction-sections -fdata-sections'
	cd lvm2 && perl -pi -e 's/SUBDIRS=.*$$/SUBDIRS=/' libdm/Makefile
	cd lvm2 && perl -pi -e 's,-L\$$\(interfacebuilddir\),-L../libdm/ioctl -pthread,' tools/Makefile

install/lib/libdevmapper.a install/lib/pkgconfig/devmapper.pc: lvm2/Makefile
	+make -C lvm2 install


# CRYPTSETUP

cryptsetup: versions.inc
	rm -rf $@
	git clone --depth 1 --branch $(CRYPTSETUP_VERSION) https://gitlab.com/cryptsetup/cryptsetup.git $@

cryptsetup/.git/HEAD: cryptsetup

cryptsetup/configure: cryptsetup/.git/HEAD install/lib/pkgconfig/devmapper.pc
	cd $(dir $@) && ./autogen.sh

cryptsetup-build/Makefile: cryptsetup/configure install/lib/pkgconfig/devmapper.pc | cryptsetup-build
	cd $(dir $@) && ../cryptsetup/configure --disable-asciidoc --disable-ssh-token --with-crypto_backend=kernel --disable-udev --enable-static-cryptsetup --enable-static --disable-shared --disable-external-tokens --prefix=$(current_dir)/install --with-tmpfilesdir=$(current_dir)/install/usr/lib/tmpfiles.d PKG_CONFIG_PATH=$(current_dir)/install/lib/pkgconfig/ CFLAGS='-Os -ffunction-sections -fdata-sections -I$(current_dir)/install/include'

install/lib/pkgconfig/libcryptsetup.pc: cryptsetup-build/Makefile
	+make -C cryptsetup-build install

# We need to hack things in install/lib/pkgconfig/libcryptsetup.pc
# to make linking happen correctly
install/lib/pkgconfig/libcryptsetup.pc.patched: install/lib/pkgconfig/libcryptsetup.pc
	perl -pi -e 's/^(Cflags: .+)$$/$$1 -pthread/ ; s/^(Libs: .+)$$/$$1 -ldevmapper -lm -luuid -ljson-c -lblkid -pthread/' install/lib/pkgconfig/libcryptsetup.pc
	touch install/lib/pkgconfig/libcryptsetup.pc.patched

# MAESON , needed for systemd build

meson/bin/pip:
	python3 -m venv meson

meson/bin/meson: meson/bin/pip
	meson/bin/pip install meson==$(MAESON_VERSION)

# SYSTEMD

systemd: versions.inc
	rm -rf $@
	git clone --depth 1 --branch $(SYSTEMD_VERSION) https://github.com/glance-/systemd $@

# The CFLAGS are to redefine some symbols which gets exposed when doing statical libs
# to other symbol names to not conflict with other static libraries which use the same
# symbol names
#
# We use a modern meson to get --prefer-static
#
# And we turn off anyhting in systemd we don't need in this specific binary.
systemd-build/build.ninja: meson/bin/meson systemd install/lib/pkgconfig/libcryptsetup.pc.patched install/lib/libtss2-esys.a
	env CFLAGS='-Os -ffunction-sections -fdata-sections -Dclose_all_fds=close_all_fds_SD -Dmkdir_p=mkdir_p_SD' LDFLAGS='-Wl,--gc-sections' meson/bin/meson setup --prefer-static --pkg-config-path=$(current_dir)/install/lib/pkgconfig/ --default-library=static -Dlibcryptsetup-plugins=false -Dstatic-binaries=true -Dlibcryptsetup=true -Dopenssl=false -Dp11kit=false -Dselinux=false -Dgcrypt=false systemd $(dir $@)

systemd-build/systemd-cryptsetup: systemd-build/build.ninja
	ninja -C systemd-build systemd-cryptsetup

systemd-build/systemd-cryptsetup.static: systemd-build/build.ninja
	ninja -C systemd-build systemd-cryptsetup.static

systemd-cryptsetup: systemd-build/systemd-cryptsetup.static
	strip -o $@ $<


# Clean build and artifacts
clean:
	rm -rf *-build install lvm2 systemd-cryptsetup

# Clean all generated

	rm -rf cryptsetup/ meson/ systemd/ tpm2-tss/
