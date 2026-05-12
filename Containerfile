# Three-stage build:
#
# Stage 0 ("fcos-base"): pull the FCOS base image just to read its
# kernel-core NVR. The output (a single text file at /tmp/kernel-
# uname-r) is COPY'd into stage 1 so the kmod is built against the
# exact kernel FCOS already has — no hardcoded version that goes
# stale every time FCOS rolls.
#
# Stage 1 ("kmod-builder"): regular Fedora 44 image. Reads the
# kernel version from stage 0, installs akmods + kernel-devel +
# xorg-x11-drv-nvidia-kmodsrc for that exact version, drops to a
# non-root user, runs akmodsbuild to produce kmod-nvidia.rpm.
# akmodsbuild's `[[ -w /var ]]` root-check passes false naturally
# for non-root.
#
# Stage 2 (final image): FCOS. Installs the pre-built kmod-nvidia
# RPM directly — NO `rpm-ostree override replace` because the kmod
# was built against FCOS's actual kernel version. When FCOS rolls
# forward, stage 0 picks up the new kernel-core NVR, the COPY into
# stage 1 invalidates the build cache, and the kmod is rebuilt
# automatically. No Containerfile edits needed across FCOS kernel
# rolls — that's the whole point of this refactor. The 2026-05-12
# build failure (FCOS shipped kernel 7.0.4 while this file hardcoded
# 6.19.14) was the prompt for this redesign.

# ── Stage 0: detect the FCOS base kernel ──────────────────────
FROM quay.io/fedora/fedora-coreos:stable AS fcos-base

# Emit just the NVR (e.g. "7.0.4-200.fc44.x86_64") to a file that
# subsequent stages will COPY in. Trailing newline is OK; $(cat ...)
# strips it via bash command-substitution semantics.
RUN rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
        > /tmp/kernel-uname-r && \
    echo "FCOS base kernel: $(cat /tmp/kernel-uname-r)"

# ── Stage 1: build kmod-nvidia RPM for that exact kernel ──────
FROM fedora:44 AS kmod-builder

# Bring the kernel NVR over from stage 0. Owner=root, mode=0644 by
# default — readable by the non-root 'builder' user we create below.
COPY --from=fcos-base /tmp/kernel-uname-r /tmp/kernel-uname-r

# RPMFusion repos for the nvidia kmod source RPM.
RUN dnf install -y \
        https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm \
        https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-44.noarch.rpm

# Enable Fedora's updates-archive repo. FCOS may track a kernel
# currently in `updates` (fresh) OR one that's already rolled into
# `updates-archive` (older). Enabling both ensures kernel-devel-
# <whatever-FCOS-has> resolves regardless of where in Fedora's
# lifecycle the kernel currently sits.
RUN dnf install -y fedora-repos-archive

# Build dependencies. kernel-devel pinned to the EXACT NVR FCOS
# ships with — read at build time from the file COPY'd in above.
# KVER_FULL: "7.0.4-200.fc44.x86_64" (uname -r format)
# KVER_NVR:  "7.0.4-200.fc44"        (Name-Version-Release, used
#                                     by the kernel-devel package suffix)
RUN KVER_FULL=$(cat /tmp/kernel-uname-r) && \
    KVER_NVR=${KVER_FULL%.x86_64} && \
    echo "Building kmod-nvidia against kernel ${KVER_FULL}" && \
    dnf install -y \
        --enablerepo=updates-archive \
        akmods \
        kernel-devel-${KVER_NVR} \
        kernel-headers \
        xorg-x11-drv-nvidia-kmodsrc \
        gcc make rpm-build

# Install akmod-nvidia for its source-rpm payload only. Its %post
# would invoke akmods → akmodsbuild as root, which refuses. Skip
# scriptlets with --setopt=tsflags=noscripts; we run akmodsbuild
# manually below as a non-root user.
RUN dnf install -y --setopt=tsflags=noscripts akmod-nvidia

RUN echo "=== /usr/src/akmods/ contents ===" && ls -la /usr/src/akmods/

# Build as non-root (the simplest way to satisfy akmodsbuild's
# `[[ -w /var ]]` check — unprivileged user lacks /var write
# permission, the check evaluates false, the build proceeds).
RUN useradd -m builder
USER builder
WORKDIR /home/builder

# Build the kmod against the FCOS kernel version detected in stage 0.
RUN KVER_FULL=$(cat /tmp/kernel-uname-r) && \
    /usr/sbin/akmodsbuild --kernels ${KVER_FULL} \
        --outputdir /home/builder \
        /usr/src/akmods/nvidia-kmod-*.src.rpm

RUN ls -la /home/builder/ && \
    echo "=== kmod-nvidia RPM requires ===" && \
    rpm -qpR /home/builder/kmod-nvidia-*.rpm

# ── Stage 2: real FCOS image ──────────────────────────────────
FROM quay.io/fedora/fedora-coreos:stable

ARG K3S_SELINUX_TAG=v1.6.stable.1
ARG K3S_SELINUX_RPM=k3s-selinux-1.6-1.coreos.noarch.rpm

LABEL org.opencontainers.image.source="https://github.com/zerosignage/coreos-nvidia"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL ostree.bootable="true"

# NOTE: NO `rpm-ostree override replace` step here. The kmod was
# built against the exact kernel-core NVR FCOS already ships, so
# there's no version mismatch to fix. When FCOS rolls forward,
# stage 0 detects the new NVR, stage 1 rebuilds against it, stage
# 2 (this stage) installs the new kmod against the matching kernel.
# Self-correcting on FCOS roll-forwards.

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

# Install the kmod (provides nvidia-kmod, satisfying the dep from
# xorg-x11-drv-nvidia-cuda) + userspace driver + container toolkit
# + k3s-selinux + ansible essentials. We deliberately do NOT install
# akmod-nvidia here — the kmod RPM produced in stage 1 is sufficient
# and akmod-nvidia would only re-trigger the build problems we just
# spent a whole afternoon designing around.
RUN ls /var/tmp/rpms/ && \
    rpm-ostree install \
        /var/tmp/rpms/kmod-nvidia-*.rpm \
        xorg-x11-drv-nvidia-cuda \
        nvidia-container-toolkit \
        python3-kubernetes \
        "https://github.com/k3s-io/k3s-selinux/releases/download/${K3S_SELINUX_TAG}/${K3S_SELINUX_RPM}"

# Force-load NVIDIA kernel modules at boot via systemd-modules-load.
# Without this, modules load lazily (first nvidia-smi call), which
# races with zsig-nvidia-cdi.service's ConditionPathExists check.
COPY modules-load.d/nvidia.conf /etc/modules-load.d/nvidia.conf

# Boot-time CDI spec generator. Regenerates /etc/cdi/nvidia.yaml on
# each boot so containers requesting `nvidia.com/gpu` see the right
# device set.
COPY systemd/zsig-nvidia-cdi.service /etc/systemd/system/
RUN systemctl enable zsig-nvidia-cdi.service

# Enable nvidia-persistenced (installed via xorg-x11-drv-nvidia-power's
# deps). Keeps the GPU in persistent mode at boot — reduces cold-start
# latency on first inference call after host idle, and ensures the
# device nodes exist before any userspace tool tries to open them.
RUN systemctl enable nvidia-persistenced.service

# Smoke check + OSTree finalize.
RUN echo "=== kernel modules in place ===" && \
    ls /lib/modules/*/extra/nvidia/ | head -5 && \
    echo "=== nvidia userspace tools ===" && \
    ls /usr/bin/nvidia-smi /usr/bin/nvidia-ctk

RUN rpm-ostree cleanup -m && \
    ostree container commit
