# coreos-nvidia

Custom Fedora CoreOS OCI image with NVIDIA proprietary driver,
nvidia-container-toolkit, and k3s-selinux pre-installed. Built for
on-prem GPU hosts in the zerosignage platform.

Image: **`ghcr.io/zerosignage/coreos-nvidia`**

## What's in it

| Component | Source | Why |
|---|---|---|
| Fedora CoreOS | `quay.io/fedora/fedora-coreos:stable` | Atomic-update host OS |
| Kernel (`-300.fc44`) | Fedora `updates-archive` (overrides FCOS's `-101` respin) | So `kernel-devel` exists and `akmod-nvidia` builds cleanly |
| NVIDIA proprietary driver | RPMFusion `akmod-nvidia` | Compiled at image build time; module ships in the image |
| `nvidia-container-toolkit` | NVIDIA RPM repo | Exposes GPU to containerd/podman via CDI |
| `k3s-selinux` | k3s-io GitHub releases | Allow rules for k3s on SELinux-enforcing FCOS |
| `python3-kubernetes` | Fedora `updates` | Required by the platform repo's k8s ansible modules |

## Tags

| Tag | Meaning |
|---|---|
| `stable` | Latest successful build from `main`. Floating — moves on each successful build. |
| `stable-<sha>` | Immutable tag for a specific commit. Use this when pinning a host. |

## Deploying to a target host

Initial rebase from vanilla FCOS:

```bash
sudo rpm-ostree rebase --bypass-driver \
  ostree-unverified-registry:ghcr.io/zerosignage/coreos-nvidia:stable
sudo systemctl reboot
```

After reboot, verify:

```bash
nvidia-smi                       # GPU + driver version
lsmod | grep ^nvidia             # Kernel module loaded
systemctl status zsig-nvidia-cdi.service
ls /etc/cdi/nvidia.yaml          # CDI spec generated
```

Updating an already-rebased host (pulls the new digest behind the
`:stable` tag):

```bash
sudo rpm-ostree upgrade --bypass-driver
sudo systemctl reboot
```

Pinning to a specific build (reproducibility):

```bash
sudo rpm-ostree rebase --bypass-driver \
  ostree-unverified-registry:ghcr.io/zerosignage/coreos-nvidia:stable-<sha>
sudo systemctl reboot
```

## Prerequisites on the target host

- **Secure Boot disabled** in firmware. The akmod-built NVIDIA module
  is not signed with a key your firmware would trust by default. We
  do not ship a MOK; the design assumes Secure Boot is off.
- **Above 4G Decoding** and **Resizable BAR** enabled. Required for
  modern NVIDIA GPUs to expose their full VRAM via PCIe BAR.
- **PCIe x16 slot** populated with an NVIDIA card that the driver
  branch in use (currently 580) supports.

The platform repo's Butane source for fresh-install hosts lives at
`platform/files/onprem/r1.bu`. Use it for the first install, then
rebase to this image as the second step.

## Build

The GHA workflow `.github/workflows/build.yml` builds on:

- push to `main` when `Containerfile`, `systemd/**`, or the workflow
  itself changes
- weekly cron (Mondays 02:00 UTC) to pick up FCOS / RPMFusion /
  NVIDIA driver bumps
- `workflow_dispatch` for manual rebuilds

The image is OSTree-aware (ends with `ostree container commit`), so
the runner uses `redhat-actions/buildah-build@v2` rather than the
plain docker/build-push-action. Build wall-time is ~10–15 min, mostly
the akmodsbuild step.

Local build for testing (requires podman + buildah on the laptop):

```bash
podman build -t coreos-nvidia:test -f Containerfile . \
  --device /dev/fuse --security-opt label=disable
```

## Trust chain

- **Fedora CoreOS** — Red Hat / Fedora project
- **RPMFusion** — community packaging project since 2008
- **NVIDIA** proprietary blob — redistributed under NVIDIA's EULA
- **k3s-selinux** — from k3s-io's GitHub releases (SHA-pinned in
  `Containerfile` via the `K3S_SELINUX_TAG` arg)
- **This image** — built by zerosignage's GitHub Actions, pushed to
  GHCR, signed by the runner's `GITHUB_TOKEN`

The Containerfile is the complete recipe — reproducible from source.

## License

Apache-2.0; see `LICENSE`. Covers the files in this repository.
Bundled packages retain their own licenses (NVIDIA EULA, GPLv2 for
akmod wrappers, etc.).
