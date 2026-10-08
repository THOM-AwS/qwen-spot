# Bootstrap: GitHub Actions roles

Creates `qwen-spot-github-actions`, the role `.github/workflows/terraform.yml`
assumes through the account's existing GitHub OIDC provider
(`token.actions.githubusercontent.com`; create one first if the account has none).
The trust is pinned to the repo's immutable OIDC subject plus the `aws` environment,
so only jobs running in that environment can assume it, and a renamed or
re-registered repo name cannot take it over. For a fork, set `github_sub_prefix`
from `gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix`.

It also creates `qwen-spot-github-plan`, a read-only role for the plan job, which
runs on every push to any branch with no approval. That role trusts branch
subjects only (`...:ref:refs/heads/*`), can read project resource configuration
and the state file, plans with `-lock=false`, and can change nothing. The write
role is explicitly barred from editing it, since anything granted to it would be
usable without review.

CI cannot create the role it runs as, so a human applies this stack once with
admin credentials:

```bash
cd terraform/bootstrap
export AWS_PROFILE=<admin-profile>
aws sts get-caller-identity                     # confirm the account
cat > terraform.tfvars <<'TFVARS'               # gitignored
state_bucket = "<state bucket from ../backend.hcl>"
TFVARS
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan
terraform apply tfplan
terraform output -raw role_arn
```

Then in GitHub, repo Settings > Environments > `aws`:

1. **Required reviewer: optional.** An apply already needs a deliberate workflow
   run on `main`, and it re-plans and stops if the summary differs from the plan
   job's. Add a reviewer only if you want a second click before every apply.
2. **Deployment branches: `main` only.** The OIDC trust pins the environment,
   not the branch, so this setting is what stops a dispatched feature branch
   from assuming the role. The workflow also checks `github.ref`.
3. Secrets (not variables, so they are masked in public logs):
   - **Environment `aws`:** `AWS_ROLE_ARN` = the `role_arn` output.
   - **Repository** (the plan job has no environment): `AWS_PLAN_ROLE_ARN` = the
     `plan_role_arn` output, `TF_STATE_BUCKET` and `TF_STATE_REGION` = the values
     in `backend.hcl`, `TFVARS` = the full contents of `terraform/terraform.tfvars`.

## What the role can do

No `PowerUserAccess`. Two inline policies:

- `qwen-spot-services`: EC2 and Auto Scaling, only in `region`. Changing,
  stopping or deleting an existing EC2 or Auto Scaling resource requires the tag
  `Project=qwen-spot`, and tagging an existing resource requires that tag already,
  so the guard cannot be sidestepped by re-tagging. Copying, sharing or exporting
  snapshots and images, and swapping instance profiles, are denied outright.
  SQS, SNS, S3, logs, CloudWatch alarms and budgets are limited to `qwen-spot-*`
  names. KMS is limited to keys tagged `Project=qwen-spot`. It can read public SSM
  parameters. `sts:AssumeRole`, `organizations:*`, `account:*`, `sso:*`,
  `sso-directory:*` and `identitystore:*` are explicitly denied, so the role cannot
  hop into member accounts or touch Identity Center.
- `qwen-spot-iam-scoped`: named IAM actions on `qwen-spot-*` roles, policies
  and instance profiles only.
  - New roles must carry the `qwen-spot-boundary` permissions boundary (this
    stack creates it). The boundary caps any qwen-spot role at the actions the
    worker and uploader use, on `qwen-spot-*` buckets, queues, groups, log
    groups and `/qwen-spot/*` parameters, and keys tagged `Project=qwen-spot`.
    It denies all of IAM, Organizations and `sts:AssumeRole`. No project role can
    read another stack's bucket or state.
  - Attach and detach are limited to `qwen-spot-*` policies plus
    `AmazonSSMManagedInstanceCore`.
  - `iam:PassRole` is only to `ec2.amazonaws.com`.
  - Explicit denies: any IAM write to the CI role itself, any edit to the
    boundary policy, removing a permissions boundary, and any trust policy
    change (`iam:UpdateAssumeRolePolicy`). Trust changes go through this
    bootstrap stack, so CI cannot make a project role trust an outside account.

Remaining risk: inside `region`, CI can still create EC2 resources and launch
instances with `qwen-spot-*` roles, and it can create a new `qwen-spot-*` role with
any trust policy (IAM has no condition key on trust content). Both are capped by
the boundary to qwen-spot resources, so a bad change can reach this project's data
but nothing else in the account. The controls for that are who can push to and
dispatch from `main`, and, optionally, a required reviewer on the `aws` environment.
