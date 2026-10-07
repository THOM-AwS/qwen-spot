# Component contract

Terraform, the AMI and the worker meet at these names. Change one side, change
all three.

## Paths on the instance

| Path | Owner | What |
|---|---|---|
| `/etc/qwen-spot/config.env` | user data (Terraform) | `KEY=VALUE` config, read by every unit via `EnvironmentFile=` |
| `/opt/qwen-spot/vllm-venv` | Packer | vLLM virtualenv (`vllm[runai]`) |
| `/opt/qwen-spot/worker-venv` | Packer | worker package virtualenv, entry point `qwen-worker` |
| `/opt/qwen-spot/bin/` | Packer | `vllm-start.sh`, `mount-nvme.sh`, `wait-vllm-health.sh`, `cache-sync.sh` |
| `/opt/qwen-spot/nvme` | `qwen-nvme.service` | instance-store NVMe mount (XFS, formatted every boot). Falls back to a directory on root when the instance has no instance store |
| `/var/log/qwen-spot/vllm.log`, `worker.log` | units | shipped to CloudWatch Logs by the CloudWatch agent |
| `/usr/local/bin/s5cmd` | Packer | pinned, checksum-verified |

## systemd units (installed and enabled by Packer)

| Unit | Type | Order | Notes |
|---|---|---|---|
| `qwen-nvme.service` | oneshot | before vllm | mounts instance store |
| `qwen-cwagent.service` | oneshot | after config | renders CloudWatch agent config with `QWEN_LOG_GROUP`, starts agent |
| `vllm.service` | simple | after qwen-nvme | `ExecStart=/opt/qwen-spot/bin/vllm-start.sh`, `Restart=on-failure` |
| `qwen-worker.service` | simple | after vllm | `ExecStartPre=/opt/qwen-spot/bin/wait-vllm-health.sh`, `Restart=always` |
| `qwen-cache-sync.service` | oneshot | after vllm healthy | uploads vLLM compile cache once if absent in S3 |

All units have `ConditionPathExists=/etc/qwen-spot/config.env`, so a bare AMI
boot (Packer build, debugging) starts nothing. User data writes the file and
runs `systemctl start qwen-nvme qwen-cwagent vllm qwen-worker`.

## config.env keys

| Key | Example | Used by |
|---|---|---|
| `QWEN_REGION` | `eu-north-1` | all |
| `QWEN_QUEUE_URL` | `https://sqs.eu-north-1.amazonaws.com/<acct>/qwen-spot-requests` | worker |
| `QWEN_RESULTS_BUCKET` | `qwen-spot-results-<suffix>` | worker |
| `QWEN_WEIGHTS_BUCKET` | `qwen-spot-weights-<suffix>` | vllm-start, cache-sync |
| `QWEN_ASG_NAME` | `qwen-spot-workers` | worker |
| `QWEN_MODEL_S3_URI` | `s3://<weights>/models/<model_name>/<revision>/` (trailing slash) | vllm-start |
| `QWEN_MODEL_NAME` | `qwen3.6-27b-abliterated` (name the API serves) | vllm-start, worker |
| `QWEN_WEIGHT_LOAD_MODE` | `stream` or `copy` | vllm-start |
| `QWEN_STREAMER_CONCURRENCY` | `32` | vllm-start |
| `QWEN_MAX_MODEL_LEN` | `32768` | vllm-start |
| `QWEN_GPU_MEMORY_UTILIZATION` | `0.92` | vllm-start |
| `QWEN_VLLM_EXTRA_ARGS` | `--language-model-only` (space separated) | vllm-start |
| `QWEN_ENGINE` | `gpu` or `cpu` (CPU is for the cheap end-to-end test) | vllm-start |
| `QWEN_COMPILE_CACHE_S3_URI` | `s3://<weights>/cache/vllm/<model_name>/<revision>/` or empty to disable | vllm-start, cache-sync |
| `QWEN_MTP_TOKENS` | `2` (0 = off): MTP speculative decoding | vllm-start |
| `QWEN_PREFETCH_VENV` | `1` (default): read the vLLM venv in parallel at start to hydrate the lazily restored root volume | vllm-start |
| `VLLM_USE_FLASHINFER_SAMPLER` | `1` or `0`, passed straight to vLLM | vllm |
| `QWEN_IDLE_MINUTES` | `15` | worker |
| `QWEN_WORKER_CONCURRENCY` | `8` | worker |
| `QWEN_VISIBILITY_TIMEOUT` | `900` | worker |
| `QWEN_MAX_RECEIVE_COUNT` | `5` (SQS redrive `maxReceiveCount`) | worker |
| `QWEN_MAX_ATTEMPTS` | `3` generation failures before a final error result; below max receive count because interruptions also use receives | worker |
| `QWEN_LOG_GROUP` | `/qwen-spot/worker` | cwagent |

## S3 layout

Weights bucket:
- `models/<model_name>/<revision>/` safetensors, config, tokenizer files
- `models/<model_name>/<revision>/.complete` written last by the uploader
- `cache/vllm/<model_name>/<revision>/cache-<fingerprint>.tar`: torch.compile and FlashInfer JIT caches, one per vLLM configuration (the fingerprint hashes the engine, model and arguments)

Results bucket:
- `results/<request_id>.json` result object (see README)
- `requests/<request_id>.json` large request payloads (client writes, worker reads)

## Tags

Worker instances carry `Project=qwen-spot` and `Role=worker`. The client's
`ssm:StartSession` permission is conditioned on `ssm:resourceTag/Role=worker`.
