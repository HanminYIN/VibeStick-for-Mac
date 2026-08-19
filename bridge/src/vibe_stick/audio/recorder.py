from __future__ import annotations

import json
import math
import os
import signal
import struct
import subprocess
import tempfile
import time
import wave
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from vibe_stick.audio.transcriber import TranscriptionAdapter
from vibe_stick.audio.send_session import (
    PendingSendCoordinator,
    SendSessionPhase,
    SendSessionSnapshot,
    SendSessionTransition,
)
from vibe_stick.config.paths import RECORDINGS_DIR
from vibe_stick.desktop.hud import hide_hud, show_hud
from vibe_stick.paste.input_injector import MacPasteInjector

MIN_AUDIO_DURATION_SECONDS = 0.7
MIN_AUDIO_RMS = 120.0
MIN_SPEECH_SECONDS = 0.28
MIN_SPEECH_WINDOWS = 3
SPEECH_WINDOW_SECONDS = 0.10
SPEECH_RMS_THRESHOLD = 900.0
SPEECH_EDGE_IGNORE_SECONDS = 0.18
KNOWN_ASR_HALLUCINATIONS = (
    "\u8bf7\u4e0d\u541d\u70b9\u8d5e\u8ba2\u9605\u8f6c\u53d1\u6253\u8d4f\u652f\u6301\u660e\u955c\u4e0e\u70b9\u70b9\u680f\u76ee",
    "\u8bf7\u4f7f\u7528\u7b80\u4f53\u4e2d\u6587\u8f93\u51fa\u3002",
)
SUPPORTED_VOICE_INTERACTION_VERSION = 2
SEND_MODE_PASTE_ONLY = "paste_only"
SEND_MODE_CONFIRM = "confirm"
SEND_MODE_AUTO_SEND = "auto_send"
CONFIRM_TARGET_RETRY_DELAY_SECONDS = 0.12


@dataclass
class RecordingSession:
    session_id: str = ""
    active: bool = False
    started_at: str = ""
    stopped_at: str = ""
    status: str = "idle"
    message: str = ""
    transcript: str = ""
    transcript_source: str = "none"
    pasted: bool = False
    audio_file: str = ""
    audio_source: str = "none"
    interaction_version: int = 1
    send_mode: str = SEND_MODE_PASTE_ONLY

    def to_jsonable(self) -> dict[str, Any]:
        return asdict(self)

    def to_persisted_jsonable(self) -> dict[str, Any]:
        """Return restart metadata without transcript text or local file paths."""
        return {
            "schema_version": 2,
            "session_id": self.session_id,
            "active": self.active,
            "started_at": self.started_at,
            "stopped_at": self.stopped_at,
            "status": self.status,
            "transcript_source": self.transcript_source,
            "pasted": self.pasted,
            "audio_source": self.audio_source,
            "interaction_version": self.interaction_version,
            "send_mode": self.send_mode,
        }


@dataclass(frozen=True)
class AudioMetrics:
    duration_seconds: float
    audio_bytes: int
    rms: float
    ac_rms: float
    speech_seconds: float
    speech_windows: int


