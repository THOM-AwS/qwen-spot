# qwen-spot

Private, single-user LLM inference on one spot H100 in AWS that scales to zero.
Requests go into SQS, results come back as JSON in S3, and the GPU only runs
while there is work. Idle cost is storage (S3, AMI snapshot, one KMS key).

```
 qwenq ask ──► SQS requests ──────────────┐            (alarm: visible >= 1 sets capacity 1)
    │            │  3 receives            │
    │            └──► DLQ ──► SNS email   ▼
    │                               ASG (min 0, max 1, 100% spot, p5.4xlarge)
    │  SetDesiredCapacity(1)  ─────────►  │
    │                                     ▼
    │                     spot instance: vllm.service (127.0.0.1:8000)
    │                                    qwen-worker.service
    │                                       │ long-poll, N in parallel,
    │                                       │ heartbeat visibility,
    │                                       │ write result, delete message
    ▼                                       ▼
 poll S3 ◄────────────── results/<request_id>.json (S3, SSE-KMS)
                         idle 15 min, empty queue ─► worker sets capacity 0
```

Weights are streamed from S3 into GPU memory with vLLM's Run:ai streamer
(`--load-format runai_streamer`), so there is no model on the AMI or the root disk.

## Status (2026-10-04)

| Step | State |
|---|---|
| 1. Repo, Terraform modules, CI | done. Plan runs on every push with a read-only role; apply is manual and gated |
| 2. Worker and client, tested against moto and a fake vLLM | done; 65 tests, 87% coverage |
| Infrastructure | applied in eu-north-1; refreshed plan shows no drift |
| 3. End-to-end on a CPU spot instance with Qwen3-0.6B | passed except the price-cap test (deferred), see below |
| 4. Packer GPU AMI, 27B model upload, first H100 run | not started |
| 5. Alarms, budget, interruption handling | deployed; not yet exercised end to end |

CPU end-to-end results (spot c6i/c7i.2xlarge, Qwen3-0.6B, 2026-10-04):

| Acceptance test | Result |
|---|---|
| Cold path (`qwenq ask` at capacity 0) | pass: 163 s submit to answer (InService ~20 s, vLLM ready ~2.3 min, generate 2 s) |
| Alarm backstop (no client wake) | pass: worker InService ~90 s after the scale-out alarm's actions were enabled |
| Warm path | pass: 4 s end to end, same instance |
| Idle scale-in | pass: capacity 0 at 15 min 34 s after the last request, instance gone at 16 min 20 s; idle backstop alarm stayed OK |
| Interruption (worker killed 7 s into a 1,500-token job) | pass: replacement finished it (1,419 tokens, 81 s), `attempt: 1`, released at once rather than after the visibility timeout |
| Privacy | pass: an AdministratorAccess user is denied SQS send/receive/purge and S3 get/list/put on both buckets; worker SG has 0 ingress; both buckets block public access |
| Price cap | not run (deferred) |

Bugs the run found and fixed: CPU image dependencies (torchvision, torchcodec, OpenMP
preload, Python headers; the AMI build now smoke-tests `vllm serve`), the worker role
missing read/list on `results/` (S3 returns AccessDenied, not 404, without list), the
uploader on an instance type not offered in eu-north-1, `tf-quiet.sh` reporting
failures as success, and `qwenq wait` re-waking a group that had been set to 0.

H100 (p5.4xlarge spot, huihui Qwen3.6 27B abliterated, 2026-10-05):

| Item | Result |
|---|---|
| Spot capacity | eu-north-1a/b reject p5.4xlarge spot outright; 1c has a small pool (placement score 1/10). First launch took 11 min, the second 61 min. |
| Weights | 1,199 tensors (55.6 GB) streamed from S3 in 27 s; model load 51.1 GiB in 33 to 52 s |
| Engine | KV cache 18.8 GiB, 267k tokens, 8 concurrent 32k-token requests |
| Startup fixes found live | `max_num_seqs` 1024 does not fit Qwen3.6's per-sequence Mamba state (350 blocks): now 64. FlashInfer JIT-compiles its GDN prefill and sampler kernels and the image has no `ninja`: GDN prefill uses triton and `VLLM_USE_FLASHINFER_SAMPLER=0`. |
| Answers | correct; 54 tokens in 1.2 s (about 45 tok/s single stream); warm request 4 s end to end |
| Session tunnel | blocked by a client policy bug (`Bool` instead of `BoolIfExists` on `ssm:SessionDocumentAccessCheck`), fixed |

