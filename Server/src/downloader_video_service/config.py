from dataclasses import dataclass
import os
from pathlib import Path


@dataclass(frozen=True)
class Config:
    token: str
    host: str = "127.0.0.1"
    port: int = 8787
    cache_dir: Path = Path(".cache/jobs")
    workers: int = 2
    max_pending: int = 8
    max_jobs: int = 100
    ttl_seconds: int = 3600
    timeout_seconds: int = 300
    max_job_bytes: int = 512 * 1024 * 1024
    max_cache_bytes: int = 2 * 1024 * 1024 * 1024
    max_media: int = 20
    cookie_file: Path | None = None

    @classmethod
    def from_env(cls) -> "Config":
        token = os.environ.get("DOWNLOADER_TOKEN", "")
        if len(token) < 32 or any(character.isspace() for character in token):
            raise ValueError("Set DOWNLOADER_TOKEN to a random token of at least 32 characters (without whitespace).")

        def integer(name: str, default: int, minimum: int, maximum: int) -> int:
            try:
                value = int(os.environ.get(name, str(default)))
            except ValueError as error:
                raise ValueError(f"{name} must be an integer.") from error
            if not minimum <= value <= maximum:
                raise ValueError(f"{name} must be between {minimum} and {maximum}.")
            return value

        cookie_path = os.environ.get("DOWNLOADER_COOKIE_FILE")
        cookie_file = Path(cookie_path).expanduser().resolve() if cookie_path else None
        if cookie_file and not cookie_file.is_file():
            raise ValueError("DOWNLOADER_COOKIE_FILE must be an existing Netscape-format cookie file.")
        workers = integer("DOWNLOADER_WORKERS", 2, 1, 8)
        return cls(
            token=token,
            host=os.environ.get("DOWNLOADER_HOST", "127.0.0.1"),
            port=integer("DOWNLOADER_PORT", 8787, 1, 65535),
            cache_dir=Path(os.environ.get("DOWNLOADER_CACHE_DIR", ".cache/jobs")).expanduser().resolve(),
            workers=workers,
            max_pending=integer("DOWNLOADER_MAX_PENDING", 8, workers, 100),
            max_jobs=integer("DOWNLOADER_MAX_JOBS", 100, workers, 10000),
            ttl_seconds=integer("DOWNLOADER_TTL_SECONDS", 3600, 30, 86400),
            timeout_seconds=integer("DOWNLOADER_TIMEOUT_SECONDS", 300, 10, 3600),
            max_job_bytes=integer("DOWNLOADER_MAX_JOB_BYTES", 512 * 1024 * 1024, 1024, 10 * 1024**3),
            max_cache_bytes=integer("DOWNLOADER_MAX_CACHE_BYTES", 2 * 1024**3, 1024, 100 * 1024**3),
            max_media=integer("DOWNLOADER_MAX_MEDIA", 20, 1, 100),
            cookie_file=cookie_file,
        )