class RecordingController:
    """project-owned push-to-talk session boundary."""

    def __init__(
        self,
        path: Path,
        *,
        pending_send_path: Path | None = None,
        managed_asr: dict[str, Any] | None = None,
        managed_asr_api_key: str = "",
        managed_send_mode: str | None = None,
    ) -> None:
        self.path = path
        self.transcriber = TranscriptionAdapter(
            managed_asr=managed_asr,
            managed_asr_api_key=managed_asr_api_key,
        )
        self.paste_injector = MacPasteInjector()
        self.audio_recorder = MacMicRecorder()
        self.managed_send_mode = managed_send_mode
        self.pending_send = PendingSendCoordinator(
            pending_send_path or path.with_name("pending-send-v1.json")
        )
        self.session = self._load()

    def start(self, request: dict[str, Any] | None = None) -> RecordingSession:
        request = request or {}
        requested_source = str(request.get("audio_source") or request.get("source") or "")
        requested_session_id = _requested_session_id(request)
        session_id = requested_session_id or uuid.uuid4().hex
        interaction_version = _voice_interaction_version(request)
        send_mode = _configured_send_mode(
            interaction_version,
            managed_send_mode=self.managed_send_mode,
        )
        recording_transition = self.pending_send.begin_recording(session_id=session_id)
        self.session = RecordingSession(
            session_id=session_id,
            active=True,
            started_at=datetime.now().isoformat(timespec="seconds"),
            stopped_at="",
            status="recording",
            message="Recording session started",
            interaction_version=interaction_version,
            send_mode=send_mode,
        )
        if not recording_transition.accepted:
            self.session.active = False
            self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
            self.session.status = "start_failed"
            self.session.message = "A send confirmation is already in progress"
            self._save()
            return self.session
        use_mac_mic = "sticks3" not in requested_source.lower()
        if not use_mac_mic:
            self.session.audio_source = "sticks3_pcm"
            self.session.message = "Waiting for StickS3 audio upload"
            show_hud("listening")

        mic_result = self.audio_recorder.start(self.session.session_id) if use_mac_mic else None
        if mic_result is not None:
            ok, audio_file, message = mic_result
            self.session.audio_file = str(audio_file) if audio_file else ""
            self.session.audio_source = "mac_mic"
            self.session.message = message
            if not ok:
                self.session.active = False
                self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
                self.session.status = "start_failed"
                show_hud("failed", hold_seconds=1.8)
                self._save()
                return self.session
            show_hud("listening")

        hook = _run_command_hook("VIBE_STICK_RECORDING_START_CMD", self.session.to_jsonable(), timeout=15)
        if hook is not None and not hook[0]:
            self.audio_recorder.stop()
            self.session.active = False
            self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
            self.session.status = "start_failed"
            self.session.message = hook[2] or "Recording start command failed"
            show_hud("failed", hold_seconds=1.8)
        self._save()
        return self.session

    def attach_pcm(
        self,
        pcm: bytes,
        *,
        session_id: str = "",
        sample_rate: int = 16000,
        channels: int = 1,
        bits_per_sample: int = 16,
    ) -> RecordingSession:
        if not pcm:
            self.session.status = "audio_failed"
            self.session.message = "Uploaded audio was empty"
            show_hud("failed", hold_seconds=1.8)
            self._save()
            return self.session
        session_id = _clean_session_id(session_id)
        if session_id and self.session.session_id and session_id != self.session.session_id and self.session.active:
            self.session.status = "audio_failed"
            self.session.message = "Uploaded audio session did not match active recording"
            show_hud("failed", hold_seconds=1.8)
            self._save()
            return self.session
        if session_id and (not self.session.session_id or session_id != self.session.session_id):
            self.session = RecordingSession(
                session_id=session_id,
                active=True,
                started_at=datetime.now().isoformat(timespec="seconds"),
                status="recording",
                message="Recovered recording session from StickS3 audio upload",
                audio_source="sticks3_pcm",
            )
        if bits_per_sample != 16:
            self.session.status = "audio_failed"
            self.session.message = "Only 16-bit PCM audio is supported"
            show_hud("failed", hold_seconds=1.8)
            self._save()
            return self.session

        _ensure_private_directory(RECORDINGS_DIR)
        sid = self.session.session_id or session_id or uuid.uuid4().hex
        audio_file = RECORDINGS_DIR / f"{sid}.wav"
        with wave.open(str(audio_file), "wb") as wav:
            wav.setnchannels(max(1, channels))
            wav.setsampwidth(bits_per_sample // 8)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm)
        audio_file.chmod(0o600)

        self.session.audio_file = str(audio_file)
        self.session.audio_source = "sticks3_pcm"
        self.session.message = "StickS3 audio uploaded"
        show_hud("sending")
        self._save()
        return self.session

    def stop(self, request: dict[str, Any] | None = None) -> RecordingSession:
        request = request or {}
        self.session.active = False
        self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
        explicit_text = str(request.get("text") or request.get("transcript") or "")
        mic_stop = self.audio_recorder.stop()
        if mic_stop is not None:
            ok, audio_file, message = mic_stop
            self.session.audio_file = str(audio_file) if audio_file else self.session.audio_file
            self.session.audio_source = "mac_mic"
            if not ok:
                self.session.status = "stop_failed"
                self.session.message = message
                show_hud("failed", hold_seconds=1.8)
                self._save_stop_result()
                return self.session
        requested_session_id = _requested_session_id(request)
        if (
            self.session.interaction_version >= SUPPORTED_VOICE_INTERACTION_VERSION
            and requested_session_id != self.session.session_id
        ):
            self.session.pasted = False
            self.session.status = "stop_failed"
            self.session.message = "Recording stop session did not match the active M3-B session"
            show_hud("failed", hold_seconds=1.8)
            self._save_stop_result()
            return self.session
        stop_hook_source = False
        stop_hook = _run_command_hook("VIBE_STICK_RECORDING_STOP_CMD", self.session.to_jsonable(), timeout=120)
        if stop_hook is not None:
            hook_ok, hook_stdout, hook_stderr = stop_hook
            if hook_ok and hook_stdout.strip():
                explicit_text = hook_stdout.strip()
                stop_hook_source = True
            elif not hook_ok:
                self.session.status = "stop_failed"
                self.session.message = hook_stderr or "Recording stop command failed"
                show_hud("failed", hold_seconds=1.8)
                self._save_stop_result()
                return self.session
        should_paste = bool(request.get("paste", True))
        press_enter = self.session.send_mode == SEND_MODE_AUTO_SEND
        show_hud("transcribing")

        if not explicit_text:
            metrics = _wav_metrics(self.session.audio_file)
            if metrics is not None:
                print(
                    "recording audio metrics "
                    f"session={self.session.session_id} "
                    f"bytes={metrics.audio_bytes} "
                    f"duration={metrics.duration_seconds:.3f}s "
                    f"rms={metrics.rms:.1f} "
                    f"ac_rms={metrics.ac_rms:.1f} "
                    f"speech_seconds={metrics.speech_seconds:.2f} "
                    f"speech_windows={metrics.speech_windows}",
                    flush=True,
                )
                if metrics.duration_seconds < MIN_AUDIO_DURATION_SECONDS:
                    self.session.pasted = False
                    self.session.status = "audio_skipped"
                    self.session.message = (
                        f"Audio too short for transcription: {metrics.duration_seconds:.2f}s"
                    )
                    show_hud("unclear", hold_seconds=1.8)
                    self._save_stop_result()
                    return self.session
                if metrics.rms < MIN_AUDIO_RMS:
                    self.session.pasted = False
                    self.session.status = "audio_skipped"
                    self.session.message = f"Audio appears silent: rms={metrics.rms:.1f}"
                    show_hud("unclear", hold_seconds=1.8)
                    self._save_stop_result()
                    return self.session
                if (
                    metrics.speech_seconds < MIN_SPEECH_SECONDS
                    or metrics.speech_windows < MIN_SPEECH_WINDOWS
                ):
                    self.session.pasted = False
                    self.session.status = "audio_skipped"
                    self.session.message = (
                        "No clear speech detected before transcription: "
                        f"speech_seconds={metrics.speech_seconds:.2f}"
                    )
                    show_hud("unclear", hold_seconds=1.8)
                    self._save_stop_result()
                    return self.session

        transcript = self.transcriber.transcribe(
            self.session.to_jsonable(),
            explicit_text=explicit_text,
        )
        self.session.transcript_source = "recording_stop_cmd" if stop_hook_source else transcript.source
        if transcript.success and transcript.text:
            self.session.transcript = transcript.text
            transcript_message = (
                "Transcript supplied by recording stop command"
                if stop_hook_source else transcript.message
            )
            rejection_reason = _transcript_rejection_reason(transcript.text)
            if rejection_reason:
                self.session.pasted = False
                self.session.status = "transcript_rejected"
                self.session.message = rejection_reason
                show_hud("unclear", hold_seconds=1.8)
                print(
                    "recording transcript rejected "
                    f"session={self.session.session_id} "
                    f"source={self.session.transcript_source} "
                    f"reason={rejection_reason}",
                    flush=True,
                )
                self._save_stop_result()
                return self.session
            if should_paste:
                paste = self.paste_injector.paste(transcript.text, press_enter=press_enter)
                clipboard_only = paste.success and paste.delivery == "clipboard"
                self.session.pasted = paste.success and not clipboard_only
                if (
                    clipboard_only
                    and self.session.interaction_version >= SUPPORTED_VOICE_INTERACTION_VERSION
                ):
                    self.session.status = "copied"
                    self.session.message = paste.message
                elif (
                    paste.success
                    and self.session.interaction_version >= SUPPORTED_VOICE_INTERACTION_VERSION
                    and self.session.send_mode == SEND_MODE_CONFIRM
                ):
                    if paste.target is None:
                        self.session.status = "confirmation_unavailable"
                        self.session.message = "Text was pasted, but the focused input could not be identified"
                    else:
                        armed = self.pending_send.arm(
                            session_id=self.session.session_id,
                            target=paste.target,
                        )
                        self.session.status = "pending_send" if armed.accepted else "confirmation_unavailable"
                        self.session.message = (
                            "Text pasted; waiting for blue-button confirmation"
                            if armed.accepted else "Text was pasted, but confirmation could not be armed"
                        )
                elif (
                    paste.success
                    and self.session.interaction_version >= SUPPORTED_VOICE_INTERACTION_VERSION
                    and self.session.send_mode == SEND_MODE_AUTO_SEND
                ):
                    self.session.status = "sent"
                    self.session.message = paste.message
                else:
                    self.session.status = "pasted" if paste.success else "paste_failed"
                    self.session.message = (
                        paste.message if paste.success else f"{transcript_message}; {paste.message}"
                    )
                if paste.success:
                    hide_hud(delay_seconds=0.5)
                else:
                    show_hud("failed", hold_seconds=1.8)
            else:
                self.session.pasted = False
                self.session.status = "transcribed"
                self.session.message = transcript_message
                hide_hud(delay_seconds=0.5)
        else:
            self.session.pasted = False
            self.session.status = "transcription_failed"
            self.session.message = transcript.message
            show_hud("failed", hold_seconds=1.8)
        self._save_stop_result()
        return self.session

    def send_session_snapshot(self) -> SendSessionSnapshot:
        return self.pending_send.snapshot()

    def confirm_send(self, session_id: str) -> SendSessionTransition:
        snapshot = self.pending_send.snapshot()
        if snapshot.target is None or snapshot.phase != SendSessionPhase.PENDING:
            current_target = snapshot.target
            if current_target is None:
                return SendSessionTransition(
                    accepted=False,
                    should_press_enter=False,
                    reason=f"pending_send_{snapshot.phase.value}",
                    snapshot=snapshot,
                )
            return self.pending_send.begin_confirmation(
                session_id=session_id,
                current_target=current_target,
            )

        inspection = self.paste_injector.inspect_target(snapshot.target)
        if not inspection.success or inspection.target is None:
            time.sleep(CONFIRM_TARGET_RETRY_DELAY_SECONDS)
            inspection = self.paste_injector.inspect_target(snapshot.target)
        if not inspection.success or inspection.target is None:
            transition = self.pending_send.invalidate(
                session_id=session_id,
                reason="target_inspection_failed",
            )
            self._record_confirmation_result(transition, "Focused input could not be verified")
            return transition

        transition = self.pending_send.begin_confirmation(
            session_id=session_id,
            current_target=inspection.target,
        )
        if not transition.should_press_enter or transition.snapshot.target is None:
            self._record_confirmation_result(transition, "Focused input changed; Return was not sent")
            return transition

        action = self.paste_injector.confirm_return(transition.snapshot.target)
        finished = self.pending_send.finish_confirmation(
            session_id=session_id,
            success=action.success,
        )
        self._record_confirmation_result(finished, action.message)
        return finished

    def _record_confirmation_result(
        self,
        transition: SendSessionTransition,
        message: str,
    ) -> None:
        if transition.snapshot.session_id != self.session.session_id:
            return
        if transition.snapshot.phase == SendSessionPhase.SENT:
            self.session.status = "sent"
            self.session.message = message
            hide_hud()
        elif transition.snapshot.phase in {
            SendSessionPhase.FAILED,
            SendSessionPhase.INVALIDATED,
            SendSessionPhase.EXPIRED,
        }:
            self.session.status = "send_failed"
            self.session.message = message
            show_hud("send_failed", hold_seconds=1.8)
        self._save_stop_result()

    def _load(self) -> RecordingSession:
        try:
            data = json.loads(self.path.read_text())
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return RecordingSession()
        return RecordingSession(
            session_id=str(data.get("session_id") or ""),
            active=bool(data.get("active", False)),
            started_at=str(data.get("started_at") or ""),
            stopped_at=str(data.get("stopped_at") or ""),
            status=str(data.get("status") or "idle"),
            transcript_source=str(data.get("transcript_source") or "none"),
            pasted=bool(data.get("pasted", False)),
            audio_source=str(data.get("audio_source") or "none"),
            interaction_version=_bounded_interaction_version(data.get("interaction_version")),
            send_mode=_clean_send_mode(data.get("send_mode")),
        )

    def _save(self) -> None:
        _write_private_json(self.path, self.session.to_persisted_jsonable())

    def _save_stop_result(self) -> None:
        self._save()
        print(
            "recording stop result "
            f"session={self.session.session_id} "
            f"status={self.session.status} "
            f"source={self.session.transcript_source} "
            f"audio_source={self.session.audio_source} "
            f"transcript_chars={len(self.session.transcript)} "
            f"pasted={self.session.pasted}",
            flush=True,
        )


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _ensure_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)


