"""qwenq command line."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from qwenq import api, session, settings

EXIT_OK = 0
EXIT_RESULT_ERROR = 1
EXIT_USAGE = 2
EXIT_TIMEOUT = 3


def _err(message: str) -> None:
    sys.stderr.write(f"qwenq: {message}\n")


def _queue(args: argparse.Namespace) -> api.QwenQueue:
    config = settings.load()
    session = boto3.session.Session(profile_name=args.profile)
    return api.QwenQueue.from_session(config, session)


def _params(args: argparse.Namespace) -> dict[str, Any]:
    params: dict[str, Any] = {"max_tokens": args.max_tokens, "temperature": args.temperature}
    if args.think is not None:
        params["chat_template_kwargs"] = {"enable_thinking": args.think}
    return params


def _print_result(result: dict[str, Any], args: argparse.Namespace) -> int:
    if args.json:
        sys.stdout.write(json.dumps(result, indent=2) + "\n")
    else:
        if args.show_reasoning and result.get("reasoning"):
            sys.stderr.write(result["reasoning"].strip() + "\n\n")
        if result.get("status") == "ok":
            sys.stdout.write((result.get("output") or "") + "\n")
        timings = result.get("timings", {})
        usage = result.get("usage", {})
        sys.stderr.write(
            f"[{result.get('status')}] queued {timings.get('queued_s', 0):.0f}s, "
            f"generated {timings.get('generation_s', 0):.1f}s, "
            f"{usage.get('prompt_tokens', 0)} in / {usage.get('completion_tokens', 0)} out\n"
        )
    if result.get("status") != "ok":
        _err(f"request failed: {result.get('error')}")
        return EXIT_RESULT_ERROR
    return EXIT_OK


def _wait_and_print(queue: api.QwenQueue, request_id: str, args: argparse.Namespace) -> int:
    try:
        result = queue.wait(request_id, timeout_s=args.timeout, on_progress=_err)
    except api.ResultTimeout as exc:
        _err(f"{exc}; it is still queued, check later with `qwenq wait {request_id}`")
        return EXIT_TIMEOUT
    return _print_result(result, args)


# ---- commands -----------------------------------------------------------


def cmd_configure(args: argparse.Namespace) -> int:
    config = settings.from_terraform(Path(args.terraform_dir))
    written = settings.save(config)
    _err(f"wrote {written}")
    return EXIT_OK


def cmd_ask(args: argparse.Namespace) -> int:
    prompt = sys.stdin.read() if args.prompt == "-" else args.prompt
    messages = []
    if args.system:
        messages.append({"role": "system", "content": args.system})
    messages.append({"role": "user", "content": prompt})
    queue = _queue(args)
    submitted = queue.submit(api.build_request(messages, _params(args)))
    waking = ", waking the GPU (cold start takes a few minutes)" if submitted.woke else ""
    _err(f"submitted {submitted.request_id}{waking}")
    return _wait_and_print(queue, submitted.request_id, args)


def cmd_submit(args: argparse.Namespace) -> int:
    raw = Path(args.file).read_text() if args.file != "-" else sys.stdin.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = None
    if isinstance(data, dict) and "messages" in data:
        try:
            request = api.build_request(
                data["messages"], data.get("params"), data.get("metadata"), data.get("request_id")
            )
        except ValueError as exc:
            _err(str(exc))
            return EXIT_USAGE
    else:
        request = api.build_request([{"role": "user", "content": raw}], _params(args))
    submitted = _queue(args).submit(request, wake=not args.no_wake)
    sys.stdout.write(submitted.request_id + "\n")
    return EXIT_OK


def cmd_wait(args: argparse.Namespace) -> int:
    return _wait_and_print(_queue(args), args.request_id, args)


def cmd_status(args: argparse.Namespace) -> int:
    queue = _queue(args)
    group = queue.group()
    status = {
        "asg": queue.settings.asg_name,
        "desired": group.desired,
        "instances": queue.instance_details([i["InstanceId"] for i in group.instances]),
        "asg_lifecycle": {i["InstanceId"]: i["LifecycleState"] for i in group.instances},
        "queue": queue.queue_depth(),
        "spot_prices_usd_hr": [{"type": t, "az": az, "price": p} for t, az, p in queue.spot_prices()],
    }
    sys.stdout.write(json.dumps(status, indent=2) + "\n")
    return EXIT_OK


def cmd_up(args: argparse.Namespace) -> int:
    _queue(args).set_capacity(1)
    _err("desired capacity set to 1")
    return EXIT_OK


def cmd_down(args: argparse.Namespace) -> int:
    _queue(args).set_capacity(0)
    _err("desired capacity set to 0; in-flight work returns to the queue")
    return EXIT_OK


def cmd_tunnel(args: argparse.Namespace) -> int:
    queue = _queue(args)
    instance_id = queue.worker_instance_id()
    if not instance_id:
        _err("no InService worker; run `qwenq up` and wait for it to boot")
        return EXIT_USAGE
    aws = os.environ.get("QWENQ_AWS_CLI") or shutil.which("aws")
    if not aws:
        _err("aws CLI not found (set QWENQ_AWS_CLI); the session-manager-plugin is also required")
        return EXIT_USAGE
    command = [
        aws,
        "ssm",
        "start-session",
        "--region",
        queue.settings.region,
        "--target",
        instance_id,
        "--document-name",
        "AWS-StartPortForwardingSession",
        "--parameters",
        json.dumps({"portNumber": ["8000"], "localPortNumber": [str(args.local_port)]}),
    ]
    if args.profile:
        command += ["--profile", args.profile]
    _err(f"forwarding localhost:{args.local_port} -> {instance_id}:8000 (vLLM). Ctrl-C to stop.")
    os.execv(aws, command)  # nosec B606 - argv built above, no shell
    return EXIT_OK  # not reached


def cmd_session(args: argparse.Namespace) -> int:
    """Wake the GPU, open a tunnel to vLLM and hold it until Ctrl-C or --max-hours."""
    queue = _queue(args)
    boto = boto3.session.Session(profile_name=args.profile)
    ssm = boto.client("ssm", region_name=queue.settings.region)
    try:
        aws = session.aws_cli()
        ready = session.wait_for_worker(queue, ssm, on_progress=_err)
        command = session.tunnel_command(aws, queue.settings.region, ready.instance_id, args.local_port, args.profile)
        tunnel = session.open_tunnel(command)
        _err(f"tunnel to {ready.instance_id} open; waiting for vLLM (the 27B model takes a few minutes to load)")
        waited = session.wait_for_vllm(args.local_port, tunnel)
    except session.SessionError as exc:
        _err(str(exc))
        return EXIT_USAGE

    base = f"http://127.0.0.1:{args.local_port}/v1"
    _err(f"ready after {ready.waited_s + waited:.0f}s. OpenAI-compatible API at {base}")
    sys.stdout.write(
        f"export OPENAI_BASE_URL={base}\nexport OPENAI_API_KEY=unused\n# model: {queue.settings.model_name}\n"
    )
    sys.stdout.flush()
    _err(f"holding the session for up to {args.max_hours:g} h; Ctrl-C to end. The GPU costs money while it is up.")

    deadline = time.monotonic() + args.max_hours * 3600
    restarts = 0
    try:
        while time.monotonic() < deadline:
            if tunnel.poll() is not None:
                if restarts >= 5:
                    _err("tunnel keeps dropping; ending the session")
                    break
                restarts += 1
                _err(f"tunnel dropped, reopening ({restarts}/5)")
                tunnel = session.open_tunnel(command)
            time.sleep(5)
        else:
            _err(f"--max-hours {args.max_hours:g} reached; ending the session")
    except KeyboardInterrupt:
        _err("ending the session")
    finally:
        tunnel.terminate()
    if args.down:
        queue.set_capacity(0)
        _err("desired capacity set to 0")
    else:
        _err("the worker scales in after its idle timeout (15 min by default); `qwenq down` stops it now")
    return EXIT_OK


# ---- parser -------------------------------------------------------------


def _request_id(value: str) -> str:
    if not api.is_request_id(value):
        raise argparse.ArgumentTypeError(f"{value!r} is not a request id (UUID)")
    return value


def _add_generation_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--temperature", type=float, default=0.7)
    think = parser.add_mutually_exclusive_group()
    think.add_argument("--think", dest="think", action="store_true", default=None, help="enable Qwen thinking mode")
    think.add_argument("--no-think", dest="think", action="store_false", help="disable Qwen thinking mode")


def _add_wait_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--timeout", type=float, default=3600.0, help="seconds to wait for the result")
    parser.add_argument("--json", action="store_true", help="print the whole result object")
    parser.add_argument("--show-reasoning", action="store_true", help="print the thinking block to stderr")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="qwenq", description=__doc__)
    parser.add_argument("--profile", default=os.environ.get("AWS_PROFILE"), help="AWS profile (default $AWS_PROFILE)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("configure", help="write client config from terraform outputs")
    p.add_argument("--terraform-dir", default="terraform")
    p.set_defaults(func=cmd_configure)

    p = sub.add_parser("ask", help="submit a prompt, wake the GPU, wait, print the answer")
    p.add_argument("prompt", help="prompt text, or - to read stdin")
    p.add_argument("--system", help="system prompt")
    _add_generation_args(p)
    _add_wait_args(p)
    p.set_defaults(func=cmd_ask)

    p = sub.add_parser("submit", help="submit a request file and print its id")
    p.add_argument("-f", "--file", required=True, help="request JSON (with messages) or plain text, - for stdin")
    p.add_argument("--no-wake", action="store_true", help="queue only; let the alarm wake the group")
    _add_generation_args(p)
    p.set_defaults(func=cmd_submit)

    p = sub.add_parser("wait", help="wait for a result")
    p.add_argument("request_id", type=_request_id)
    _add_wait_args(p)
    p.set_defaults(func=cmd_wait)

    for name, func, text in (
        ("status", cmd_status, "group, queue and spot price"),
        ("up", cmd_up, "set desired capacity to 1"),
        ("down", cmd_down, "set desired capacity to 0"),
    ):
        sub.add_parser(name, help=text).set_defaults(func=func)

    p = sub.add_parser("session", help="wake the GPU and hold an SSM tunnel to vLLM (OpenAI API on localhost)")
    p.add_argument("--local-port", type=int, default=session.DEFAULT_PORT)
    p.add_argument("--max-hours", type=float, default=2.0, help="end the session after this long (cost guard)")
    p.add_argument("--down", action="store_true", help="set capacity to 0 when the session ends")
    p.set_defaults(func=cmd_session)

    p = sub.add_parser("tunnel", help="SSM port-forward to vLLM for interactive use")
    p.add_argument("--local-port", type=int, default=8000)
    p.set_defaults(func=cmd_tunnel)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except settings.SettingsError as exc:
        _err(str(exc))
        return EXIT_USAGE
    except (ClientError, BotoCoreError) as exc:
        _err(f"AWS error: {exc}")
        return EXIT_USAGE
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
