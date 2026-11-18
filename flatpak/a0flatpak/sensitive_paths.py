"""Guard the File Browser API: credential paths and write boundaries.

The File Browser root is ``/`` on purpose: the agent works on the real
machine.  Reads stay that way, but writes must not delete or replace arbitrary
host files.  This module answers 403 for credential directories and for writes
outside the configured work roots, and it keeps error bodies free of
tracebacks.

Write roots come from ``A0_WRITE_ROOTS`` (colon-separated); the default is
``/a0:~/Documents:~/Downloads``.  Reads are not restricted by this list.
"""

from __future__ import annotations

import importlib
import json
import os
import posixpath

from a0flatpak import plugin_guard

SENSITIVE_MARKER = "SENSITIVE_PATH_BLOCKED"
SENSITIVE_MESSAGE = "This path holds credentials and is not available to the agent."
WRITE_MARKER = "WRITE_OUTSIDE_WORKDIR"
WRITE_MESSAGE = (
    "Writes are limited to /a0, ~/Documents and ~/Downloads (A0_WRITE_ROOTS)."
)
INTERNAL_MARKER = "INTERNAL"
INTERNAL_MESSAGE = "Internal server error."

# Relative to the user's home.  Keep this list in step with the manifest's
# --nofilesystem entries.
SENSITIVE_DIRS = (
    ".ssh",
    ".gnupg",
    ".pki",
    ".local/share/keyrings",
    ".config/gh",
    ".aws",
    ".docker",
    ".kube",
)

DEFAULT_WRITE_ROOTS = ("/a0", "~/Documents", "~/Downloads")


def _resolve(path: object) -> str:
    value = os.path.expanduser(os.fspath(path))
    # The File Browser resolves relative names against its root, ``/``.
    return os.path.realpath(os.path.join("/", value))


def _roots() -> tuple[str, ...]:
    home = os.path.expanduser("~")
    return tuple(os.path.realpath(os.path.join(home, name)) for name in SENSITIVE_DIRS)


def is_sensitive(path: object) -> bool:
    if not path:
        return False
    resolved = _resolve(path)
    for root in _roots():
        if resolved == root or resolved.startswith(root + os.sep):
            return True
    return False


def write_roots() -> tuple[str, ...]:
    """Return the configured write roots, resolved through symlinks."""
    raw = os.environ.get("A0_WRITE_ROOTS", "").strip()
    values = raw.split(":") if raw else list(DEFAULT_WRITE_ROOTS)
    return tuple(os.path.realpath(os.path.expanduser(value.strip())) for value in values)


def is_write_allowed(path: object) -> bool:
    """True when ``path`` resolves under one of the write roots."""
    if not path:
        return True
    resolved = _resolve(path)
    for root in write_roots():
        if resolved == root or resolved.startswith(root + os.sep):
            return True
    return False


def _response(status: int, error: str, message: str):
    from helpers.api import Response

    return Response(
        json.dumps({"ok": False, "error": error, "message": message}),
        status=status,
        mimetype="application/json",
    )


def blocked_response():
    return _response(403, SENSITIVE_MARKER, SENSITIVE_MESSAGE)


def write_blocked_response():
    return _response(403, WRITE_MARKER, WRITE_MESSAGE)


def internal_response():
    return _response(500, INTERNAL_MARKER, INTERNAL_MESSAGE)


def _error_response(status: int, error: str, message: str):
    return _response(status, error, message)


def _download_paths(input: dict, request) -> list[object]:
    return [request.args.get("path", "") or input.get("path", "")]


def _list_paths(input: dict, request) -> list[object]:
    return [request.args.get("path", "")]


def _delete_one_paths(input: dict, request) -> list[object]:
    return [input.get("path", "")]


def _delete_many_paths(input: dict, request) -> list[object]:
    return list(input.get("paths", []) or [])


def _edit_paths(input: dict, request) -> list[object]:
    if request.method == "GET":
        return [request.args.get("path", "")]
    return [input.get("path", "")]


def _edit_write_paths(input: dict, request) -> list[object]:
    return [] if request.method == "GET" else [input.get("path", "")]


def _file_info_paths(input: dict, request) -> list[object]:
    return [input.get("path", "")]


def _rename_paths(input: dict, request) -> list[object]:
    paths: list[object] = [input.get("path", ""), input.get("destinationPath", "")]
    paths.extend(input.get("paths", []) or [])
    parent = input.get("parentPath") or ""
    name = input.get("newName") or ""
    if parent and name:
        paths.append(posixpath.join(str(parent).rstrip("/"), str(name)))
    return paths


def _upload_paths(input: dict, request) -> list[object]:
    current = request.form.get("path", "")
    paths: list[object] = [current]
    for storage in request.files.getlist("files[]"):
        filename = getattr(storage, "filename", "") or ""
        if current and filename:
            paths.append(posixpath.join(str(current).rstrip("/"), filename))
    return paths


def _recursive(input: dict) -> bool:
    value = input.get("recursive")
    return value is True or str(value).strip().lower() == "true"


def _non_empty_dir(path: object) -> bool:
    try:
        resolved = _resolve(path)
        return (
            os.path.isdir(resolved)
            and not os.path.islink(resolved)
            and bool(os.listdir(resolved))
        )
    except OSError:
        return False


def _delete_precheck(input: dict, request):
    if _non_empty_dir(input.get("path", "")) and not _recursive(input):
        return _error_response(
            409,
            "NON_EMPTY_DIRECTORY",
            "pass recursive=true to delete a non-empty directory",
        )
    return None


def _delete_many_precheck(input: dict, request):
    if _recursive(input):
        return None
    for path in input.get("paths", []) or []:
        if _non_empty_dir(path):
            return _error_response(
                409,
                "NON_EMPTY_DIRECTORY",
                "pass recursive=true to delete a non-empty directory",
            )
    return None


