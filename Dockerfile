# =============================================================================
# Dockerfile - build container for AlmaLinux 9 live ISO
# =============================================================================
# Runs livemedia-creator + lorax inside an almalinux:9 chroot so the host OS
# does not need any RHEL-specific tooling. Invoked by build-iso.sh.
# =============================================================================

FROM almalinux:9.8

# Versions pinned for reproducibility. Bump deliberately.
ARG LORAX_VERSION=*
ARG ANACONDA_VERSION=*
ARG PYKICKSTART_VERSION=*
RUN dnf swap -y coreutils-single coreutils ||\
	dnf install -y coreutils --allowerasing
RUN dnf install -y epel-release \
 && dnf install -y --setopt=install_weak_deps=False \
        "lorax-${LORAX_VERSION}" \
        "pykickstart-${PYKICKSTART_VERSION}" \
        "anaconda-tui-${ANACONDA_VERSION}" \
        efibootmgr \
        efi-filesystem \
        grub2-efi-x64 \
        grub2-efi-x64-cdboot \
        grub2-tools \
        grub2-tools-efi \
        grub2-tools-extra \
        shim-x64 \
        squashfs-tools \
        xorriso \
        isomd5sum \
        syslinux \
        syslinux-nonlinux \
        unzip \
        tar \
        which \
        coreutils \
	syslinux \
	syslinux-extlinux \
 && dnf clean all \
 && rm -rf /var/cache/dnf

# base64 ships in coreutils; explicit check
RUN command -v base64 >/dev/null && command -v ksvalidator >/dev/null && command -v livemedia-creator >/dev/null

WORKDIR /build

# The actual command is invoked from build-iso.sh with a `docker run` call,
# but we still set a default ENTRYPOINT so `docker run <image> --help` is useful.
ENTRYPOINT ["livemedia-creator"]
CMD ["--help"]