Still to do: measure a clean cold start with the fixes baked in, re-run `qwenq session`, and add `ninja` to the
image to bring back FlashInfer's kernels.

### Manual changes

| When (UTC) | Change | Why | Undo |
|---|---|---|---|
| 2026-10-04 08:20 | `aws cloudwatch disable-alarm-actions --alarm-names qwen-spot-scale-out` | A queued test request kept waking a worker on the broken AMI, which never becomes healthy and so never scales in | Resolved: the 12:12 apply re-enabled it |
| 2026-10-04 11:02 | Same again, plus `set-desired-capacity 0` | The rebuilt CPU AMI still failed at `vllm serve` (PyPI torchcodec is a CUDA build: `libnvrtc.so.13` missing) | Resolved: the 12:12 apply re-enabled it |
| 2026-10-05 00:34 | `disable-alarm-actions` on `qwen-spot-stalled` and `qwen-spot-idle-backstop`; worker subnets cut to eu-north-1c in the console | Live troubleshooting of the first H100 boot (vLLM refused to start: `max_num_seqs` 1024 > 350 Mamba cache blocks) without the breaker stopping the box; only 1c has p5.4xlarge spot | Resolved: alarms re-enabled 02:45 UTC; subnets codified as `worker_availability_zones` (default `["eu-north-1c"]`) |
| 2026-10-05 00:35 | Live edit of `/etc/qwen-spot/config.env` on the H100 (`QWEN_VLLM_EXTRA_ARGS="--max-num-seqs 64"`), vLLM restarted | Same | Codified as `max_num_seqs` (default 64); lost when that instance goes |

## Checked facts (2026-10-04)

| Question | Finding |
|---|---|
| Default model repo | `huihui-ai/Huihui-Qwen3.6-27B-abliterated` at `27502c8717fd5a2f8c0c77188c10c243fd4f672e`. Apache-2.0, not gated. 15 bf16 safetensors shards, 55.6 GB, no pickle files. The tensor map (1199 tensors, including the vision tower and MTP head) matches official `Qwen/Qwen3.6-27B`. |
| Alternative model | `wangzhang/Qwen3.6-27B-abliterated` at `9637e79...`. Apache-2.0, 2 safetensors shards, 54.7 GB. **It looks like a broken export:** the 333 vision tensors are nested as `model.language_model.visual.*` instead of `model.visual.*`, there is no MTP head, and `preprocessor_config.json` is missing. Expect vLLM to fail loading it. To try it anyway, set `vllm_extra_args = "--language-model-only"`. |
| Architecture | `Qwen3_5ForConditionalGeneration` (`model_type` `qwen3_5`): a hybrid of linear attention (Gated DeltaNet) and full attention, 64 layers, 262k native context, multimodal |
| vLLM version | Qwen recommends `vllm>=0.19.0`. Pinned to **0.30.0** (latest, 2026-09-22). Its wheel needs torch 2.13 / CUDA 13.0, and the DLAMI driver (595.91.07) supports that. See `packer/README.md`. |
| Deep Learning AMI | `Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) 20261002` (`ami-0f56562c7bd805c4f` in eu-north-1). Packer resolves the newest one by name at build time. |
| p5.4xlarge | 16 vCPU, 256 GiB RAM, 1x H100 80 GB, 100 Gbit network, **one 3,800 GB instance-store NVMe** (so `copy` mode works). |
| eu-north-1 AZs | p5.4xlarge is offered in 1a, 1b and 1c, **but spot price history over the last 7 days exists only in eu-north-1c** (1.13 to 1.64 USD/hr, 1.64 now). In practice spot is single-AZ. |
| Spot quota | p5.4xlarge needs 16 vCPUs of "All P Spot Instance Requests" in the region. New accounts often have 0; check with `scripts/check-quotas`. |
| Cheapest region now | eu-north-1c at 1.61 USD/hr. The next cheapest is us-west-2d at 2.63. |

