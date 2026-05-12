# Multi-stage build:
#
# Stage 1 ("kmod-builder"): regular Fedora 44 image. Install
# akmods + kernel-devel + xorg-x11-drv-nvidia-kmodsrc, drop to a
# non-root user, run akmodsbuild to produce kmod-nvidia.rpm. No
# rpm-ostree involved — akmodsbuild's `-w /var` root check passes
# false naturally for non-root.
#
# Stage 2 (final image): FCOS. Override-replace kernel to match
# what stage 1 built against, then `rpm-ostree install` the
# kmod-nvidia RPM that stage 1 produced. No akmod build inside
# FCOS, no transaction-reset issues.

# ── Stage 1: build kmod-nvidia RPM ─────────────────────────────
FROM fedora:44 AS kmod-builder

ARG KERNEL_VERSION=6.19.14-300.fc44.x86_64
ARG KERNEL_BASE_VERSION=6.19.14-300.fc44

# RPMFusion for the nvidia kmod source RPM
RUN dnf install -y \
        https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm \
        https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-44.noarch.rpm

# Enable Fedora's updates-archive repo (not in the stock fedora:44
# image). Needed because kernel-devel-6.19.14-300.fc44 has rolled
# off updates into archive by now.
RUN dnf install -y fedora-repos-archive

# Build dependencies. kernel-devel pinned to the exact NVR we'll
# build against, from the archive repo.
RUN dnf install -y --enablerepo=updates-archive \
        akmods \
        kernel-devel-${KERNEL_BASE_VERSION} \
        kernel-headers \
        xorg-x11-drv-nvidia-kmodsrc \
        gcc make rpm-build

# Install akmod-nvidia for its source-rpm payload only. Its %post
# would invoke akmods → akmodsbuild as root, which refuses. Skip
# scriptlets with --setopt=tsflags=noscripts; we'll run akmodsbuild
# manually below as a non-root user.
RUN dnf install -y --setopt=tsflags=noscripts \
        akmod-nvidia

RUN echo "=== /usr/src/akmods/ contents ===" && \
    ls -la /usr/src/akmods/

# Build as non-root (the simplest way to satisfy akmodsbuild's
# `[[ -w /var ]]` check — unprivileged user lacks /var write
# permission, the check evaluates false, the build proceeds).
RUN useradd -m builder
USER builder
WORKDIR /home/builder

RUN /usr/sbin/akmodsbuild --kernels ${KERNEL_VERSION} \
        --outputdir /home/builder \
        /usr/src/akmods/nvidia-kmod-*.src.rpm

# Inspect what we produced — surfaces in build log, helps debug
# the depsolve issue we expect to hit in stage 2.
RUN ls -la /home/builder/ && \
    echo "=== kmod-nvidia RPM requires ===" && \
    rpm -qpR /home/builder/kmod-nvidia-*.rpm

# ── Stage 2: real FCOS image ───────────────────────────────────
FROM quay.io/fedora/fedora-coreos:stable

ARG K3S_SELINUX_TAG=v1.6.stable.1
ARG K3S_SELINUX_RPM=k3s-selinux-1.6-1.coreos.noarch.rpm

LABEL org.opencontainers.image.source="https://github.com/zerosignage/coreos-nvidia"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL ostree.bootable="true"

# Same kernel override as before — must match stage 1's KERNEL_VERSION.
RUN rpm-ostree override replace \
        --experimental \
        --from repo=updates-archive \
        kernel kernel-core kernel-modules kernel-modules-core

RUN rpm-ostree install \
        https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
        https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

RUN ln -sf /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
           /etc/pki/tls/certs/ca-bundle.crt && \
    update-ca-trust extract

RUN curl -fsSL -o /etc/pki/rpm-gpg/nvidia-container-toolkit.gpg \
        https://nvidia.github.io/libnvidia-container/gpgkey && \
    rpm --import /etc/pki/rpm-gpg/nvidia-container-toolkit.gpg && \
    curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo && \
    sed -i 's|^gpgkey=.*|gpgkey=file:///etc/pki/rpm-gpg/nvidia-container-toolkit.gpg|' \
        /etc/yum.repos.d/nvidia-container-toolkit.repo

# Bring in the pre-built kmod RPM from stage 1.
COPY --from=kmod-builder /home/builder/kmod-nvidia-*.rpm /var/tmp/rpms/

# Install the kmod RPM (provides nvidia-kmod, satisfying the dep
# from xorg-x11-drv-nvidia-cuda) + userspace driver + container
# toolkit + k3s-selinux + ansible essentials. We deliberately do
# NOT install akmod-nvidia here — the kmod RPM produced in stage 1
# is sufficient and akmod-nvidia would only re-trigger the build
# problems we just spent a whole afternoon designing around.
RUN ls /var/tmp/rpms/ && \
    rpm-ostree install \
        /var/tmp/rpms/kmod-nvidia-*.rpm \
        xorg-x11-drv-nvidia-cuda \
        nvidia-container-toolkit \
        python3-kubernetes \
        "https://github.com/k3s-io/k3s-selinux/releases/download/${K3S_SELINUX_TAG}/${K3S_SELINUX_RPM}"

# Boot-time CDI spec generator. Regenerates /etc/cdi/nvidia.yaml on
# each boot so containers requesting `nvidia.com/gpu` see the right
# device set.
COPY systemd/zsig-nvidia-cdi.service /etc/systemd/system/
RUN systemctl enable zsig-nvidia-cdi.service

# Smoke check + OSTree finalize.
RUN echo "=== kernel modules in place ===" && \
    ls /lib/modules/*/extra/nvidia/ | head -5 && \
    echo "=== nvidia userspace tools ===" && \
    ls /usr/bin/nvidia-smi /usr/bin/nvidia-ctk

RUN rpm-ostree cleanup -m && \
    ostree container commit
