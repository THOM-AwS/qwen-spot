#!/usr/bin/env bash
# Fail fast on a bad boot. If vLLM is not healthy within QWEN_BOOT_TIMEOUT_MINUTES
# (crash loop, hang, missing dependency), give up on this instance: publish
# QwenSpot/BootFailed and set the worker group to 0 so the instance terminates,
# instead of systemd restarting a broken vLLM on a GPU billed by the second.
set -euo pipefail

# shellcheck source=common.sh
. /opt/qwen-spot/bin/common.sh

require_env QWEN_REGION QWEN_ASG_NAME

timeout_s=$(( ${QWEN_BOOT_TIMEOUT_MINUTES:-20} * 60 ))
start=$(date +%s)

while true; do
  if curl -fsS --max-time 5 http://127.0.0.1:8000/health >/dev/null 2>&1; then
    log info boot-watchdog "vLLM healthy after $(( $(date +%s) - start ))s"
    exit 0
  fi
  if [ $(( $(date +%s) - start )) -ge "$timeout_s" ]; then
    break
  fi
  sleep 15
done

log error boot-watchdog "vLLM not healthy after ${QWEN_BOOT_TIMEOUT_MINUTES:-20} min; failing this boot and setting $QWEN_ASG_NAME to 0"
/opt/qwen-spot/worker-venv/bin/python - <<'PY' || log error boot-watchdog "could not report the failed boot or scale in"
import os
import boto3

region = os.environ["QWEN_REGION"]
group = os.environ["QWEN_ASG_NAME"]
boto3.client("cloudwatch", region_name=region).put_metric_data(
    Namespace="QwenSpot",
    MetricData=[{
        "MetricName": "BootFailed",
        "Dimensions": [{"Name": "AutoScalingGroupName", "Value": group}],
        "Value": 1,
        "Unit": "Count",
    }],
)
boto3.client("autoscaling", region_name=region).set_desired_capacity(
    AutoScalingGroupName=group, DesiredCapacity=0, HonorCooldown=False
)
PY
exit 1
