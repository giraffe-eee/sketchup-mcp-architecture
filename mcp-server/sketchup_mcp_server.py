"""MCP server for the local Codex SketchUp architecture bridge.

The SketchUp Ruby extension exposes a deliberately small HTTP API on the
loopback interface. This process translates MCP tool calls into those API
commands; it never evaluates arbitrary Ruby.
"""

from __future__ import annotations

import errno
import json
import math
import os
import re
import socket
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from mcp.server.fastmcp import FastMCP


SERVER_NAME: Final = "SketchUp Architecture"
DEFAULT_HOST: Final = "127.0.0.1"
DEFAULT_PORT: Final = 17654
DEFAULT_TIMEOUT_SECONDS: Final = 35.0
FILE_QUEUE_RETRY_DELAY_SECONDS: Final = 0.05
MAX_BATCH_COMMANDS: Final = 100
MAX_STREAM_STAGES: Final = 64
MAX_STREAM_STAGE_COMMANDS: Final = 8
DEFAULT_MIN_STAGE_DURATION_MS: Final = 120
MAX_MIN_STAGE_DURATION_MS: Final = 2_000
REQUEST_ID_PATTERN: Final = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
PROJECT_ROOT: Final = Path(__file__).resolve().parents[1]
DEFAULT_FILE_BRIDGE_DIR: Final = PROJECT_ROOT / ".runtime" / "file-queue"
ACTION_CATALOG_PATH: Final = (
    PROJECT_ROOT / "sketchup-plugin-source" / "codex_sketchup_mcp" / "action_catalog.json"
)