## Design notes

- **Account choice.** Prefer a dedicated member account. Service control policies
  never apply to an AWS Organizations management account, so there the only guards
  are the IAM scoping, the spot price cap, the alarms and the budget.
- **Clients assume a role.** No policy is attached to a user. `client_principal_arns`
  may assume `qwen-spot-client`, which carries the permissions boundary, so a
  change to the client policy can never grant a human principal more than the
  boundary allows.
- **Default model** is huihui-ai rather than wangzhang (see above). wangzhang is
  one variable away.
- **Encryption** uses one customer-managed KMS key (rotation on) for both buckets,
  both queues, the SNS topic, the log groups and the EBS volumes. That adds 1 USD a month to the idle cost.
- **Model upload** runs on an on-demand `m5d.2xlarge` in its own Auto Scaling
  group at desired 0, instead of an ad-hoc instance. `scripts/upload-model` sets
  that group to 1; the instance uploads, writes `.complete`, and sets the group
  back to 0. It is all in Terraform and leaves nothing behind.
- **CI** runs on GitHub-hosted runners: they are free for public repos, and
  self-hosted runners on a public repo would run strangers' PR code on private hardware.
  `ci.yml` has no AWS access. `terraform.yml` plans on every push with a read-only role and applies only on
  manual dispatch from `main`, behind the `aws` environment's reviewer, through OIDC.
- **Retries** are counted by the worker, not by the SQS receive count, because spot
  hand-backs also raise the receive count. `maxReceiveCount` is 5. See "How
  failures behave".
- **Result objects** carry `attempt` and `final`. A failed attempt that will be
  retried is written with `final: false`, and the client keeps waiting.
- **Termination** has two triggers: the spot interruption notice and the ASG
  target lifecycle state `Terminated`. When either fires, in-flight messages are
  released at once.

## Setup

One-time steps, in order. Every step that writes to AWS costs money or changes
IAM; review each plan before applying.

1. **State backend.** Copy `terraform/backend.hcl.example` to `terraform/backend.hcl`
   (gitignored) with your state bucket and its region.
2. **Bootstrap** the CI role once with admin credentials (CI cannot create the role
   it runs as). See [`terraform/bootstrap/README.md`](terraform/bootstrap/README.md).
   This also activates `Project` as a cost allocation tag, which the budget filters on.
3. **GitHub.** Environment `aws`: a required reviewer, deployments limited to
   `main`, and secret `AWS_ROLE_ARN` (the write role). Repository secrets for the
   plan job: `AWS_PLAN_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_STATE_REGION`, and `TFVARS`
   (the contents of your `terraform/terraform.tfvars`, see `terraform.tfvars.example`).
   Secrets rather than variables, so the values are masked in public workflow logs.
4. **Infrastructure.** Every push that touches `terraform/` runs a read-only plan
   (no approval). To apply: Actions > terraform > Run workflow > `apply` on `main`;
   it plans, waits for the reviewer, re-plans and applies only if nothing changed. Confirm the SNS subscription email afterwards.
5. **Spot quota.** `scripts/check-quotas`; request an increase if it reports less
   than 16 P-family spot vCPUs.

## Deploy

```bash
export AWS_PROFILE=<your-profile>
aws sts get-caller-identity                 # confirm the account before anything else

# 1. AMI (about 0.20 USD, about 30 min on a c7i.2xlarge; needs packer >= 1.14 and session-manager-plugin)
cd packer && packer init . && packer build -only='qwen-spot.amazon-ebs.gpu' . && cd ..
#    then run the terraform workflow again so the launch template picks up the AMI

# 2. weights (about 0.50 USD on-demand m5d.2xlarge, 15 to 30 min)
scripts/upload-model

# 3. client
uv tool install ./client          # or: uv run qwenq ...
qwenq configure --terraform-dir terraform   # needs terraform output access, or write ~/.config/qwenq/config.json by hand
```

## Use

