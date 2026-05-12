# syntax=docker/dockerfile:1.6
#
# Custom Fedora CoreOS + NVIDIA proprietary driver OCI image, built for
# zerosignage on-prem GPU hosts (currently: r1.0cs.lan, RTX 3090 Ti).
#
# The kernel-devel-matching dance that bites everyone hand-installing
# akmod-nvidia on FCOS (FCOS ships a `-101.fc44` kernel respin for
# which no public kernel-devel matches) is resolved here, once, at
# image-build time: we override-replace FCOS's kernel package set
# with Fedora's standard `-300.fc44` build of the same upstream
# version. Then akmod-nvidia resolves cleanly, and we precompile the
# kernel module so the image ships with it baked in. Target hosts
# boot straight into a working driver.
#
# Output: OSTree-aware OCI image at ghcr.io/zerosignage/coreos-nvidia.
# Consume via: rpm-ostree rebase ostree-unverified-registry:<path>:stable

FROM quay.io/fedora/fedora-coreos:stable

ARG K3S_SELINUX_TAG=v1.6.stable.1
ARG K3S_SELINUX_RPM=k3s-selinux-1.6-1.coreos.noarch.rpm

LABEL org.opencontainers.image.source="https://github.com/zerosignage/coreos-nvidia"
LABEL org.opencontainers.image.description="Fedora CoreOS + NVIDIA proprietary driver + nvidia-container-toolkit + k3s-selinux, ready for k3s GPU workloads"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL ostree.bootable="true"

# ── 1. Replace the FCOS kernel respin (-101) with Fedora's matching
# `-300.fc44` upstream build so akmod-nvidia's build dependency on
# kernel-devel-matched is satisfiable. We pull from updates-archive
# rather than updates because the matching -300 build often lands in
# archive before akmod-nvidia in nonfree-updates catches up.
RUN rpm-ostree override replace \
        --experimental \
        --from repo=updates-archive \
        kernel kernel-core kernel-modules kernel-modules-core

# ── 2. RPMFusion (free + nonfree) provides akmod-nvidia + the matching
# CUDA userspace driver packages.
RUN rpm-ostree install \
        https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
        https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# ── 3. NVIDIA-published container-toolkit repo. Not in RPMFusion;
# only NVIDIA hosts it. Local repo file means no GPG-key fetch over
# TLS at install time (which has its own intermittent failure modes).
RUN curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo

# ── 4. Layer the NVIDIA stack + k3s-selinux + ansible-side essentials
# in one transaction so the depsolve happens once cleanly. akmod-nvidia
# pulls in akmods, gcc, make, kernel-devel-matched as dependencies.
RUN rpm-ostree install \
        kernel-devel \
        akmod-nvidia \
        xorg-x11-drv-nvidia-cuda \
        nvidia-container-toolkit \
        python3-kubernetes \
        "https://github.com/k3s-io/k3s-selinux/releases/download/${K3S_SELINUX_TAG}/${K3S_SELINUX_RPM}"

# ── 5. Pre-build the NVIDIA kernel module against the (now-matched)
# kernel-devel. Without this, akmods would run on first boot of the
# target host — which is the exact fragility we are trying to avoid.
# After this RUN, `/lib/modules/<kver>/extra/nvidia/` is populated.
RUN KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -1) && \
    akmods --force --kernels "$KVER" && \
    depmod -a "$KVER"

# ── 6. Boot-time CDI spec generator. Containers requesting GPUs via
# `nvidia.com/gpu=all` or `runtimeClassName: nvidia` read the spec
# from /etc/cdi/nvidia.yaml; we regenerate it on every boot so the
# spec always matches the running driver version.
COPY systemd/zsig-nvidia-cdi.service /etc/systemd/system/
RUN systemctl enable zsig-nvidia-cdi.service

# ── 7. Finalize as an OSTree commit. Without this step the image
# is a plain OCI image, not rebaseable via rpm-ostree.
RUN rpm-ostree cleanup -m && \
    ostree container commit