def load_action_catalog(path: Path = ACTION_CATALOG_PATH) -> tuple[str, dict[str, dict[str, Any]]]:
    """Load the Ruby bridge's allowlist without duplicating its protocol contract."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise RuntimeError(f"SketchUp action catalog is unavailable: {path}") from error
    except json.JSONDecodeError as error:
        raise RuntimeError(f"SketchUp action catalog is invalid JSON: {path}") from error

    if not isinstance(document, dict):
        raise RuntimeError("SketchUp action catalog must be a JSON object")
    protocol_version = document.get("protocol_version")
    actions = document.get("actions")
    if not isinstance(protocol_version, str) or not protocol_version:
        raise RuntimeError("SketchUp action catalog is missing protocol_version")
    if not isinstance(actions, dict) or not actions:
        raise RuntimeError("SketchUp action catalog is missing actions")
    if any(not isinstance(name, str) or not isinstance(spec, dict) for name, spec in actions.items()):
        raise RuntimeError("SketchUp action catalog has an invalid action definition")
    return protocol_version, actions


ACTION_CATALOG_PROTOCOL_VERSION, ACTION_CATALOG = load_action_catalog()
SUPPORTED_ACTIONS: Final = frozenset(ACTION_CATALOG)
MUTATING_ACTIONS: Final = frozenset(
    action for action, spec in ACTION_CATALOG.items() if spec.get("mutating") is True
)

SERVER_INSTRUCTIONS: Final = (
    "Call bridge_status before editing a model. All geometric values are in "
    "millimetres. Use list_entities before changing or deleting an existing "
    "entity, inspect_model after a modelling batch, and sketchup_action_catalog "
    "when an action's parameter shape is unclear. For a new architectural model, "
    "create a large green site-ground slab first. Do not inset an upper storey "
    "unless the user explicitly requests a setback: derive its slab and walls from "
    "the ground-storey footprint. Every upper wall base must meet the slab top below "
    "it. External stairs must start at or above the site-ground top and their final "
    "tread must meet the entrance landing. For new model creation, prefer "
    "sketchup_stream with small semantic stages: it commits each stage atomically "
    "and runs a quality gate before continuing. sketchup_batch is atomic by default "
    "and is appropriate when the entire change must be one operation. The server "
    "only contacts the local SketchUp bridge on 127.0.0.1 and never runs arbitrary Ruby."
)

mcp = FastMCP(SERVER_NAME, instructions=SERVER_INSTRUCTIONS)


class BridgeError(RuntimeError):
    """Base error returned by the local SketchUp bridge."""


class BridgeUnavailable(BridgeError):
    """The local bridge could not be reached."""


class BridgeCommandError(BridgeError):
    """SketchUp received a command but rejected it."""


@dataclass(frozen=True)
class BridgeSettings:
    host: str
    port: int
    timeout_seconds: float
    file_queue_enabled: bool
    file_bridge_dir: Path

    @classmethod
    def from_environment(cls) -> "BridgeSettings":
        enabled = os.environ.get("SKETCHUP_MCP_ENABLE_FILE_QUEUE", "true").lower()
        bridge_dir = os.environ.get("SKETCHUP_MCP_FILE_BRIDGE_DIR")
        host = os.environ.get("SKETCHUP_MCP_HOST", DEFAULT_HOST).strip()
        if host != DEFAULT_HOST:
            raise ValueError(f"SKETCHUP_MCP_HOST must be {DEFAULT_HOST}")
        try:
            port = int(os.environ.get("SKETCHUP_MCP_PORT", str(DEFAULT_PORT)))
        except ValueError as error:
            raise ValueError("SKETCHUP_MCP_PORT must be an integer") from error
        if not 1 <= port <= 65_535:
            raise ValueError("SKETCHUP_MCP_PORT must be between 1 and 65535")
        try:
            timeout_seconds = float(
                os.environ.get("SKETCHUP_MCP_TIMEOUT_SEC", str(DEFAULT_TIMEOUT_SECONDS))
            )
        except ValueError as error:
            raise ValueError("SKETCHUP_MCP_TIMEOUT_SEC must be a positive number") from error
        if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
            raise ValueError("SKETCHUP_MCP_TIMEOUT_SEC must be a positive number")
        return cls(
            host=host,
            port=port,
            timeout_seconds=timeout_seconds,
            file_queue_enabled=enabled in {"1", "true", "yes", "on"},
            file_bridge_dir=Path(bridge_dir) if bridge_dir else DEFAULT_FILE_BRIDGE_DIR,
        )


class BridgeClient:
    """Small, dependency-free client for the Ruby HTTP and file-queue bridge."""

    def __init__(self, settings: BridgeSettings | None = None) -> None:
        self.settings = settings or BridgeSettings.from_environment()

    @property
    def base_url(self) -> str:
        return f"http://{self.settings.host}:{self.settings.port}"

    def health(self) -> dict[str, Any]:
        if self.settings.file_queue_enabled:
            return {
                "ok": True,
                "service": "codex-sketchup-mcp-file-queue",
                "transport": "file-queue",
            }
        return self._request_json("GET", "/health")

    def command(
        self,
        action: str,
        params: dict[str, Any],
        request_id: str | None = None,
    ) -> dict[str, Any]:
        validate_action(action)
        normalized_params = normalize_params(params)
        normalized_request_id = normalize_request_id(request_id)
        if self.settings.file_queue_enabled:
            response = self._queue_command(action, normalized_params, normalized_request_id)
            try:
                return unwrap_command_response(response)
            except BridgeCommandError as error:
                raise BridgeCommandError(f"{error} (request_id={normalized_request_id})") from error

        try:
            response = self._request_json(
                "POST",
                "/command",
                {
                    "action": action,
                    "params": normalized_params,
                    "request_id": normalized_request_id,
                },
            )
        except BridgeUnavailable as error:
            if not self.settings.file_queue_enabled:
                raise BridgeUnavailable(f"{error} (request_id={normalized_request_id})") from error
            response = self._queue_command(action, normalized_params, normalized_request_id)
        except BridgeCommandError as error:
            raise BridgeCommandError(f"{error} (request_id={normalized_request_id})") from error
        try:
            return unwrap_command_response(response)
        except BridgeCommandError as error:
            raise BridgeCommandError(f"{error} (request_id={normalized_request_id})") from error

    def _request_json(
        self, method: str, path: str, payload: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        body = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"

        request = Request(f"{self.base_url}{path}", data=body, headers=headers, method=method)
        try:
            with urlopen(request, timeout=self.settings.timeout_seconds) as response:
                raw = response.read().decode("utf-8")
        except HTTPError as error:
            raw = error.read().decode("utf-8", errors="replace")
            raise BridgeCommandError(format_http_error(error.code, raw)) from error
        except (URLError, OSError, socket.timeout) as error:
            raise BridgeUnavailable(
                f"SketchUp bridge is unavailable at {self.base_url}: {error}"
            ) from error

        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError as error:
            raise BridgeError("SketchUp bridge returned invalid JSON") from error
        if not isinstance(decoded, dict):
            raise BridgeError("SketchUp bridge returned a non-object JSON payload")
        return decoded

    def _queue_command(
        self, action: str, params: dict[str, Any], request_id: str
    ) -> dict[str, Any]:
        """Use the Ruby extension's optional JSONL fallback when explicitly enabled."""
        bridge_dir = self.settings.file_bridge_dir
        command_file = bridge_dir / "commands.jsonl"
        response_file = bridge_dir / "responses.jsonl"
        bridge_dir.mkdir(parents=True, exist_ok=True)
        deadline = time.monotonic() + self.settings.timeout_seconds
        command_line = (
            json.dumps(
                {"id": request_id, "action": action, "params": params},
                ensure_ascii=True,
            )
            + "\n"
        )
        while True:
            try:
                with command_file.open("a", encoding="utf-8") as file:
                    file.write(command_line)
                break
            except OSError as error:
                if not is_transient_file_queue_error(error) or time.monotonic() >= deadline:
                    raise BridgeUnavailable(
                        "Could not write to the SketchUp file command queue"
                    ) from error
                time.sleep(FILE_QUEUE_RETRY_DELAY_SECONDS)

        while time.monotonic() < deadline:
            try:
                if response_file.exists():
                    with response_file.open("r", encoding="utf-8") as file:
                        for line in file:
                            try:
                                response = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            if response.get("id") == request_id:
                                return response
            except OSError as error:
                if not is_transient_file_queue_error(error):
                    raise BridgeUnavailable(
                        "Could not read from the SketchUp file response queue"
                    ) from error
            time.sleep(0.1)
        raise BridgeUnavailable(
            "SketchUp did not process the queued command before the configured timeout"
        )