`qwenq` runs as the `qwen-spot-client` role: only that role and the worker can
use the queue and the results bucket. Add a profile that assumes it (the ARN is
the `client_role_arn` output), and allow your user `sts:AssumeRole` on it:

```ini
# ~/.aws/config
[profile qwen-spot]
role_arn       = arn:aws:iam::<account>:role/qwen-spot-client
source_profile = <your-profile>
region         = eu-north-1
```

Then `export AWS_PROFILE=qwen-spot`, or pass `--profile qwen-spot`.

```bash
qwenq ask "Explain the CAP theorem in two sentences" --no-think
qwenq submit -f request.json      # prints a request id; see Message schema below
qwenq wait <request_id> --json
qwenq status                      # desired capacity, instances and uptime, queue/DLQ depth, spot price per AZ
qwenq up / qwenq down             # manual capacity
qwenq tunnel                      # SSM port-forward localhost:8000 -> vLLM (needs session-manager-plugin)
scripts/spot-prices --types p5.4xlarge
scripts/check-quotas
```

`ask` and `submit` wake the group when it is at 0. `wait` only polls for the
result and never changes capacity, so a `qwenq down` is not undone.


### Interactive use (no queue)

Every `ask`/`submit` goes through SQS, which suits batch work and survives spot
interruptions but cannot stream. For interactive work, open a session:

```bash
AWS_PROFILE=qwen-spot qwenq session            # wakes the GPU, opens an SSM tunnel, prints:
# export OPENAI_BASE_URL=http://127.0.0.1:8000/v1
# export OPENAI_API_KEY=unused
```

Any OpenAI-compatible client then talks to vLLM directly, with streaming: the
`openai` SDK, curl, Aider, Continue, LangChain. Use the model name from
`qwenq status` (default `qwen3.6-27b-abliterated`). The session ends on Ctrl-C or
after `--max-hours` (default 2, a cost guard); `--down` also sets capacity to 0.

The worker reads vLLM's `/metrics`, so tunnel traffic counts as activity and the
instance is not scaled in under you. It publishes `QwenSpot/Busy`, which the
idle backstop alarm also respects. Once the session ends, the normal 15-minute
idle scale-in applies.

From Python, `qwenq.client.chat()` uses the tunnel when a session is open and
the queue otherwise, with the same result shape (plus `via`). It only trusts a
tunnel that a live `qwenq session` opened on that port and that serves the
configured model, so a prompt never goes to some other local process that happens
to listen on 8000:

```python
from qwenq.client import chat

result = chat([{"role": "user", "content": "Summarise RFC 9110 in one line"}], params={"max_tokens": 128})
print(result["via"], result["output"])
```

### Message schema

```json
{"request_id": "uuid", "messages": [{"role": "user", "content": "..."}],
 "params": {"max_tokens": 2048, "temperature": 0.7}, "metadata": {}}
```

- `params` is an allow-list of sampling settings: `max_tokens`, `temperature`,
  `top_p`, `top_k`, `min_p`, penalties, `stop`, `seed`, `n`, `response_format`,
  `chat_template_kwargs`. Anything else is rejected, so a request cannot pick
  another model.
- `request_id` must be a canonical UUID, because it becomes an S3 key.
- Requests over 256 KiB are written to `requests/<id>.json` in the results
  bucket. The queue message then only carries `{"request_id", "payload_key"}`.

### Result schema

```json
{"request_id": "uuid", "status": "ok | error", "output": "...", "reasoning": "...",
 "usage": {"prompt_tokens": 0, "completion_tokens": 0},
 "timings": {"queued_s": 0, "generation_s": 0}, "error": null,
 "attempt": 1, "final": true, "model": "qwen3.6-27b-abliterated", "metadata": {}, "finished_at": 0}
```

## How failures behave