def _write_private_json(path: Path, payload: dict[str, Any]) -> None:
    _ensure_private_directory(path.parent)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        path.chmod(0o600)
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def _voice_interaction_version(request: dict[str, Any]) -> int:
    return _bounded_interaction_version(request.get("interaction_version"))


def _bounded_interaction_version(raw: object) -> int:
    if isinstance(raw, bool) or not isinstance(raw, int):
        return 1
    return max(1, min(SUPPORTED_VOICE_INTERACTION_VERSION, raw))


def _configured_send_mode(
    interaction_version: int,
    *,
    managed_send_mode: str | None = None,
) -> str:
    if managed_send_mode is not None:
        return _clean_send_mode(managed_send_mode)
    if interaction_version < SUPPORTED_VOICE_INTERACTION_VERSION:
        return SEND_MODE_AUTO_SEND if _env_bool("VIBE_STICK_AUTO_ENTER", default=False) else SEND_MODE_PASTE_ONLY
    configured = os.environ.get("VIBE_STICK_SEND_MODE", "").strip().lower().replace("-", "_")
    aliases = {
        "paste": SEND_MODE_PASTE_ONLY,
        "paste_only": SEND_MODE_PASTE_ONLY,
        "confirm": SEND_MODE_CONFIRM,
        "blue_button": SEND_MODE_CONFIRM,
        "auto": SEND_MODE_AUTO_SEND,
        "auto_send": SEND_MODE_AUTO_SEND,
    }
    if configured in aliases:
        return aliases[configured]
    return SEND_MODE_AUTO_SEND if _env_bool("VIBE_STICK_AUTO_ENTER", default=False) else SEND_MODE_PASTE_ONLY


