#!/usr/bin/env bash
# Render the CloudWatch agent config for this boot's log group and start it.
set -euo pipefail

# shellcheck source=common.sh
. /opt/qwen-spot/bin/common.sh

require_env QWEN_LOG_GROUP

conf=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

collect() {
  local name=$1
  jq -n --arg group "$QWEN_LOG_GROUP" --arg name "$name" '{
    file_path: ("/var/log/qwen-spot/" + $name + ".log"),
    log_group_name: $group,
    log_stream_name: ("{instance_id}-" + $name),
    retention_in_days: -1
  }'
}

jq -n \
  --argjson vllm "$(collect vllm)" \
  --argjson worker "$(collect worker)" \
  --argjson cache "$(collect cache-sync)" \
  '{
    agent: {run_as_user: "root"},
    logs: {logs_collected: {files: {collect_list: [$vllm, $worker, $cache]}}}
  }' >"$conf"

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c "file:$conf"
log info cwagent "shipping /var/log/qwen-spot to $QWEN_LOG_GROUP"