def is_transient_file_queue_error(error: OSError) -> bool:
    """Return whether Windows can reasonably release a file-queue lock shortly."""
    return isinstance(error, PermissionError) or error.errno in {
        errno.EACCES,
        errno.EAGAIN,
        errno.EBUSY,
        errno.EPERM,
    }


def format_http_error(status_code: int, raw_body: str) -> str:
    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError:
        return f"SketchUp bridge returned HTTP {status_code}: {raw_body}"
    if isinstance(payload, dict):
        return str(payload.get("error") or payload.get("message") or payload)
    return f"SketchUp bridge returned HTTP {status_code}: {payload}"


def normalize_params(params: dict[str, Any] | None) -> dict[str, Any]:
    if params is None:
        return {}
    if not isinstance(params, dict):
        raise ValueError("params must be a JSON object")
    try:
        json.dumps(params, ensure_ascii=True, allow_nan=False)
    except (TypeError, ValueError) as error:
        raise ValueError("params must contain JSON-compatible values") from error
    return params


def normalize_request_id(request_id: str | None) -> str:
    value = request_id or uuid.uuid4().hex
    if not isinstance(value, str) or not REQUEST_ID_PATTERN.fullmatch(value):
        raise ValueError(
            "request_id must contain 1-128 letters, digits, dots, underscores, colons, or hyphens"
        )
    return value


def validate_action(action: str) -> None:
    if action not in SUPPORTED_ACTIONS:
        supported = ", ".join(sorted(SUPPORTED_ACTIONS))
        raise ValueError(f"Unsupported SketchUp action: {action}. Supported actions: {supported}")


def normalize_mutating_batch_commands(
    commands: list[dict[str, Any]], *, context: str, maximum_commands: int = MAX_BATCH_COMMANDS
) -> list[dict[str, Any]]:
    """Validate commands that will run together in one atomic SketchUp operation."""
    if not isinstance(commands, list) or not commands:
        raise ValueError(f"{context} must be a non-empty list")
    if len(commands) > maximum_commands:
        raise ValueError(f"{context} must contain at most {maximum_commands} items")

    normalized_commands: list[dict[str, Any]] = []
    for index, command in enumerate(commands):
        if not isinstance(command, dict):
            raise ValueError(f"{context}[{index}] must be an object")
        action = command.get("action")
        if not isinstance(action, str):
            raise ValueError(f"{context}[{index}].action must be a string")
        validate_action(action)
        if action == "apply_batch" or action not in MUTATING_ACTIONS:
            raise ValueError(
                f"{context}[{index}] must be a mutating action other than apply_batch"
            )
        normalized_commands.append(
            {"action": action, "params": normalize_params(command.get("params"))}
        )
    return normalized_commands