def _clean_send_mode(raw: object) -> str:
    value = str(raw or "").strip().lower()
    if value in {SEND_MODE_PASTE_ONLY, SEND_MODE_CONFIRM, SEND_MODE_AUTO_SEND}:
        return value
    return SEND_MODE_PASTE_ONLY


def _wav_metrics(audio_file: str) -> AudioMetrics | None:
    if not audio_file:
        return None
    path = Path(audio_file)
    if not path.is_file() or path.suffix.lower() != ".wav":
        return None
    try:
        with wave.open(str(path), "rb") as wav:
            frames = wav.getnframes()
            rate = wav.getframerate()
            sample_width = wav.getsampwidth()
            raw = wav.readframes(frames)
    except (OSError, wave.Error):
        return None

    duration_seconds = frames / rate if rate else 0.0
    if sample_width != 2 or not raw:
        return AudioMetrics(duration_seconds, len(raw), 0.0, 0.0, 0.0, 0)

    usable_len = len(raw) - (len(raw) % 2)
    samples = [sample for (sample,) in struct.iter_unpack("<h", raw[:usable_len])]
    count = len(samples)
    if count == 0:
        return AudioMetrics(duration_seconds, len(raw), 0.0, 0.0, 0.0, 0)
    total = sum(int(sample) * int(sample) for sample in samples)
    rms = math.sqrt(total / count) if count else 0.0
    mean = sum(samples) / count
    ac_rms = math.sqrt(sum((sample - mean) * (sample - mean) for sample in samples) / count)

    window_size = max(1, int(rate * SPEECH_WINDOW_SECONDS)) if rate else count
    edge_windows = int(math.ceil(SPEECH_EDGE_IGNORE_SECONDS / SPEECH_WINDOW_SECONDS))
    window_rms: list[float] = []
    for start in range(0, count, window_size):
        chunk = samples[start:start + window_size]
        if len(chunk) < max(1, window_size // 2):
            continue
        chunk_mean = sum(chunk) / len(chunk)
        chunk_rms = math.sqrt(
            sum((sample - chunk_mean) * (sample - chunk_mean) for sample in chunk) / len(chunk)
        )
        window_rms.append(chunk_rms)
    speech_windows = 0
    for index, value in enumerate(window_rms):
        if index < edge_windows or index >= len(window_rms) - edge_windows:
            continue
        if value >= SPEECH_RMS_THRESHOLD:
            speech_windows += 1
    speech_seconds = speech_windows * SPEECH_WINDOW_SECONDS
    return AudioMetrics(duration_seconds, len(raw), rms, ac_rms, speech_seconds, speech_windows)


def _transcript_rejection_reason(text: str) -> str:
    normalized = _normalized_transcript(text)
    for phrase in KNOWN_ASR_HALLUCINATIONS:
        if phrase in normalized:
            return "Rejected known ASR hallucination transcript"
    return ""


def _normalized_transcript(text: str) -> str:
    return "".join(str(text).split()).lower()


def _requested_session_id(request: dict[str, Any]) -> str:
    return _clean_session_id(str(request.get("session_id") or ""))


def _clean_session_id(raw: str) -> str:
    value = raw.strip()
    if not 8 <= len(value) <= 64:
        return ""
    if not all(ch.isalnum() or ch in {"-", "_"} for ch in value):
        return ""
    return value


def _run_command_hook(
    env_name: str,
    payload: dict[str, Any],
    timeout: int,
) -> tuple[bool, str, str] | None:
    command = os.environ.get(env_name, "").strip()
    if not command:
        return None
    try:
        result = subprocess.run(
            command,
            input=json.dumps(payload),
            shell=True,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return (False, "", str(exc))
    return (result.returncode == 0, result.stdout, result.stderr.strip())


class MacMicRecorder:
    """Small project-owned wrapper around a local AVFoundation recorder helper."""

    def __init__(self) -> None:
        self.process: subprocess.Popen[str] | None = None
        self.audio_file: Path | None = None

    def start(self, session_id: str) -> tuple[bool, Path | None, str] | None:
        if os.environ.get("VIBE_STICK_RECORDING_USE_MAC_MIC", "1").strip().lower() in {"0", "false", "no", "off"}:
            return None
        if self.process and self.process.poll() is None:
            return (False, self.audio_file, "A recording session is already active")

        _ensure_private_directory(RECORDINGS_DIR)
        self.audio_file = RECORDINGS_DIR / f"{session_id}.m4a"
        binary = self._ensure_helper_binary()
        if binary is None:
            return (False, self.audio_file, "Could not build VibeStick mic recorder helper")

        try:
            self.process = subprocess.Popen(
                [str(binary), str(self.audio_file)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError as exc:
            self.process = None
            return (False, self.audio_file, f"Could not start mic recorder: {exc}")

        time.sleep(1.0)
        if self.process.poll() is not None:
            _, stderr = self.process.communicate(timeout=1)
            message = stderr.strip() or "Mic recorder exited before recording started"
            self.process = None
            return (False, self.audio_file, message)
        return (True, self.audio_file, "Recording from Mac microphone")

    def stop(self) -> tuple[bool, Path | None, str] | None:
        if not self.process:
            return None
        process = self.process
        audio_file = self.audio_file
        self.process = None
        self.audio_file = None

        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)

        stdout, stderr = process.communicate(timeout=1)
        if process.returncode != 0:
            message = stderr.strip() or stdout.strip() or "Mic recorder stopped with an error"
            return (False, audio_file, message)
        if audio_file is None or not audio_file.exists() or audio_file.stat().st_size == 0:
            return (False, audio_file, "Mic recorder produced no audio")
        audio_file.chmod(0o600)
        return (True, audio_file, "Recording stopped")

    def _ensure_helper_binary(self) -> Path | None:
        source = Path(__file__).resolve().parents[3] / "tools" / "vibe_stick_mic_recorder.swift"
        binary = RECORDINGS_DIR.parent / "vibe_stick_mic_recorder"
        if not source.exists():
            return None
        if binary.exists() and binary.stat().st_mtime >= source.stat().st_mtime:
            return binary
        try:
            result = subprocess.run(
                ["swiftc", str(source), "-o", str(binary), "-framework", "AVFoundation"],
                check=False,
                capture_output=True,
                text=True,
                timeout=45,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        return binary
