"""yt-dlp EJS provider using Apple's in-process JavaScriptCore bridge.

The solver is part of the signed application, hash checked by yt-dlp. Only the
YouTube player is fetched by the extractor; no executable or solver is fetched.
"""

import json

from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP, ScriptSource
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProviderError, register_preference, register_provider,
)

try:
    from downloader_native import evaluate_javascript
except ImportError:
    evaluate_javascript = None


@register_provider
class AppleJavaScriptCoreJCP(EJSBaseJCP):
    PROVIDER_NAME = "Apple JavaScriptCore"
    PROVIDER_VERSION = "1.0.0"
    BUG_REPORT_LOCATION = "Downloader's bundled JavaScriptCore provider"
    JS_RUNTIME_NAME = "JavaScriptCore"

    def is_available(self):
        from yt_dlp.dependencies import yt_dlp_ejs
        return callable(evaluate_javascript) and yt_dlp_ejs is not None and self._available

    def _iter_script_sources(self):
        # Preserve upstream version/hash verification but prohibit remote code
        # and cache paths. The Python package is bundled at build time.
        yield ScriptSource.PYPACKAGE, self._pypackage_source

    def _run_js_runtime(self, stdin):
        if not callable(evaluate_javascript):
            raise JsChallengeProviderError("The built-in JavaScript engine is unavailable.")
        try:
            return evaluate_javascript(stdin)
        except Exception as error:
            raise JsChallengeProviderError("The built-in JavaScript challenge failed.") from error

    def _construct_stdin(self, player, preprocessed, requests):
        # Upstream asks for a several-megabyte prepared player even when its
        # cache is disabled. Keep only the challenge results in this process.
        data = {"type": "preprocessed", "preprocessed_player": player} if preprocessed else {
            "type": "player", "player": player, "output_preprocessed": False}
        data["requests"] = [{"type": request.type.value, "challenges": request.input.challenges} for request in requests]
        return (self._lib_script.code + "\nObject.assign(globalThis, lib);\n" + self._core_script.code
                + "\nconsole.log(JSON.stringify(jsc(" + json.dumps(data) + ")));\n")


@register_preference(AppleJavaScriptCoreJCP)
def apple_preference(provider, requests):
    return 10000