def normalize_stream_stages(stages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Validate small, named atomic batches suitable for visible model streaming."""
    if not isinstance(stages, list) or not stages:
        raise ValueError("stages must be a non-empty list")
    if len(stages) > MAX_STREAM_STAGES:
        raise ValueError(f"stages must contain at most {MAX_STREAM_STAGES} items")

    normalized_stages: list[dict[str, Any]] = []
    for index, stage in enumerate(stages):
        if not isinstance(stage, dict):
            raise ValueError(f"stages[{index}] must be an object")
        unexpected_fields = set(stage) - {"name", "commands"}
        if unexpected_fields:
            raise ValueError(
                f"stages[{index}] has unsupported fields: {', '.join(sorted(unexpected_fields))}"
            )
        name = stage.get("name")
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"stages[{index}].name must be a non-empty string")
        if len(name.strip()) > 96:
            raise ValueError(f"stages[{index}].name must be at most 96 characters")
        normalized_stages.append(
            {
                "name": name.strip(),
                "commands": normalize_mutating_batch_commands(
                    stage.get("commands"),
                    context=f"stages[{index}].commands",
                    maximum_commands=MAX_STREAM_STAGE_COMMANDS,
                ),
            }
        )
    return normalized_stages


def split_stream_phases(
    phases: list[tuple[str, list[dict[str, Any]]]], *, maximum_stage_commands: int = 4
) -> list[dict[str, Any]]:
    """Split ordered semantic phases into small visible atomic stages."""
    if isinstance(maximum_stage_commands, bool) or not isinstance(maximum_stage_commands, int):
        raise ValueError("maximum_stage_commands must be an integer")
    if not 1 <= maximum_stage_commands <= MAX_STREAM_STAGE_COMMANDS:
        raise ValueError(
            f"maximum_stage_commands must be between 1 and {MAX_STREAM_STAGE_COMMANDS}"
        )

    stages: list[dict[str, Any]] = []
    for phase_index, phase in enumerate(phases):
        if not isinstance(phase, tuple) or len(phase) != 2:
            raise ValueError(f"phases[{phase_index}] must contain a name and commands")
        phase_name, commands = phase
        if not isinstance(phase_name, str) or not phase_name.strip():
            raise ValueError(f"phases[{phase_index}] name must be a non-empty string")
        if not isinstance(commands, list) or not commands:
            raise ValueError(f"phases[{phase_index}] commands must be a non-empty list")

        stage_count = math.ceil(len(commands) / maximum_stage_commands)
        for stage_index in range(stage_count):
            start = stage_index * maximum_stage_commands
            end = start + maximum_stage_commands
            suffix = f" {stage_index + 1}/{stage_count}" if stage_count > 1 else ""
            stages.append({"name": f"{phase_name}{suffix}", "commands": commands[start:end]})

    return normalize_stream_stages(stages)


def child_request_id(batch_request_id: str, index: int) -> str:
    """Create a stable per-command ID for a retryable non-atomic batch."""
    direct_id = f"{batch_request_id}:{index}"
    if len(direct_id) <= 128:
        return direct_id
    return f"batch-{uuid.uuid5(uuid.NAMESPACE_URL, direct_id).hex}"


def normalize_min_stage_duration_ms(value: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("minimum_stage_duration_ms must be an integer")
    if not 0 <= value <= MAX_MIN_STAGE_DURATION_MS:
        raise ValueError(
            f"minimum_stage_duration_ms must be between 0 and {MAX_MIN_STAGE_DURATION_MS}"
        )
    return value


def execute_staged_build(
    client: BridgeClient,
    stages: list[dict[str, Any]],
    *,
    request_id: str | None = None,
    verify_each_stage: bool = True,
    minimum_stage_duration_ms: int = DEFAULT_MIN_STAGE_DURATION_MS,
) -> dict[str, Any]:
    """Run a visible build as independently atomic, quality-gated stages."""
    if not isinstance(verify_each_stage, bool):
        raise ValueError("verify_each_stage must be a boolean")

    normalized_stages = normalize_stream_stages(stages)
    minimum_duration_ms = normalize_min_stage_duration_ms(minimum_stage_duration_ms)
    stream_request_id = normalize_request_id(request_id)
    completed_stages: list[dict[str, Any]] = []
    total_command_count = sum(len(stage["commands"]) for stage in normalized_stages)

    def failure(
        index: int, stage: dict[str, Any], error: str, *, committed: bool
    ) -> dict[str, Any]:
        return {
            "ok": False,
            "atomic_per_stage": True,
            "request_id": stream_request_id,
            "command_count": total_command_count,
            "completed_stage_count": len(completed_stages),
            "completed_stages": completed_stages,
            "failed_stage": {
                "index": index,
                "name": stage["name"],
                "command_count": len(stage["commands"]),
                "committed": committed,
            },
            "error": error,
        }

    for index, stage in enumerate(normalized_stages):
        started_at = time.monotonic()
        stage_request_id = child_request_id(stream_request_id, index * 2)
        try:
            batch = client.command(
                "apply_batch",
                {"name": stage["name"], "commands": stage["commands"]},
                request_id=stage_request_id,
            )
        except (BridgeError, ValueError) as error:
            return failure(index, stage, str(error), committed=False)

        if batch.get("atomic") is not True:
            return failure(index, stage, "SketchUp did not confirm an atomic stage", committed=True)
        if batch.get("command_count") != len(stage["commands"]):
            return failure(
                index,
                stage,
                "SketchUp reported an unexpected stage command count",
                committed=True,
            )

        stage_result: dict[str, Any] = {
            "index": index,
            "name": stage["name"],
            "command_count": len(stage["commands"]),
            "request_id": stage_request_id,
        }
        if verify_each_stage:
            quality_request_id = child_request_id(stream_request_id, index * 2 + 1)
            try:
                quality = client.command("quality_check", {}, request_id=quality_request_id)
            except (BridgeError, ValueError) as error:
                completed_stages.append(stage_result)
                return failure(index, stage, str(error), committed=True)
            stage_result["quality"] = quality
            completed_stages.append(stage_result)
            if quality.get("status") != "ok":
                return failure(
                    index,
                    stage,
                    f"Quality gate returned {quality.get('status', 'no status')}",
                    committed=True,
                )
        else:
            completed_stages.append(stage_result)

        if index + 1 < len(normalized_stages):
            remaining_seconds = minimum_duration_ms / 1000 - (time.monotonic() - started_at)
            if remaining_seconds > 0:
                time.sleep(remaining_seconds)

    return {
        "ok": True,
        "atomic_per_stage": True,
        "request_id": stream_request_id,
        "command_count": total_command_count,
        "stage_count": len(completed_stages),
        "stages": completed_stages,
    }


def unwrap_command_response(response: dict[str, Any]) -> dict[str, Any]:
    if response.get("ok") is not True:
        error = response.get("error")
        if not error and isinstance(response.get("payload"), dict):
            error = response["payload"].get("error")
        raise BridgeCommandError(str(error or "SketchUp rejected the command"))
    payload = response.get("payload", {})
    if isinstance(payload, dict):
        return payload
    return {"result": payload}


def execute_action(
    action: str, params: dict[str, Any] | None = None, request_id: str | None = None
) -> dict[str, Any]:
    """Validate and forward one allowlisted command to the local Ruby bridge."""
    validate_action(action)
    return BridgeClient().command(action, normalize_params(params), request_id=request_id)


@mcp.tool()
def bridge_status() -> dict[str, Any]:
    """Check that SketchUp's localhost bridge is reachable and describe its capabilities."""
    client = BridgeClient()
    bridge = client.command("bridge_info", {})
    advertised_actions = bridge.get("actions", [])
    advertised_action_set = set(advertised_actions) if isinstance(advertised_actions, list) else set()
    required_actions = {"apply_batch", "bridge_info"}
    missing_actions = sorted(required_actions - advertised_action_set)
    compatible = (
        bridge.get("protocol_version") == ACTION_CATALOG_PROTOCOL_VERSION
        and not missing_actions
    )
    return {
        "health": client.health(),
        "bridge": bridge,
        "compatible": compatible,
        "required_protocol_version": ACTION_CATALOG_PROTOCOL_VERSION,
        "missing_required_actions": missing_actions,
    }


@mcp.tool()
def sketchup_action_catalog() -> dict[str, Any]:
    """Return the allowed SketchUp actions and common parameter names."""
    return {
        "protocol_version": ACTION_CATALOG_PROTOCOL_VERSION,
        "actions": ACTION_CATALOG,
    }


@mcp.tool()
def inspect_model() -> dict[str, Any]:
    """List current entities and run the Ruby bridge's quality checks without editing the model."""
    return {
        "entities": execute_action("list_entities"),
        "quality": execute_action("quality_check"),
    }


@mcp.tool()
def sketchup_action(
    action: str,
    params: dict[str, Any] | None = None,
    request_id: str | None = None,
) -> dict[str, Any]:
    """Execute one named, allowlisted SketchUp modeling action using millimetres."""
    return execute_action(action, params, request_id=request_id)


@mcp.tool()
def sketchup_stream(
    stages: list[dict[str, Any]],
    verify_each_stage: bool = True,
    minimum_stage_duration_ms: int = DEFAULT_MIN_STAGE_DURATION_MS,
    request_id: str | None = None,
) -> dict[str, Any]:
    """Build visibly in small atomic stages and stop at the first failed quality gate."""
    return execute_staged_build(
        BridgeClient(),
        stages,
        request_id=request_id,
        verify_each_stage=verify_each_stage,
        minimum_stage_duration_ms=minimum_stage_duration_ms,
    )


@mcp.tool()
def sketchup_batch(
    commands: list[dict[str, Any]],
    atomic: bool = True,
    stop_on_error: bool = True,
    request_id: str | None = None,
) -> dict[str, Any]:
    """Execute up to 100 actions; atomic batches roll back completely when one fails."""
    if not isinstance(commands, list) or not commands:
        raise ValueError("commands must be a non-empty list")
    if len(commands) > MAX_BATCH_COMMANDS:
        raise ValueError(f"commands must contain at most {MAX_BATCH_COMMANDS} items")

    normalized_commands: list[dict[str, Any]] = []
    for index, command in enumerate(commands):
        if not isinstance(command, dict):
            raise ValueError(f"commands[{index}] must be an object")
        action = command.get("action")
        if not isinstance(action, str):
            raise ValueError(f"commands[{index}].action must be a string")
        validate_action(action)
        normalized_commands.append(
            {"action": action, "params": normalize_params(command.get("params"))}
        )

    if atomic:
        if not stop_on_error:
            raise ValueError("stop_on_error=false is only available when atomic=false")
        invalid_actions = [
            command["action"]
            for command in normalized_commands
            if command["action"] == "apply_batch"
            or command["action"] not in MUTATING_ACTIONS
        ]
        if invalid_actions:
            raise ValueError(
                "atomic batches accept only mutating actions other than apply_batch: "
                + ", ".join(sorted(set(invalid_actions)))
            )
        payload = execute_action(
            "apply_batch",
            {"commands": normalized_commands},
            request_id=request_id,
        )
        return {"ok": True, **payload}

    batch_request_id = normalize_request_id(request_id) if request_id is not None else None
    results: list[dict[str, Any]] = []
    for index, command in enumerate(normalized_commands):
        action = command["action"]
        params = command["params"]
        command_request_id = (
            child_request_id(batch_request_id, index) if batch_request_id is not None else None
        )
        try:
            payload = execute_action(action, params, request_id=command_request_id)
        except (BridgeError, ValueError) as error:
            results.append(
                {
                    "index": index,
                    "action": action,
                    "ok": False,
                    "error": str(error),
                    "request_id": command_request_id,
                }
            )
            if stop_on_error:
                break
        else:
            results.append(
                {
                    "index": index,
                    "action": action,
                    "ok": True,
                    "payload": payload,
                    "request_id": command_request_id,
                }
            )

    return {"ok": all(item["ok"] for item in results), "atomic": False, "results": results}


if __name__ == "__main__":
    mcp.run(transport="stdio")
