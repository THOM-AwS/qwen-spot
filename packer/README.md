# AMI build

One template, two sources:

| Source | Base | Build instance | Root | Purpose |
|---|---|---|---|---|
| `amazon-ebs.gpu` | Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04), newest | `c7i.2xlarge` | 100 GB gp3 | H100 worker |
| `amazon-ebs.cpu` | Canonical Ubuntu 24.04 (noble), newest | `c7i.2xlarge` | 30 GB gp3 | cheap end-to-end test with a tiny model |

The gpu image is built on a CPU instance. Installing vLLM does not need a GPU;
the NVIDIA driver in the DLAMI only loads when the AMI boots on the H100.

## Build

This launches an EC2 instance and creates an AMI, both billed.

```bash
export AWS_PROFILE=<your-profile>   # confirm the account first: aws sts get-caller-identity
cd packer
packer init .
packer validate .
packer build -only='qwen-spot.amazon-ebs.gpu' .   # or qwen-spot.amazon-ebs.cpu
```

The build connects over SSM Session Manager (`session-manager-plugin` must be
installed locally). Packer's temporary security group only admits
`127.0.0.1/32`, so the build instance has no reachable inbound port. Pass
`-var security_group_id=sg-...` to use an existing no-ingress group instead. The
build needs a subnet with outbound internet access: the default VPC, or
`-var subnet_id=subnet-...`.

`manifest.json` records the AMI ID. After a build, run `scripts/prune-amis --yes`: it
keeps the newest image per engine plus any image a launch template still uses, and
deregisters the rest with their snapshots. Terraform finds the newest
`qwen-spot-<engine>-*` AMI owned by the account.

Cost: about 30 minutes on c7i.2xlarge (about 0.40 USD/hr in eu-north-1), so
roughly 0.20 USD, plus snapshot storage of about 0.05 USD per GB-month for the
retained AMI (about 30 to 40 GB of data on the gpu image).

## What gets installed

| Item | Version | Integrity check |
|---|---|---|
| uv | 0.12.23 | sha256 of release tarball, pinned |
| s5cmd | 2.3.0 | sha256 of release tarball, pinned (matches upstream `s5cmd_checksums.txt`) |
| CloudWatch agent | latest | detached GPG signature, key fingerprint pinned to `9376 16F3 450B 7D80 6CBD 9725 D581 6730 3B78 9C72` |
| vLLM (gpu) | `vllm[runai]==0.30.0` from PyPI | version pin only (see below) |
| vLLM (cpu) | `vllm-0.30.0+cpu` wheel from the vllm-project GitHub release | sha256 pinned |
| worker | `../worker` | built from this repo |

AWS publishes the CloudWatch agent only under `latest`. Versioned paths return
403, so the version cannot be pinned and the GPG signature is the check.

The gpu vLLM install pins the version but does not hash-lock the transitive
dependency tree (torch, flashinfer, CUDA wheels). A `uv pip compile
--generate-hashes` lock would tighten this; it was left out because the lock is
platform-specific and needs regenerating on every vLLM bump.

Layout and units follow [docs/contract.md](../docs/contract.md). Units are
enabled but gated on `/etc/qwen-spot/config.env`, so a bare AMI boot starts
nothing. vLLM and the worker run as the `qwen` system user. The image ships with
no SSH host keys and no authorized keys.

## Driver and CUDA compatibility (checked 2026-10-04)

- vLLM 0.30.0 (PyPI, released 2026-09-22) requires `torch==2.13.0`. That torch
  build depends on `cuda-toolkit==13.0.3` and `nvidia-*-cu13` wheels, so it is a
  CUDA 13.0 build. vLLM also pulls `nvidia-cutlass-dsl[cu13]`.
- DLAMI "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) 20260929"
  release notes: NVIDIA driver 595.91.07, default CUDA 13.2, CUDA stacks
  12.8/12.9/13.0/13.2, Python 3.12, instance store at `/opt/dlami/nvme`.
- CUDA 13.0 needs driver 580 or newer. 595.91.07 qualifies, so the default
  PyPI wheel runs on this AMI without a `--torch-backend` override.
- Qwen recommends `vllm>=0.19.0` for Qwen3.6. 0.30.0 registers the `qwen3`
  reasoning parser and the `--language-model-only` flag.
- vLLM 0.30.0 removed `--disable-log-requests` (request logging is now opt-in
  with `--enable-log-requests`). Do not add it to `QWEN_VLLM_EXTRA_ARGS`: vLLM
  exits on unknown flags.

The CPU wheel requires `torch==2.13.0+cpu` and `intel-openmp`. That torch build
only exists on `https://download.pytorch.org/whl/cpu`, which the cpu install adds
as an extra index. The third-party `vllm-cpu` PyPI package is not published by
vllm-project and is not used.