| Event | Behaviour |
|---|---|
| No spot capacity, or price above `spot_max_price` | The ASG cannot launch and requests wait in the queue. After 20 minutes the oldest-message alarm emails you. There is never an on-demand fallback. |
| vLLM 5xx or timeout | An error result is written with `final: false`, and the message retries after 30 s times the attempt number. The worker counts real generation attempts (`attempt` in the result). The third failure (`max_attempts`) writes `final: true` and deletes the message. |
| vLLM 4xx (bad params, prompt too long) | Final error result; the message is deleted. No retry. |
| Malformed message | Error result if the id is readable; the message is deleted. |
| Spot interruption or ASG termination | The worker stops receiving and sets in-flight messages to visibility 0. The next instance picks them up. Hand-backs raise the SQS receive count but not `attempt`. That is why the queue's `maxReceiveCount` is 5 (`max_receive_count`) rather than the brief's 3: the DLQ only catches messages that keep killing the worker, and the worker writes a final error result on the last receive. |
| Message arrives while the worker scales in | The queue counts lag, so 15 s after setting capacity 0 the worker checks the queue again and sets capacity back to 1 if anything is there. The scale-out alarm is the second backstop. `qwenq wait` never changes capacity, so `qwenq down` sticks. |
| Duplicate delivery | If an `ok` result already exists, the worker deletes the message without generating. |
| Instance up longer than `max_uptime_hours` | Email only. Nothing is terminated. |
| Worker idle but does not scale itself in | The idle backstop alarm: in service with nothing waiting or in flight for `idle_backstop_minutes` (18) sets capacity to 0 and emails. |
| Worker up but taking nothing (vLLM never healthy, worker crashed) | Requests age past `stuck_queue_seconds` (20 min) with nothing in flight. The `stalled` alarm sets capacity to 0 and emails, and the scale-out alarm stops waking the group for requests that old, so the broken worker is not relaunched every minute. A `qwenq ask` still wakes it. Worst case is about 25 minutes of instance time. |

## Cost

- **Idle:** about 1 USD/month for the KMS key, plus about 1.3 USD/month to keep
  55 GB of weights in S3, plus AMI snapshot storage of about 2 USD/month.
- **One cold 5-minute job:** about 25 minutes of instance time. That breaks down
  as roughly 4 to 5 minutes of boot and load, 5 minutes of work, and 15 minutes of
  idle. At 1.64 USD/hr this is about 0.70 USD. A shorter `idle_minutes` saves
  about 0.27 USD per 10 minutes but cold-starts more often.
- **Cold-start target** is under 5 minutes to first token. Not measured yet.
- **Risk to measure on the first run:** EBS volumes restored from a snapshot load
  lazily. vLLM's first import of torch and CUDA libraries (several GB) reads
  blocks from S3 on demand, and that can add minutes to every cold start.

## Known limitations

- **The alarm backstop is slow.** SQS metrics resume up to 15 minutes after an
  inactive queue gets a message. Until then the alarm sees nothing. The
  client's wake call is the fast path, and the alarm only covers a skipped call.
- **`allowed_cidrs` is weak behind CGNAT.** If your ISP puts you behind carrier-grade
  NAT, your public IPv4 is shared with other customers, and requests may also
  leave over IPv6. A `SourceIp` pin on a shared address admits everyone behind it,
  and it can block you on IPv6.
- **Budget and cost tag.** The budget sees nothing until you activate `Project`
  as a cost allocation tag. That is a one-time human step in Billing.
- **Unlocked transitive dependencies.** The gpu vLLM install pins vLLM 0.30.0
  but does not hash-lock torch and the CUDA wheels it pulls in.

## Layout

```
terraform/            root stack + modules (network, storage, queue, iam, compute, alarms); bootstrap/ = CI role
packer/               AMI (gpu: DLAMI base; cpu: Ubuntu, for the cheap end-to-end test), systemd units, start scripts
worker/               qwen_worker package (runs on the instance)
client/               qwenq CLI
scripts/              upload-model, upload_model.py (on the uploader), spot-prices, check-quotas
tests/                pytest, moto, fake vLLM
docs/contract.md      names shared by Terraform, the AMI and the worker
```

## Development

```bash
uv sync
uv run pytest --cov            # moto + fake vLLM, no AWS
uv run ruff check . && uv run ruff format --check . && uv run mypy worker/src client/src
cd terraform && terraform init -backend=false && terraform validate && tflint --recursive
```

## Licence

[0BSD](LICENSE): do anything with it, no attribution required.