def _download_precheck(input: dict, request):
    path = request.args.get("path", "") or input.get("path", "")
    if path and not os.path.exists(_resolve(path)):
        return _error_response(404, "NOT_FOUND", f"File not found: {path}")
    return None


def _result_error(result, *, status: int, code: str):
    """Turn a 200 body carrying ``error`` into the requested 4xx JSON."""
    if not isinstance(result, dict):
        return None
    error = result.get("error")
    if not error:
        data = result.get("data")
        if isinstance(data, dict):
            error = data.get("error")
    if not error:
        return None
    message = str(error)
    if "not found" in message.lower():
        return _error_response(404, "NOT_FOUND", message)
    return _error_response(status, code, message)


def _list_postprocess(result):
    return _result_error(result, status=400, code="LIST_FAILED")


def _delete_postprocess(result):
    return _result_error(result, status=409, code="DELETE_FAILED")


def _edit_postprocess(result):
    return _result_error(result, status=409, code="EDIT_FAILED")


def _rename_postprocess(result):
    return _result_error(result, status=409, code="RENAME_FAILED")


def _extract_postprocess(result):
    return _result_error(result, status=400, code="EXTRACT_FAILED")


def _upload_postprocess(result):
    return _result_error(result, status=409, code="UPLOAD_FAILED")


def _patch_class(
    handler,
    paths_for,
    *,
    write_paths_for=None,
    precheck=None,
    postprocess=None,
) -> None:
    if getattr(handler, "_a0flatpak_sensitive_patched", False):
        return

    original = handler.process

    async def process(self, input, request):
        data = input or {}
        for path in paths_for(data, request):
            if is_sensitive(path):
                return blocked_response()
        if write_paths_for is not None:
            for path in write_paths_for(data, request):
                if is_sensitive(path):
                    return blocked_response()
                if not is_write_allowed(path):
                    return write_blocked_response()
        if precheck is not None:
            response = precheck(data, request)
            if response is not None:
                return response
        try:
            result = await original(self, data, request)
        except Exception as exc:
            plugin_guard.log(f"file-api {handler.__name__}", "handler failed", exc)
            return internal_response()
        if postprocess is not None:
            response = postprocess(result)
            if response is not None:
                return response
        return result

    handler.process = process
    handler._a0flatpak_sensitive_patched = True


def _patch_resolve(module) -> None:
    if getattr(module, "_a0flatpak_resolve_patched", False):
        return
    original = module.resolve_download_path

    def resolve_download_path(path: str) -> str:
        if is_sensitive(path):
            raise ValueError(SENSITIVE_MARKER)
        return original(path)

    module.resolve_download_path = resolve_download_path
    module._a0flatpak_resolve_patched = True


def _patch_module(module, class_name: str, **options) -> None:
    handler = getattr(module, class_name, None)
    if not isinstance(handler, type):
        return
    _patch_class(handler, **options)
    if class_name == "DownloadFile":
        _patch_resolve(module)


HANDLERS = (
    ("api.get_work_dir_files", "GetWorkDirFiles", {"paths_for": _list_paths, "postprocess": _list_postprocess}),
    ("api.download_work_dir_file", "DownloadFile", {"paths_for": _download_paths, "precheck": _download_precheck}),
    ("api.delete_work_dir_file", "DeleteWorkDirFile", {"paths_for": _delete_one_paths, "write_paths_for": _delete_one_paths, "precheck": _delete_precheck, "postprocess": _delete_postprocess}),
    ("api.delete_work_dir_files", "DeleteWorkDirFiles", {"paths_for": _delete_many_paths, "write_paths_for": _delete_many_paths, "precheck": _delete_many_precheck, "postprocess": _delete_postprocess}),
    ("api.edit_work_dir_file", "EditWorkDirFile", {"paths_for": _edit_paths, "write_paths_for": _edit_write_paths, "postprocess": _edit_postprocess}),
    ("api.file_info", "FileInfoApi", {"paths_for": _file_info_paths}),
    ("api.rename_work_dir_file", "RenameWorkDirFile", {"paths_for": _rename_paths, "write_paths_for": _rename_paths, "postprocess": _rename_postprocess}),
    ("api.extract_work_dir_archive", "ExtractWorkDirArchive", {"paths_for": _file_info_paths, "write_paths_for": _file_info_paths, "postprocess": _extract_postprocess}),
    ("api.upload_work_dir_files", "UploadWorkDirFiles", {"paths_for": _upload_paths, "write_paths_for": _upload_paths, "postprocess": _upload_postprocess}),
    ("api.api_files_get", "ApiFilesGet", {"paths_for": _delete_many_paths, "postprocess": _list_postprocess}),
)


def _patch_global_500() -> None:
    """Replace any API 500 body with JSON; the traceback stays in the log."""
    from helpers.api import ApiHandler

    if getattr(ApiHandler, "_a0flatpak_500_patched", False):
        return

    original = ApiHandler.handle_request

    async def handle_request(self, request):
        response = await original(self, request)
        if getattr(response, "status_code", None) == 500:
            return internal_response()
        return response

    ApiHandler.handle_request = handle_request
    ApiHandler._a0flatpak_500_patched = True


def apply() -> None:
    """Install every file API guard.  Safe to repeat."""
    _patch_global_500()

    for suffix, class_name, options in HANDLERS:
        def patch(module, _class=class_name, _options=options):
            _patch_module(module, _class, **_options)

        plugin_guard.register_module(suffix, patch)
        modules = plugin_guard.live_modules(suffix)
        if not modules:
            modules = [importlib.import_module(suffix)]
        for module in modules:
            _patch_module(module, class_name, **options)
