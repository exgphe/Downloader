from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import json
import os
import re
import signal
import sys
import threading
from urllib.parse import unquote, urlsplit

from .config import Config
from .jobs import JobManager, QueueFull
from .urls import InvalidPostURL


JOB_PATH = re.compile(r"/v1/jobs/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})")
MEDIA_PATH = re.compile(r"/v1/jobs/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})/media/([^/]+)")


def byte_range(header: str, size: int) -> tuple[int, int]:
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
    if not match or not any(match.groups()) or size == 0:
        raise ValueError("Invalid range")
    left, right = match.groups()
    if not left:
        length = int(right)
        if length < 1:
            raise ValueError("Invalid range")
        return max(0, size - length), size - 1
    start = int(left)
    end = min(int(right), size - 1) if right else size - 1
    if start >= size or end < start:
        raise ValueError("Unsatisfiable range")
    return start, end


class VideoHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], manager: JobManager):
        self.manager = manager
        self._connections = threading.BoundedSemaphore(16)
        super().__init__(address, RequestHandler)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(15)
        return request, address

    def process_request(self, request, client_address):
        if not self._connections.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._connections.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._connections.release()


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "DownloaderVideoService/0.1"

    @property
    def manager(self) -> JobManager:
        return self.server.manager

    def log_message(self, format: str, *args) -> None:
        # Tokens and post URLs are never written to access logs.
        return

    def _json(self, status: int, value: dict) -> None:
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if status == HTTPStatus.UNAUTHORIZED:
            self.send_header("WWW-Authenticate", 'Bearer realm="Downloader"')
        if status == HTTPStatus.TOO_MANY_REQUESTS:
            self.send_header("Retry-After", "10")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _authenticated(self) -> bool:
        headers = self.headers.get_all("Authorization", [])
        authorized = len(headers) == 1 and headers[0].startswith("Bearer ")
        if authorized:
            authorized = hmac.compare_digest(headers[0][7:].encode("utf-8"), self.manager.config.token.encode("utf-8"))
        if not authorized:
            self.close_connection = True
            self._json(HTTPStatus.UNAUTHORIZED, {"error": "A valid video service bearer token is required."})
        return authorized

    def do_POST(self) -> None:
        if not self._authenticated():
            return
        if urlsplit(self.path).path != "/v1/jobs":
            self._json(HTTPStatus.NOT_FOUND, {"error": "Unknown API endpoint."})
            return
        if self.headers.get("Transfer-Encoding"):
            self._json(HTTPStatus.BAD_REQUEST, {"error": "Chunked request bodies are not supported."})
            return
        if self.headers.get_content_type() != "application/json":
            self._json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "Use an application/json request body."})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) != 1:
            self._json(HTTPStatus.LENGTH_REQUIRED, {"error": "A Content-Length header is required."})
            return
        try:
            length = int(lengths[0])
        except ValueError:
            self._json(HTTPStatus.BAD_REQUEST, {"error": "Invalid Content-Length."})
            return
        if not 0 < length <= 8192:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "The request body must be between 1 and 8192 bytes."})
            return
        try:
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError("Incomplete request body.")
            payload = json.loads(data.decode("utf-8"))
            if not isinstance(payload, dict) or not isinstance(payload.get("postURL"), str):
                raise ValueError("Provide a JSON object with a postURL string.")
            result = self.manager.submit(payload["postURL"])
        except InvalidPostURL as error:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
        except (ValueError, UnicodeError) as error:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)[:200]})
        except QueueFull as error:
            self._json(HTTPStatus.TOO_MANY_REQUESTS, {"error": str(error)})
        else:
            self._json(HTTPStatus.ACCEPTED, result)

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        if not self._authenticated():
            return
        path = unquote(urlsplit(self.path).path)
        if path == "/health":
            self._json(HTTPStatus.OK, {"status": "ok"})
            return
        match = JOB_PATH.fullmatch(path)
        if match:
            result = self.manager.get(match[1])
            if result is None:
                self._json(HTTPStatus.NOT_FOUND, {"error": "This video job does not exist or has expired."})
            else:
                self._json(HTTPStatus.OK, result)
            return
        match = MEDIA_PATH.fullmatch(path)
        if match:
            self._send_media(match[1], match[2])
            return
        self._json(HTTPStatus.NOT_FOUND, {"error": "Unknown API endpoint."})

    def _send_media(self, job_id: str, filename: str) -> None:
        path = self.manager.media_path(job_id, filename)
        if path is None:
            self._json(HTTPStatus.NOT_FOUND, {"error": "This video file does not exist or has expired."})
            return
        try:
            media_file = path.open("rb")
        except FileNotFoundError:
            self._json(HTTPStatus.NOT_FOUND, {"error": "This video file has expired."})
            return
        with media_file:
            size = os.fstat(media_file.fileno()).st_size
            start, end = 0, size - 1
            status = HTTPStatus.OK
            range_header = self.headers.get("Range")
            if range_header:
                try:
                    start, end = byte_range(range_header, size)
                except ValueError:
                    self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = HTTPStatus.PARTIAL_CONTENT
            self.send_response(status)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "private, no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if range_header:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if self.command == "HEAD":
                return
            media_file.seek(start)
            remaining = end - start + 1
            try:
                while remaining > 0:
                    chunk = media_file.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                return


def main() -> None:
    try:
        config = Config.from_env()
    except ValueError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
    manager = JobManager(config)
    try:
        server = VideoHTTPServer((config.host, config.port), manager)
    except Exception:
        manager.close()
        raise

    def interrupt(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    print(f"Downloader video service listening on {config.host}:{config.port}; bearer authentication is required.", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        manager.close()


if __name__ == "__main__":
    main()
