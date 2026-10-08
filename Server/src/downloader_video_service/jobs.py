from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from typing import Callable
import uuid

from .config import Config
from .urls import canonical_post_url


class ServiceError(RuntimeError):
    pass


class QueueFull(ServiceError):
    pass


@dataclass
class Job:
    id: str
    post_url: str
    directory: Path
    created: float
    state: str = "queued"
    finished: float | None = None
    media: list[dict] = field(default_factory=list)
    error: str | None = None
    warning: str | None = None

    def snapshot(self) -> dict:
        result = {"id": self.id, "state": self.state, "media": [dict(item) for item in self.media]}
        if self.error:
            result["error"] = self.error
        if self.warning:
            result["warning"] = self.warning
        return result


def directory_bytes(directory: Path) -> int:
    total = 0
    for path in directory.rglob("*"):
        try:
            if path.is_file() and not path.is_symlink():
                total += path.stat().st_size
        except FileNotFoundError:
            continue
    return total


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        if hasattr(os, "killpg"):
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
        process.wait(timeout=2)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            if hasattr(os, "killpg"):
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except ProcessLookupError:
            pass
        process.wait()


class JobManager:
    def __init__(
        self,
        config: Config,
        runner: Callable[[str, Path, Config], dict] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.config = config
        self._clock = clock
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._jobs: dict[str, Job] = {}
        self._runner = runner or self._run_process
        config.cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._cache_lock = (config.cache_dir / ".service.lock").open("a+")
        try:
            fcntl.flock(self._cache_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            self._cache_lock.close()
            raise ServiceError("Another video service is already using this cache directory.") from error
        # Only this service's UUID folders are temporary. Do not delete unrelated files.
        try:
            for path in config.cache_dir.iterdir():
                if re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", path.name):
                    self._remove_directory(path)
        except Exception:
            self._cache_lock.close()
            raise
        self._pool = ThreadPoolExecutor(max_workers=config.workers, thread_name_prefix="video-job")
        self._janitor = threading.Thread(target=self._clean_loop, name="video-cache-cleaner", daemon=True)
        self._janitor.start()

    @staticmethod
    def _remove_directory(directory: Path) -> None:
        if directory.is_symlink():
            directory.unlink(missing_ok=True)
        elif directory.exists():
            shutil.rmtree(directory)

    def _clean_loop(self) -> None:
        while not self._stop.wait(min(30, self.config.ttl_seconds)):
            self.prune()

    def prune(self) -> None:
        with self._lock:
            expired = [
                job_id for job_id, job in self._jobs.items()
                if job.finished is not None and self._clock() - job.finished >= self.config.ttl_seconds
            ]
            for job_id in expired:
                self._remove_directory(self._jobs.pop(job_id).directory)

    def submit(self, post_url: str) -> dict:
        post_url = canonical_post_url(post_url)
        with self._lock:
            self.prune()
            pending = sum(job.state in {"queued", "running"} for job in self._jobs.values())
            if self._stop.is_set() or pending >= self.config.max_pending or len(self._jobs) >= self.config.max_jobs:
                raise QueueFull("The video service is busy. Try again after existing downloads finish or expire.")
            if directory_bytes(self.config.cache_dir) >= self.config.max_cache_bytes:
                raise QueueFull("The video cache is full. Try again after existing downloads expire.")
            job_id = str(uuid.uuid4())
            directory = self.config.cache_dir / job_id
            directory.mkdir(mode=0o700)
            job = Job(job_id, post_url, directory, self._clock())
            self._jobs[job_id] = job
            response = job.snapshot()
            self._pool.submit(self._execute, job)
            return response

    def get(self, job_id: str) -> dict | None:
        with self._lock:
            self.prune()
            job = self._jobs.get(job_id)
            return job.snapshot() if job else None

    def media_path(self, job_id: str, filename: str) -> Path | None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+\.mp4", filename):
            return None
        with self._lock:
            self.prune()
            job = self._jobs.get(job_id)
            if not job or job.state != "complete" or filename not in {item["filename"] for item in job.media}:
                return None
            path = job.directory / filename
            return path if path.is_file() and not path.is_symlink() else None

    def _execute(self, job: Job) -> None:
        with self._lock:
            job.state = "running"
        try:
            result = self._runner(job.post_url, job.directory, self.config)
            items = result.get("media", [])
            if not items or len(items) > self.config.max_media:
                raise ServiceError("No downloadable videos were found in this post.")
            media = []
            for item in items:
                filename = item.get("filename", "")
                if not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+\.mp4", filename):
                    raise ServiceError("The video worker returned an invalid media filename.")
                path = job.directory / filename
                if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
                    raise ServiceError("The video download did not produce a valid file.")
                media.append({
                    "url": f"/v1/jobs/{job.id}/media/{filename}",
                    "kind": "video",
                    "filename": filename,
                    "hasAudio": bool(item.get("hasAudio", True)),
                })
            if directory_bytes(job.directory) > self.config.max_job_bytes:
                raise ServiceError("This post exceeds the configured video size limit.")
            with self._lock:
                job.media = media
                job.warning = result.get("warning")
                job.state = "complete"
        except Exception as error:
            with self._lock:
                job.state = "failed"
                job.error = str(error)[:400] if isinstance(error, ServiceError) else "The video download failed. Check the service configuration and try again."
                self._remove_directory(job.directory)
        finally:
            with self._lock:
                job.finished = self._clock()

    def _run_process(self, post_url: str, directory: Path, config: Config) -> dict:
        request_path = directory / "request.json"
        request_path.write_text(json.dumps({
            "postURL": post_url,
            "maxBytes": config.max_job_bytes,
            "maxMedia": config.max_media,
            "cookieFile": str(config.cookie_file) if config.cookie_file else None,
        }), encoding="utf-8")
        environment = os.environ.copy()
        environment.pop("DOWNLOADER_TOKEN", None)
        process = subprocess.Popen(
            [sys.executable, "-m", "downloader_video_service.worker", str(directory)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=environment, start_new_session=True,
        )
        deadline = self._clock() + config.timeout_seconds
        try:
            while process.poll() is None:
                if self._stop.is_set():
                    raise ServiceError("The video service is shutting down. Try again later.")
                if self._clock() >= deadline:
                    raise ServiceError("The video download timed out. The post may be unavailable or too large.")
                if directory_bytes(directory) > config.max_job_bytes:
                    raise ServiceError("This post exceeds the configured video size limit.")
                if directory_bytes(config.cache_dir) > config.max_cache_bytes:
                    raise ServiceError("The video cache reached its configured size limit. Try again later.")
                self._stop.wait(0.25)
            result_path = directory / "result.json"
            if not result_path.is_file() or result_path.stat().st_size > 32768:
                raise ServiceError("The video worker could not finish. Check that yt-dlp, ffmpeg and ffprobe are installed.")
            result = json.loads(result_path.read_text(encoding="utf-8"))
            if process.returncode != 0 or result.get("error"):
                raise ServiceError(result.get("error", "The video download failed."))
            return result
        finally:
            stop_process(process)

    def close(self) -> None:
        self._stop.set()
        self._pool.shutdown(wait=True, cancel_futures=True)
        self._janitor.join(timeout=1)
        with self._lock:
            for job in self._jobs.values():
                self._remove_directory(job.directory)
            self._jobs.clear()
            self._cache_lock.close()
