# Two-stage build with dynamic kernel resolution:
#
# Stage 1 ("kmod-builder"): regular Fedora 44 image. Install
# kernel-devel WITHOUT a version pin — let dnf pick whatever the
# latest available release is in updates / updates-archive. Record
# the resolved NVR to /home/builder/kernel-uname-r. Build kmod
# against THAT version. Drop the file alongside the produced RPM
# so stage 2 can read it back.
#
# Stage 2 (final FCOS image): COPY both the kmod RPM and the
# kernel-uname-r record. Use `rpm-ostree override replace
# --from repo=updates-archive kernel kernel-core kernel-modules
# kernel-modules-core` — rpm-ostree picks the LATEST available in
# the repo, which is the same version dnf picked in stage 1 (both
# stages run within seconds of each other against the same
# repo metadata snapshot). The verify step at the end asserts the
# installed kernel NVR matches what stage 1 built against.
#
# Why this design beats hardcoded pins:
#   - When Fedora's archive rolls (older releases age out, newer
#     ones land), the build adapts automatically. No Containerfile
#     edits.
#   - Both kmod and FCOS kernel-replace target the SAME version
#     within one build, so they can never mismatch.
#
# Why FCOS's own kernel can't be the target:
#   - FCOS ships kernel-core-${V}-101.fc44 (the `-101` release is
#     CoreOS-internal). Fedora's main + updates + updates-archive
#     repos only have `-200` / `-300` releases (Fedora-mainline
#     builds). So `kernel-devel-${V}-101.fc44` is unavailable to
#     build a matching kmod. Hence we always override-replace
#     FCOS's `-101` kernel to a Fedora-mainline release and build
#     the kmod against that. This is what the original Containerfile
#     did with a hardcoded `-300`; we just dynamize the choice.

# ── Stage 1: install latest available kernel-devel + build kmod ──
FROM fedora:44 AS kmod-builder

# RPMFusion repos for the nvidia kmod source RPM.
RUN dnf install -y \
        https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm \
        https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-44.noarch.rpm

# Enable Fedora's updates-archive repo. The latest available
# kernel-devel for fc44 may sit in `updates` (fresh) OR in
# `updates-archive` (older), depending on Fedora's lifecycle phase.
# Both enabled covers either case.
RUN dnf install -y fedora-repos-archive

# Pin kernel-devel to the LATEST VERSION IN updates-archive --
# the same repo stage 2's `override replace --from
# repo=updates-archive` pulls from. Resolving "latest across all
# repos" instead let stage 1 pick a newer kernel from `updates`
# (e.g. 7.1.10) than stage 2 could get from updates-archive
# (7.1.9), so the stage-2 sanity check aborted every build once
# the two repos skewed. Pinning to one repo makes the two stages
# agree by construction.
RUN KVER=$(dnf repoquery --disablerepo='*' --enablerepo=updates-archive \
        --latest-limit=1 --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core \
        | tail -1) && \
    test -n "$KVER" && \
    echo "Pinning kernel to updates-archive latest: $KVER" && \
    dnf install -y --enablerepo=updates-archive \
        akmods \
        kernel-devel-$KVER \
        kernel-headers \
        xorg-x11-drv-nvidia-kmodsrc \
        gcc make rpm-build

# Capture the exact kernel-devel NVR dnf actually installed. This
# is the version stage 2 will need to override-replace FCOS's
# kernel to.
RUN rpm -q kernel-devel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
        > /tmp/kernel-uname-r && \
    echo "Resolved kernel-devel: $(cat /tmp/kernel-uname-r)"

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

# Stage the kernel-uname-r file into builder's home (root-owned
# /tmp file isn't accessible after USER switch on some buildah
# versions; copying first avoids race + permission issues).
RUN cp /tmp/kernel-uname-r /home/builder/kernel-uname-r && \
    chown builder:builder /home/builder/kernel-uname-r

USER builder
WORKDIR /home/builder

# Build the kmod against the resolved kernel NVR.
RUN KVER_FULL=$(cat /home/builder/kernel-uname-r) && \
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

# Bring in the kernel-uname-r record from stage 1 + the produced
# kmod RPM. We do the override-replace FIRST so the rest of the
# install picks up against the new kernel.
COPY --from=kmod-builder /home/builder/kernel-uname-r /tmp/kernel-uname-r
COPY --from=kmod-builder /home/builder/kmod-nvidia-*.rpm /var/tmp/rpms/

# Override-replace FCOS's CoreOS-internal `-101` kernel with the
# Fedora-mainline release that stage 1 built against. `--from
# repo=updates-archive` picks the latest available in the repo,
# which should be the same version stage 1 resolved a few seconds
# earlier (same repo snapshot). The sanity check below verifies.
RUN rpm-ostree override replace \
        --experimental \
        --from repo=updates-archive \
        kernel kernel-core kernel-modules kernel-modules-core

# Sanity: confirm the kernel rpm-ostree installed matches what
# stage 1 built kmod against. If they diverge (e.g. repo rolled
# between stages — vanishingly unlikely but possible), the
# subsequent install would fail with a depsolve error and produce
# a confusing message. Better to fail loudly here.
RUN EXPECTED=$(cat /tmp/kernel-uname-r) && \
    ACTUAL=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n') && \
    if [ "$EXPECTED" != "$ACTUAL" ]; then \
        echo "ABORT: stage 1 built kmod for $EXPECTED but FCOS now has $ACTUAL" >&2 ; \
        echo "Repo rolled between stage 1 and stage 2 of this build. Retry." >&2 ; \
        exit 1 ; \
    else \
        echo "kmod ↔ FCOS kernel version match: $EXPECTED" ; \
    fi

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

# Install the kmod (provides nvidia-kmod, satisfying the dep from
# xorg-x11-drv-nvidia-cuda) + userspace driver + container toolkit
# + k3s-selinux + ansible essentials.
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
