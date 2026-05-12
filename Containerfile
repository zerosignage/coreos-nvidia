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

# ── 2a. Fix the legacy CA-bundle symlink that FCOS 44 omits but
# rpm-ostree's libcurl expects when it goes to fetch a repo's GPG key
# over TLS. Without this, `rpm-ostree install` from any repo with a
# remote `gpgkey=https://...` fails with curl error 77 ("CA cert
# bundle access"), even though regular curl works fine. Same bug we
# hit during r1's manual install dance. Also re-extract the trust
# store so every consumer (java, openssl, pem) is consistent.
RUN ln -sf /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
           /etc/pki/tls/certs/ca-bundle.crt && \
    update-ca-trust extract

# ── 3. NVIDIA-published container-toolkit repo. We pre-download the
# GPG key into the rpm keyring AND point the repo file at the local
# copy of the key, so rpm-ostree never has to make a TLS roundtrip
# for it. This avoids the "rpm-ostree can't open ca-bundle.crt"
# class of failures even if upstream's TLS chain or our trust store
# wobbles in the future.
RUN curl -fsSL -o /etc/pki/rpm-gpg/nvidia-container-toolkit.gpg \
        https://nvidia.github.io/libnvidia-container/gpgkey && \
    rpm --import /etc/pki/rpm-gpg/nvidia-container-toolkit.gpg && \
    curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo && \
    sed -i 's|^gpgkey=.*|gpgkey=file:///etc/pki/rpm-gpg/nvidia-container-toolkit.gpg|' \
        /etc/yum.repos.d/nvidia-container-toolkit.repo

# ── 3a. Pre-install akmods + patch its root check. akmod-nvidia's
# post-install scriptlet invokes `akmodsbuild` to compile the kernel
# module; `akmodsbuild` refuses to run as root for desktop-safety
# reasons. In a Containerfile build we ARE root, with no clean way
# to drop privileges from inside an rpm-ostree post-install hook,
# so we neutralize the check: replace every `$EUID` reference with
# `$NOT_CHECKING_ROOT_IN_CI_BUILDS`. The replacement variable is
# undefined, Bash expands it to empty, the `[[ "" = "0" ]]` test
# evaluates false, the build proceeds.
RUN rpm-ostree install akmods && \
    sed -i 's/\$EUID/\$NOT_CHECKING_ROOT_IN_CI_BUILDS/g' /usr/sbin/akmodsbuild && \
    grep NOT_CHECKING_ROOT_IN_CI_BUILDS /usr/sbin/akmodsbuild | head -1

# ── 4. Layer the NVIDIA stack + k3s-selinux + ansible-side essentials.
# akmod-nvidia's post-install scriptlet now succeeds because the
# previously-installed akmodsbuild has been patched in 3a.
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
