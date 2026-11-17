"""Optional X11 native tools, session cursor, and trajectory evidence."""
import configparser
import ctypes
import ctypes.util
import importlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

CONFIG_PATH = Path.home() / ".linux-use/config.json"
SESSION = {"session": None, "capture_scope": "desktop"}
CURSOR = {"enabled": True, "theme": "default", "motion": "instant", "x": 0, "y": 0,
          "scope": "window", "overlay_available": False, "theme_id": "default", "reduced_motion": "auto"}
OVERLAY = None
OVERLAY_DIR = None
RECORDING = {"active": False, "output_dir": None, "turn": 0, "video": False}
VIDEO = None
DISPATCH_DEPTH = 0
# When this server last sent X input. XTest input resets the X idle timer exactly as the user's own
# does; the guard must not take the agent's pointer motion for a person.
AGENT_INPUT = {"at": float("-inf")}
# xdotool can exit before the X server has processed its last event.
AGENT_INPUT_GRACE = 0.25
# The last screenshot given for each window: click pixels are read from that image, not the window.
SCREENSHOTS = {}
# What to do next, for the refusals a caller can act on; a bare refusal sent agents into repeating the call.
HUMAN_ACTIVITY_HINT = ("Hint: the user is using this target. Prefer a route that does not disturb them (background delivery, "
                       "an AT-SPI action, or a short wait and one retry). If none works, retry with allow_while_user_active: true, "
                       "unless the user said not to interrupt them.")
STALE_HINT = "Hint: the window changed since that token was read. Take a new screenshot and retry with its state_token."
MISSING_HINT = "Hint: that pid and window id are not on the window list now. Call list_windows."
FOCUS_HINT = ("Hint: the window manager did not hand focus to the window. Retry once, use restore_window, "
              "or use background delivery, which needs no focus.")

STRING = {"type": "string"}
INTEGER = {"type": "integer"}
BOOL = {"type": "boolean"}
STRINGS = {"type": "array", "items": STRING}
TARGET = {"pid": INTEGER, "window_id": INTEGER, "target_pid": INTEGER,
          "target_window_id": INTEGER, "expected_state_token": STRING}
SELECTOR = {"type": "object", "properties": {"element_id": STRING, "role": STRING, "label": STRING}, "additionalProperties": False}
DELIVERY = {"delivery_mode": {"type": "string", "enum": ["background", "foreground"]}}
INPUT = {**TARGET, **DELIVERY}
COORDS = {"x": INTEGER, "y": INTEGER}
CLICK = {**INPUT, **COORDS, "button": {"type": "string", "enum": ["left", "right", "middle"]},
         "count": {"type": "integer", "minimum": 1, "maximum": 100}, "modifier": STRINGS}
PROPERTIES = {
    "list_apps": {},
    "launch_app": {"name": STRING, "desktop_id": STRING, "bundle_id": STRING, "command": STRING,
                   "urls": STRINGS, "additional_arguments": STRINGS, "creates_new_application_instance": BOOL},
    "kill_app": {"pid": INTEGER}, "bring_to_front": TARGET,
    "get_accessibility_tree": {}, "get_desktop_state": {}, "get_screen_size": {},
    "get_cursor_position": {},
    "move_cursor": {**TARGET, **COORDS, "scope": {"type": "string", "enum": ["window", "desktop"]}},
    "click": CLICK, "double_click": CLICK, "right_click": CLICK,
    "drag": {**INPUT, "from_x": INTEGER, "from_y": INTEGER, "to_x": INTEGER, "to_y": INTEGER},
    "type_text": {**INPUT, "text": STRING},
    "press_key": {**INPUT, "key": STRING, "modifiers": STRINGS},
    "hotkey": {**INPUT, "keys": STRINGS},
    "set_window_frame": {**TARGET, "x": INTEGER, "y": INTEGER, "w": {"type": "integer", "minimum": 1},
                         "h": {"type": "integer", "minimum": 1}},
    "verify_state": {**TARGET, "browser": BOOL, "expect": {"type": "object", "properties": {
        "title_contains": STRING, "window_exists": BOOL, "active": BOOL,
        "element_exists": SELECTOR, "focused_element": SELECTOR,
        "element_value": {"type": "object", "properties": {**SELECTOR["properties"], "equals": STRING}, "required": ["equals"], "additionalProperties": False},
        "criteria": {"type": "array", "minItems": 1, "maxItems": 8, "items": {"type": "string", "minLength": 1, "maxLength": 200}}}, "additionalProperties": False}},
    "clipboard_read": {"include_text": BOOL},
    "clipboard_write": {"text": STRING, "image_path": STRING, "file_path": STRING},
    "check_permissions": {}, "health_report": {}, "get_config": {},
    "set_config": {"allow_without_activity_check": BOOL, "max_image_dimension": {"type": "integer", "minimum": 0, "maximum": 16384}},
    "start_session": {"session": STRING, "capture_scope": {"type": "string", "enum": ["desktop", "window"]}},
    "end_session": {}, "get_session_state": {},
    "set_agent_cursor_enabled": {"enabled": BOOL}, "set_agent_cursor_theme": {"theme_id": STRING, "theme": STRING, "reduced_motion": {"type": "string", "enum": ["auto", "on", "off"]}},
    "set_agent_cursor_motion": {"motion": {"type": "string", "enum": ["instant", "smooth"]}, "style": {"type": "string", "enum": ["classic"]}, "timing": {"type": "string", "enum": ["native", "fixed"]}, "glide_duration_ms": {"type": "integer", "minimum": 0, "maximum": 5000}},
    "get_agent_cursor_state": {},
    "start_recording": {"output_dir": STRING, "record_video": BOOL}, "stop_recording": {},
    "get_recording_state": {}, "replay_trajectory": {"dir": STRING, "delay_ms": {"type": "integer", "minimum": 0, "maximum": 10000}, "stop_on_error": BOOL},
    "invoke_menu": {**TARGET, "path": STRINGS},
    "set_value": {**TARGET, "role": STRING, "label": STRING, "element_id": STRING, "value": {"type": ["string", "number"]}},
    "run_steps": {"steps": {"type": "array", "minItems": 1, "maxItems": 32, "items": {
                      "type": "object", "properties": {"tool": STRING, "arguments": {"type": "object"}},
                      "required": ["tool"], "additionalProperties": False}},
                  "observe": {"type": "object", "description": "Arguments for one screenshot after the steps: target_pid, "
                              "target_window_id and optionally max_image_dimension."}},
}
REQUIRED = {
    "kill_app": ["pid"], "move_cursor": ["x", "y"], "click": ["x", "y"],
    "double_click": ["x", "y"], "right_click": ["x", "y"],
    "drag": ["from_x", "from_y", "to_x", "to_y"], "type_text": ["text"],
    "press_key": ["key"], "hotkey": ["keys"], "set_window_frame": ["x", "y", "w", "h"],
    "verify_state": ["expect"], "start_session": ["session"], "set_agent_cursor_enabled": ["enabled"],
    "set_agent_cursor_theme": [], "set_agent_cursor_motion": [],
    "start_recording": ["output_dir"], "replay_trajectory": ["dir"], "invoke_menu": ["path"],
    "set_value": ["value"], "run_steps": ["steps"],
}
for properties in PROPERTIES.values():
    properties["session"] = STRING
ALLOW_WHILE_USER_ACTIVE = {"type": "boolean", "description": "Act even though the user is using the target. Only after the "
                           "non-disturbing routes failed, and never when the user said not to interrupt them."}

READ_ONLY = {"list_apps", "get_accessibility_tree", "get_desktop_state", "get_screen_size",
             "get_cursor_position", "verify_state", "clipboard_read", "check_permissions", "health_report",
             "get_config", "get_session_state", "get_agent_cursor_state", "get_recording_state"}
CONTROL = {"start_recording", "stop_recording", "replay_trajectory", "run_steps"}
MUTATIONS = set(PROPERTIES) - READ_ONLY
# Stealth is the default; every mutation can be escalated once the quiet routes failed.
for tool in MUTATIONS - {"run_steps"}:  # each step carries its own
    PROPERTIES[tool]["allow_while_user_active"] = ALLOW_WHILE_USER_ACTIVE
LEGACY_MUTATIONS = {"restore_window", "left_click", "type", "key", "scroll", "click_element",
                    "native_visual_execute", "browser_open", "browser_act", "browser_close"}
DESCRIPTIONS = {
    "verify_state": "Verify exact window conditions, AT-SPI element checks (element_exists, element_value, focused_element) or 1-8 natural-language criteria (200 characters each), judged by the decision model (liquid/d1.2-ultra, Jev on fallback). browser:true uses owned Chrome labels only; otherwise the window title, AT-SPI labels and, for one window, its screenshot (1024 px; none with a password field). Each criterion reports probability, engine and image_attached. No key returns unknown with filtered evidence.",
    "list_apps": "List X11 window-owning processes and installed desktop applications.",
    "launch_app": "Launch exactly one name, desktop_id, or command detached without activating its windows; return PID and new windows.",
    "get_accessibility_tree": "X11 desktop window summary with geometry, stacking order and active window; not an AT-SPI element tree.",
    "move_cursor": "Window scope updates agent overlay only; desktop scope moves the physical pointer.",
    "click": "Window-local click. Background uses XSendEvent without activation; foreground temporarily activates and restores focus. Coordinates move the physical pointer.",
    "drag": "Window-local drag uses the physical pointer; foreground delivery restores previous focus.",
    "type_text": "Type into explicit X11 window; background uses xdotool --window, foreground restores focus.",
    "invoke_menu": "Invoke an exact enabled AT-SPI menu path; requires python gi Atspi.",
    "set_value": "Set an editable AT-SPI value, chosen by element_id from get_ui_tree (with its state_token as expected_state_token) or by an unambiguous role/label; verifies by readback and never retries. Requires python gi Atspi.",
    "start_recording": "Record mutations as turn folders with action, before/after PNG and evidence; optionally capture ffmpeg X11 video.",
    "clipboard_read": "Read the clipboard; its text is returned only when include_text is true.",
    "clipboard_write": "Replace the clipboard with exactly one of text, image_path (PNG) or file_path. Paths must be absolute and contain no symlinks.",
    "set_config": "Persist allow_without_activity_check and max_image_dimension (long-edge limit of screenshots, default 1366; 0 keeps the native frame) in ~/.linux-use/config.json.",
    "run_steps": "Run up to 32 tool calls in order in one round trip, stopping at the first that fails, then optionally take one screenshot (observe: the arguments of screenshot). Use it to act and look together: steps:[{tool, arguments}]. Each step is validated, guarded and recorded like its own call; step results are text; a step cannot be run_steps or replay_trajectory.",
    "replay_trajectory": "Replay recorded mutations in order with current human-activity and argument checks; does not bypass stale tokens.",
}


def description(name):
    return DESCRIPTIONS.get(name, name.replace("_", " ").capitalize() + ". X11 utilities must be installed; recent human activity refuses mutations.")


def schema(name):
    return {"type": "object", "properties": PROPERTIES[name], "required": REQUIRED.get(name, []),
            "additionalProperties": False}


def validate(value, spec, path="arguments"):
    types = spec.get("type", [])
    if isinstance(types, str):
        types = [types]
    checks = {"object": lambda v: isinstance(v, dict), "array": lambda v: isinstance(v, list),
              "string": lambda v: isinstance(v, str) and "\x00" not in v,
              "integer": lambda v: type(v) is int, "number": lambda v: type(v) in (int, float),
              "boolean": lambda v: type(v) is bool}
    if types and not any(checks[t](value) for t in types):
        raise ValueError(f"{path} must have type {types} and contain no NUL.")
    if "enum" in spec and value not in spec["enum"]:
        raise ValueError(f"{path} must be one of {spec['enum']}.")
    if type(value) in (int, float):
        if value < spec.get("minimum", float("-inf")) or value > spec.get("maximum", float("inf")):
            raise ValueError(f"{path} is outside the allowed range.")
    if isinstance(value, str) and not spec.get("minLength", 0) <= len(value) <= spec.get("maxLength", float("inf")):
        raise ValueError(f"{path} has an invalid length.")
    if isinstance(value, list) and not spec.get("minItems", 0) <= len(value) <= spec.get("maxItems", float("inf")):
        raise ValueError(f"{path} has an invalid item count.")
    if isinstance(value, dict):
        props = spec.get("properties", {})
        if any(key not in value for key in spec.get("required", [])):
            raise ValueError(f"{path} requires {spec['required']}.")
        if spec.get("additionalProperties") is False and set(value) - set(props):
            raise ValueError(f"Unknown {path} fields: {sorted(set(value) - set(props))}.")
        for key, item in value.items():
            if key in props:
                validate(item, props[key], f"{path}.{key}")
    if isinstance(value, list):
        for item in value:
            validate(item, spec.get("items", {}), path + "[]")


def require_x11(s):
    if not os.environ.get("DISPLAY") or os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland":
        raise s.Unsupported("Linux native controls require an X11 DISPLAY; Wayland is unsupported.")


def target(s, args, optional=False):
    require_x11(s)
    wid = args.get("window_id", args.get("target_window_id"))
    pid = args.get("pid", args.get("target_pid"))
    if wid is None and pid is None:
        if optional:
            return None
        raise ValueError("window_id or pid is required; implicit active-window targeting is forbidden.")
    if wid is not None and (type(wid) is not int or wid <= 0):
        raise ValueError("window_id must be a positive integer.")
    if pid is not None and (type(pid) is not int or pid <= 0):
        raise ValueError("pid must be a positive integer.")
    windows = [w for w in s.list_windows() if (wid is None or w["window_id"] == wid) and (pid is None or w["pid"] == pid)]
    if len(windows) != 1:
        raise s.Unsupported("Target window identity is missing or ambiguous; no action was performed. " + MISSING_HINT)
    window = windows[0]
    if "expected_state_token" in args and s.token_view(args["expected_state_token"], window) is None:
        raise s.Unsupported("Target state token is stale; refresh before acting. " + STALE_HINT)
    return window


def active_window(s):
    value = s.run_cli("xdotool", "getactivewindow").strip()
    try:
        return int(value, 0)
    except ValueError as exc:
        raise s.Unsupported("Cannot determine active X11 window safely.") from exc


def front_or_none(s):
    try:
        return active_window(s)
    except s.Unsupported:
        return None


def user_on(s, window):
    """Whether the user is on this window now. Escalation does not apply: focus is never taken back from them."""
    try:
        human_guard(s, {"window_id": window["window_id"]})
        return False
    except s.Unsupported:
        return True


def hand_front_back(s, window, previous):
    """Reactivate `previous` only while the target still holds the front and the user is not on it."""
    if previous is None or previous == window["window_id"] or front_or_none(s) != window["window_id"] or user_on(s, window):
        return False
    s.run_cli("wmctrl", "-ia", hex(previous))
    return True


def human_guard(s, args, all_windows=False):
    if not shutil.which("xprintidle"):
        if not get_config(s)["allow_without_activity_check"]:
            raise s.Unsupported("human_activity_check_unavailable: install xprintidle")
        return
    if args.get("allow_while_user_active") is True:
        return
    require_x11(s)
    started = time.monotonic()
    idle = s.run_cli("xprintidle").strip()
    if not idle.isdigit():
        raise s.Unsupported("Cannot determine X11 idle time safely.")
    # The last input arrived `idle` ms ago; when that was no later than our own last injection, it was ours.
    if int(idle) >= 2000 or started - int(idle) / 1000 <= AGENT_INPUT["at"] + AGENT_INPUT_GRACE:
        return
    pointer = s.run_cli("xdotool", "getmouselocation", "--shell")
    match = re.search(r"^WINDOW=(\d+)$", pointer, re.M)
    if not match:
        raise s.Unsupported("Cannot determine pointer target safely.")
    active = active_window(s)
    wid = args.get("window_id", args.get("target_window_id"))
    pid = args.get("pid", args.get("target_pid"))
    windows = s.list_windows()
    ids = {w["window_id"] for w in windows if (wid is None or w["window_id"] == wid) and (pid is None or w["pid"] == pid)}
    if all_windows or wid is None and pid is None or active in ids or int(match[1]) in ids:
        raise s.Unsupported("human_activity: recent pointer/keyboard activity on the target window; no mutation performed. "
                            + HUMAN_ACTIVITY_HINT)


def inject(s, *command):
    """Run an xdotool input command as the agent and remember when, for human_guard."""
    try:
        return s.run_cli(*command)
    finally:
        AGENT_INPUT["at"] = time.monotonic()


def health(s):
    utilities = {name: shutil.which(name) for name in ("wmctrl", "xdotool", "xwd", "convert", "magick", "xprop", "xdpyinfo", "xrandr", "xprintidle", "xclip", "xsel", "ffmpeg")}
    try:
        gi = importlib.import_module("gi")
        gi.require_version("Atspi", "2.0")
        importlib.import_module("gi.repository.Atspi")
        atspi_available = True
    except (ImportError, ValueError):
        atspi_available = False
    return {"x11": bool(os.environ.get("DISPLAY")) and os.environ.get("XDG_SESSION_TYPE", "").lower() != "wayland",
            "session_type": os.environ.get("XDG_SESSION_TYPE"), "utilities": utilities,
            "human_activity_check": "available" if utilities["xprintidle"] else "skipped: xprintidle is not installed",
            "atspi_available": atspi_available, "accessibility": "AT-SPI available" if atspi_available else "unsupported: python gi Atspi unavailable"}


def available_tools(s):
    status = health(s)
    if not status["x11"]:
        return []
    utilities = status["utilities"]
    needs = {
        "list_apps": ("wmctrl", "xdotool"), "launch_app": ("wmctrl", "xdotool"),
        "bring_to_front": ("wmctrl", "xdotool"), "get_accessibility_tree": ("wmctrl", "xdotool", "xprop"),
        "get_cursor_position": ("xdotool",), "move_cursor": ("wmctrl", "xdotool"),
        "set_window_frame": ("wmctrl",), "verify_state": ("wmctrl", "xdotool"),
    }
    for name in ("click", "double_click", "right_click", "drag", "type_text", "press_key", "hotkey"):
        needs[name] = ("wmctrl", "xdotool")
    supported = []
    for name in PROPERTIES:
        if not all(utilities.get(utility) for utility in needs.get(name, ())):
            continue
        if name == "get_desktop_state" and not (utilities["xwd"] and (utilities["convert"] or utilities["magick"])):
            continue
        if name == "get_screen_size" and not (utilities["xdpyinfo"] or utilities["xrandr"]):
            continue
        if name in ("clipboard_read", "clipboard_write") and not (utilities["xclip"] or utilities["xsel"]):
            continue
        if name in ("invoke_menu", "set_value") and not status["atspi_available"]:
            continue
        supported.append(name)
    return supported


def get_config(s):
    try:
        config = json.loads(CONFIG_PATH.read_text()) if CONFIG_PATH.exists() else {}
        validate(config, {**schema("set_config"), "properties": PROPERTIES["set_config"]}, "config")
        return {"max_image_dimension": 1366, "allow_without_activity_check": False, **config}
    except (OSError, ValueError) as exc:
        raise s.Unsupported(f"Cannot read config safely: {exc}") from exc


def root_png(s):
    require_x11(s)
    return s.capture_png(["-root"])


def desktop_entries():
    entries = {}
    for directory in (Path("/usr/share/applications"), Path.home() / ".local/share/applications"):
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.desktop")):
            try:
                config = configparser.ConfigParser(interpolation=None, strict=False)
                config.read(path, encoding="utf-8")
                entry = config["Desktop Entry"]
                desktop_id = str(path.relative_to(directory)).replace("/", "-")
                entries[desktop_id] = {"desktop_id": desktop_id, "name": entry.get("Name", path.stem),
                                       "exec": entry.get("Exec", ""), "path": str(path),
                                       "hidden": entry.get("Hidden", "false").lower() == "true",
                                       "type": entry.get("Type", "Application")}
            except (OSError, UnicodeError, configparser.Error, KeyError):
                continue
    return [entry for entry in entries.values() if not entry["hidden"] and entry["type"] == "Application"]


def application_command(args, entries):
    selectors = [key for key in ("name", "desktop_id", "bundle_id", "command") if args.get(key)]
    if len(selectors) != 1:
        raise ValueError("Provide exactly one name, desktop_id, bundle_id, or command.")
    if selectors[0] == "command":
        command = shlex.split(args["command"])
        entry = None
    else:
        value = args[selectors[0]]
        matches = [e for e in entries if e["desktop_id"] == value or e["name"].casefold() == value.casefold()]
        if len(matches) != 1:
            raise ValueError("Installed application is missing or ambiguous; use exact desktop_id or command.")
        entry = matches[0]
        command = shlex.split(entry["exec"])
    urls = args.get("urls", [])
    result = []
    used_urls = False
    for arg in command:
        if arg in ("%U", "%F"):
            result.extend(urls); used_urls = True
        elif arg in ("%u", "%f"):
            result.extend(urls[:1]); used_urls = True
        elif arg == "%c" and entry:
            result.append(entry["name"])
        elif arg == "%k" and entry:
            result.append(entry["path"])
        elif arg == "%i":
            continue
        elif re.search(r"%[A-Za-z]", arg):
            raise ValueError("Unsupported embedded desktop Exec field code.")
        else:
            result.append(arg.replace("%%", "%"))
    if not used_urls:
        result.extend(urls)
    result.extend(args.get("additional_arguments", []))
    if not result or not result[0] or result[0].startswith("-"):
        raise ValueError("Application command must name an executable.")
    return result


def record_screenshot(window_id, view):
    SCREENSHOTS.pop(window_id, None)
    SCREENSHOTS[window_id] = view
    while len(SCREENSHOTS) > 16:
        SCREENSHOTS.pop(next(iter(SCREENSHOTS)))


def to_window(window, x, y, view=None):
    """Window pixels for x,y read from the image a caller was shown. `view` is the screenshot or zoom
    (image_size, region, frame) they came from; without one, or once the window has another size,
    x,y are window pixels. A pixel outside that image is refused, not clamped."""
    width, height = window["geometry"][2:]
    image, shown = [width, height], [0, 0, width, height]
    if view and view.get("image_size") and list(view.get("geometry", [])[2:]) == [width, height]:
        image, shown = view["image_size"], view.get("region") or shown
    if not (0 <= x < image[0] and 0 <= y < image[1]):
        raise ValueError(f"Coordinates are outside the target window's {image[0]}x{image[1]} image pixels.")
    return shown[0] + int((x + 0.5) * shown[2] / image[0]), shown[1] + int((y + 0.5) * shown[3] / image[1])


def pointer_view(s, args, window):
    """The image a tool's x,y were read from: the screenshot or zoom its token names, else the last screenshot."""
    view = s.token_view(args["expected_state_token"], window) if "expected_state_token" in args else None
    return view if view and view.get("image_size") else SCREENSHOTS.get(window["window_id"])


def position(args, window, xkey="x", ykey="y", view=None):
    return tuple(map(str, to_window(window, args[xkey], args[ykey], view)))


def keys(values):
    aliases = {"cmd": "Super_L", "command": "Super_L", "ctrl": "ctrl", "control": "ctrl", "alt": "alt", "option": "alt", "shift": "shift", "super": "Super_L"}
    if not values or any(not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9_+<>-]{1,64}", v) or v.startswith("-") for v in values):
        raise ValueError("Keys must be non-empty valid xdotool key names, not options.")
    return [aliases.get(v.lower(), v) for v in values]


def note_cursor(window, x, y):
    CURSOR.update(x=window["geometry"][0] + x, y=window["geometry"][1] + y, scope="window")
    if CURSOR["enabled"]:
        overlay_update()


def input_action(s, name, args):
    window = target(s, args)
    wid = hex(window["window_id"])
    foreground = args.get("delivery_mode", "background") == "foreground"
    view = pointer_view(s, args, window)
    commands = []
    modifiers = []
    if name in ("click", "double_click", "right_click"):
        x, y = position(args, window, view=view)
        modifiers = keys(args["modifier"]) if args.get("modifier") else []
        button = {"left": "1", "middle": "2", "right": "3"}["right" if name == "right_click" else args.get("button", "left")]
        count = 2 if name == "double_click" else args.get("count", 1)
        commands.append(["xdotool", "mousemove", "--window", wid, x, y])
        commands.append(["xdotool", "click", *([] if foreground else ["--window", wid]), "--repeat", str(count), "--delay", "100", button])
    elif name == "drag":
        start = position(args, window, "from_x", "from_y", view)
        end = position(args, window, "to_x", "to_y", view)
        destination = [] if foreground else ["--window", wid]
        commands = [["xdotool", "mousemove", "--window", wid, *start],
                    ["xdotool", "mousedown", *destination, "1"],
                    ["xdotool", "mousemove", "--window", wid, *end],
                    ["xdotool", "mouseup", *destination, "1"]]
    elif name == "type_text":
        if not args["text"]:
            raise ValueError("text must be non-empty.")
        commands = [["xdotool", "type", *([] if foreground else ["--window", wid]), "--clearmodifiers", "--", args["text"]]]
    else:
        chord = keys(args["keys"] if name == "hotkey" else [*args.get("modifiers", []), args["key"]])
        commands = [["xdotool", "key", *([] if foreground else ["--window", wid]), "+".join(chord)]]
    previous = active_window(s) if foreground else front_or_none(s)
    held = []
    activated = False
    dragging = False
    try:
        human_guard(s, args)
        if foreground:
            s.run_cli("wmctrl", "-ia", wid)
            activated = True
            if active_window(s) != window["window_id"]:
                try:
                    s.run_cli("xdotool", "windowactivate", wid)
                except Exception:
                    pass
                for _ in range(10):
                    if active_window(s) == window["window_id"]:
                        break
                    time.sleep(0.1)
                else:
                    raise s.Unsupported("foreground activation failed: target window did not become active. " + FOCUS_HINT)
        for modifier in modifiers:
            inject(s, "xdotool", "keydown", *([] if foreground else ["--window", wid]), modifier)
            held.append(modifier)
        for command in commands:
            human_guard(s, args)
            if command[1] == "mousemove":
                note_cursor(window, int(command[-2]), int(command[-1]))
            inject(s, *command)
            if command[1] == "mousedown":
                dragging = True
            if command[1] == "mouseup":
                dragging = False
    finally:
        try:
            if dragging:
                inject(s, "xdotool", "mouseup", *([] if foreground else ["--window", wid]), "1")
            for modifier in reversed(held):
                inject(s, "xdotool", "keyup", *([] if foreground else ["--window", wid]), modifier)
        finally:
            if activated:
                hand_front_back(s, window, previous)
    result = {"ok": True, "window_id": window["window_id"], "delivery_mode": "foreground" if foreground else "background"}
    # Background input must leave the user's window in front. Pressing a control makes some apps bring
    # themselves forward; when the target did that and the user did not go there, hand the front back.
    if not foreground and hand_front_back(s, window, previous):
        result.update(took_focus=True, focus_returned=front_or_none(s) == previous)
    return result


def clipboard(s, name, args):
    require_x11(s)
    xclip = shutil.which("xclip")
    xsel = shutil.which("xsel")
    if not xclip and not xsel:
        raise s.Unsupported("Clipboard requires xclip or xsel.")
    if name == "clipboard_read":
        # Clipboard text is often private; read it only when asked.
        if args.get("include_text") is not True:
            return {"text": None}
        data = s.run_cli_bytes("xclip", "-selection", "clipboard", "-o") if xclip else s.run_cli_bytes("xsel", "--clipboard", "--output")
        return {"text": data.decode("utf-8", errors="replace")}
    selected = [key for key in ("text", "image_path", "file_path") if key in args]
    if len(selected) != 1:
        raise ValueError("Provide exactly one text, image_path, or file_path.")
    kind = selected[0]
    mime = "text/plain;charset=utf-8"
    if kind == "text":
        data = args[kind].encode()
    else:
        if not os.path.isabs(args[kind]):
            raise ValueError("Clipboard paths must be absolute.")
        path = Path(args[kind]).resolve(strict=True)
        # A symlink anywhere in the path could point the clipboard at a file the caller did not name.
        if str(path) != os.path.normpath(args[kind]):
            raise ValueError("Clipboard paths must not pass through symlinks.")
        if not path.is_file():
            raise ValueError("Clipboard path must be a file.")
        if kind == "image_path":
            data = path.read_bytes()
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("image_path must be a PNG file.")
            mime = "image/png"
        else:
            data = (path.as_uri() + "\r\n").encode()
            mime = "text/uri-list"
    human_guard(s, args)
    if xclip:
        # xclip forks to serve the selection; do not wait for its inherited pipes.
        process = subprocess.Popen([xclip, "-selection", "clipboard", "-t", mime, "-i"], stdin=subprocess.PIPE,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            process.communicate(data, timeout=4)
        except subprocess.TimeoutExpired:
            process.kill(); process.communicate()
            raise s.Unsupported("Clipboard owner failed to detach.")
        if process.returncode:
            raise s.Unsupported("xclip could not own clipboard selection.")
    elif kind == "text":
        s.run_cli_bytes("xsel", "--clipboard", "--input", input_data=data)
    else:
        raise s.Unsupported("PNG and text/uri-list clipboard targets require xclip; xsel supports text only.")
    return {"ok": True, "mime_type": mime}


def jev_window_labels(s, window):
    try:
        gi = importlib.import_module("gi")
        gi.require_version("Atspi", "2.0")
        atspi = importlib.import_module("gi.repository.Atspi")
        desktop = atspi.get_desktop(0)
        apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
        apps = [app for app in apps if app.get_process_id() == window["pid"]]
        if len(apps) != 1:
            return []
        app = apps[0]
        frames = [app.get_child_at_index(i) for i in range(app.get_child_count())]
        frames = [frame for frame in frames if frame.get_name() == window["title"]]
        if len(frames) != 1:
            return []
        labels, pending, visited = [], [(frames[0], 0)], 0
        while pending and visited < 500:
            node, depth = pending.pop()
            visited += 1
            role = s.scrub_jev_text(node.get_role_name())
            label = node.get_name()
            if label and not s.JEV_CREDENTIAL_RE.search(label) and not re.search(r"(?i)password|passcode|secret|credential|entry|text", role):
                labels.append({"role": role, "label": s.scrub_jev_text(label)})
            if depth < 12:
                pending.extend((node.get_child_at_index(i), depth + 1)
                               for i in range(min(node.get_child_count(), 500 - visited)))
        return labels
    except Exception:
        return []


def element_check(s, window, key, spec):
    """mac-use's element checks over a fresh AT-SPI read: True, False, or None when the read cannot tell."""
    if not spec.get("element_id") and not (spec.get("role") and spec.get("label")):
        raise ValueError(f"expect.{key} needs element_id, or role and label.")
    try:
        _token, nodes = s.atspi_tree.snapshot(s, window)
    except (s.Unsupported, ValueError):
        return None
    complete = len(nodes) < s.atspi_tree.MAX_NODES

    def matches(item):
        if spec.get("element_id"):
            return item["id"] == spec["element_id"]
        return item["role"] == spec["role"] and spec["label"] in (item["name"], item["description"])
    found = [item for item in nodes if matches(item)]
    if key == "element_exists":
        return True if found else (False if complete else None)
    if key == "focused_element":
        focused = [item for item in nodes if "focused" in item["states"]]
        return matches(focused[0]) if len(focused) == 1 else None
    if len(found) == 1 and found[0]["value"] is not None:
        return found[0]["value"] == spec["equals"]
    return False if not found and complete else None


def write_value(s, atspi, node, value):
    """Write text or a number through AT-SPI and confirm it by readback; an unconfirmed write is never retried."""
    if isinstance(value, str):
        editable = node.get_editable_text_iface()
        if editable is None or not editable.set_text_contents(value):
            raise s.Unsupported("AT-SPI target does not support editable text.")
        # Atspi.Text.get_text, not the interface object's get_text: that name resolves to the deprecated
        # one-argument Accessible.get_text, which failed every readback after a successful write.
        for _ in range(15):
            if node.get_text_iface() is not None and atspi.Text.get_text(node, 0, -1) == value:
                return
            time.sleep(0.01)
        raise s.Unsupported("AT-SPI text write accepted but unverified; no retry was sent.")
    number = node.get_value_iface()
    if number is None or not number.set_current_value(value):
        raise s.Unsupported("AT-SPI target does not support numeric values.")
    for _ in range(15):
        if number.get_current_value() == value:
            return
        time.sleep(0.01)
    raise s.Unsupported("AT-SPI numeric write accepted but unverified; no retry was sent.")


def atspi_action(s, name, args):
    try:
        gi = importlib.import_module("gi")
        gi.require_version("Atspi", "2.0")
        atspi = importlib.import_module("gi.repository.Atspi")
    except (ImportError, ValueError) as exc:
        raise s.Unsupported("Unsupported: invoke_menu/set_value require python gi Atspi (AT-SPI 2.0).") from exc
    if name == "set_value" and args.get("element_id") is not None:
        if args.get("role") or args.get("label"):
            raise ValueError("set_value takes element_id or role/label, not both.")
        window = s.atspi_tree.exact_window(s, {"target_pid": args.get("target_pid", args.get("pid")),
                                               "target_window_id": args.get("target_window_id", args.get("window_id"))})
        node = s.atspi_tree.resolve(s, window, args["element_id"], args.get("expected_state_token"))
        if not node.get_state_set().contains(atspi.StateType.ENABLED):
            raise s.Unsupported("AT-SPI value target is disabled.")
        human_guard(s, args)
        write_value(s, atspi, node, args["value"])
        return {"ok": True, "element_id": args["element_id"]}
    window = target(s, args)
    desktop = atspi.get_desktop(0)
    applications = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    applications = [app for app in applications if app.get_process_id() == window["pid"]]
    if len(applications) != 1:
        raise s.Unsupported("AT-SPI application is missing or ambiguous.")
    def children(node):
        return [node.get_child_at_index(i) for i in range(node.get_child_count())]
    def descendants(node, depth=0):
        if depth > 40:
            raise s.Unsupported("AT-SPI traversal depth exceeded.")
        result = [node]
        for child in children(node):
            result.extend(descendants(child, depth + 1))
            if len(result) > 10000:
                raise s.Unsupported("AT-SPI element limit exceeded.")
        return result
    roots = [node for node in children(applications[0]) if node.get_name() == window["title"]]
    if len(roots) != 1:
        raise s.Unsupported("AT-SPI target window is missing or ambiguous.")
    root = roots[0]
    if name == "invoke_menu":
        if not args["path"] or any(not part for part in args["path"]):
            raise ValueError("path must contain non-empty menu names.")
        parent = root
        for index, label in enumerate(args["path"]):
            candidates = descendants(parent) if index == 0 else children(parent)
            matches = [node for node in candidates if node.get_name() == label and "menu" in node.get_role_name().lower()]
            if len(matches) != 1:
                raise s.Unsupported("AT-SPI menu is missing or ambiguous.")
            parent = matches[0]
            if not parent.get_state_set().contains(atspi.StateType.ENABLED):
                raise s.Unsupported("AT-SPI menu is disabled.")
            human_guard(s, args)
            action = parent.get_action_iface()
            if action is None or action.get_n_actions() != 1 or not action.do_action(0):
                raise s.Unsupported("AT-SPI menu action unavailable or ambiguous.")
    else:
        if not args.get("label") and not args.get("role"):
            raise ValueError("set_value requires role or label.")
        matches = [node for node in descendants(root) if (not args.get("label") or node.get_name() == args["label"]) and (not args.get("role") or node.get_role_name() == args["role"])]
        if len(matches) != 1 or not matches[0].get_state_set().contains(atspi.StateType.ENABLED):
            raise s.Unsupported("AT-SPI value target is missing, ambiguous, or disabled.")
        node = matches[0]
        human_guard(s, args)
        write_value(s, atspi, node, args["value"])
    return {"ok": True}


def overlay_stop():
    global OVERLAY, OVERLAY_DIR
    if OVERLAY is not None:
        if OVERLAY.poll() is None:
            OVERLAY.terminate()
            try:
                OVERLAY.wait(timeout=2)
            except subprocess.TimeoutExpired:
                OVERLAY.kill(); OVERLAY.wait(timeout=2)
        OVERLAY = None
    if OVERLAY_DIR is not None:
        OVERLAY_DIR.cleanup(); OVERLAY_DIR = None
    CURSOR["overlay_available"] = False


def overlay_update():
    global OVERLAY, OVERLAY_DIR
    if not CURSOR["enabled"]:
        overlay_stop()
        return dict(CURSOR)
    if OVERLAY is not None and OVERLAY.poll() is not None:
        overlay_stop()
    if OVERLAY is None:
        try:
            importlib.import_module("tkinter")
            if not os.environ.get("DISPLAY") or os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland":
                raise RuntimeError("X11 session unavailable")
            OVERLAY_DIR = tempfile.TemporaryDirectory(prefix="linux-use-cursor-")
            state_path = Path(OVERLAY_DIR.name) / "cursor.json"
            state_path.write_text(json.dumps(CURSOR))
            OVERLAY = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--overlay", str(state_path)],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True)
            CURSOR["overlay_available"] = OVERLAY.poll() is None
        except (ImportError, OSError, RuntimeError):
            overlay_stop()
    if OVERLAY_DIR is not None:
        path = Path(OVERLAY_DIR.name) / "cursor.json"
        pending = path.with_suffix(".tmp")
        pending.write_text(json.dumps(CURSOR)); pending.replace(path)
        CURSOR["overlay_available"] = (Path(OVERLAY_DIR.name) / "ready").exists() and OVERLAY.poll() is None
    result = dict(CURSOR)
    if not result["overlay_available"]:
        result["status"] = "overlay_unavailable"
    return result


def overlay_main(path):
    import tkinter as tk
    root = tk.Tk()
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.configure(takefocus=False, background="#ff3355")
    scale = 1.2
    points = [(1, 1), (1, 17.5), (5, 13.7), (7.8, 20.3),
              (10.8, 19), (8.1, 12.6), (13.3, 12.6)]
    points = [(x * scale, y * scale) for x, y in points]
    width, height = 24, 30
    canvas = tk.Canvas(root, width=width, height=height, highlightthickness=0, background="#ff3355")
    canvas.pack()
    arrow = canvas.create_polygon(*[coordinate for point in points for coordinate in point],
                                  fill="#ff3355", outline="white", width=2)
    root.update_idletasks()
    # Empty X Shape input region lets pointer events pass through the overlay.
    x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
    shape = ctypes.CDLL(ctypes.util.find_library("Xext"))
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    display = x11.XOpenDisplay(None)
    if not display:
        return
    shape.XShapeCombineRectangles.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                                             ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                                             ctypes.c_int, ctypes.c_int]
    class XRectangle(ctypes.Structure):
        _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short),
                    ("width", ctypes.c_ushort), ("height", ctypes.c_ushort)]

    def arrow_spans(vertices, box_width, box_height):
        spans = []
        for row in range(box_height):
            intersections = []
            scan_y = row + 0.5
            for index, (x1, y1) in enumerate(vertices):
                x2, y2 = vertices[(index + 1) % len(vertices)]
                if (y1 <= scan_y < y2) or (y2 <= scan_y < y1):
                    intersections.append(x1 + (scan_y - y1) * (x2 - x1) / (y2 - y1))
            if intersections:
                left = max(0, int(min(intersections)) - 1)
                right = min(box_width, int(max(intersections) + 1.999))
                if right > left:
                    spans.append((left, row, right - left, 1))
        return spans

    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    rectangles = (XRectangle * len(arrow_spans(points, width, height)))(
        *(XRectangle(*span) for span in arrow_spans(points, width, height)))
    shape.XShapeCombineRectangles(display, root.winfo_id(), 0, 0, 0, rectangles,
                                  len(rectangles), 0, 0)
    shape.XShapeCombineRectangles(display, root.winfo_id(), 2, 0, 0, None, 0, 0, 0)
    x11.XFlush(display)
    Path(path).with_name("ready").touch()
    previous = [0, 0]
    destination = [None, None]
    origin = [0, 0]
    started = [time.monotonic()]
    def tick():
        if not Path(path).exists():
            root.destroy(); return
        try:
            state = json.loads(Path(path).read_text())
            x, y = state["x"], state["y"]
            if state.get("motion") == "smooth" and state.get("reduced_motion") != "on":
                if destination != [x, y]:
                    destination[:] = [x, y]
                    origin[:] = previous
                    started[0] = time.monotonic()
                duration = state.get("motion_options", {}).get("glide_duration_ms", 300) or 300
                progress = min(1, (time.monotonic() - started[0]) * 1000 / duration)
                x, y = [round(old + (new - old) * progress) for old, new in zip(origin, (x, y))]
            previous[:] = [x, y]
            root.geometry(f"{width}x{height}+{max(0, x - int(scale))}+{max(0, y - int(scale))}")
            color = {"default": "#ff3355", "dark": "#222222", "light": "#eeeeee"}.get(state["theme"], "#ff3355")
            outline = "#222222" if state["theme"] == "light" else "white"
            canvas.configure(background=color)
            canvas.itemconfigure(arrow, fill=color, outline=outline)
        except (OSError, ValueError, KeyError):
            pass
        root.after(30, tick)
    tick()
    try:
        root.mainloop()
    finally:
        x11.XCloseDisplay(display)


def recording_stop(s):
    global VIDEO
    if VIDEO is not None:
        if VIDEO.poll() is None:
            VIDEO.terminate()
            try:
                VIDEO.wait(timeout=5)
            except subprocess.TimeoutExpired:
                VIDEO.kill(); VIDEO.wait(timeout=2)
        RECORDING["video_exit_code"] = VIDEO.returncode
        VIDEO = None
    RECORDING["active"] = False
    return dict(RECORDING)


def dispatch(s, name, args):
    global VIDEO
    validate(args, schema(name))
    if args.get("session") and name != "start_session" and args["session"] != SESSION["session"]:
        raise s.Unsupported("Unknown session; call start_session with this identity first.")
    if name == "health_report":
        return {**health(s), "chrome_extension": s.extension_status()}
    if name == "check_permissions":
        return health(s)
    if name == "get_config":
        return get_config(s)
    if name == "set_config":
        config = {**get_config(s), **{key: value for key, value in args.items() if key != "session"}}
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temp = tempfile.mkstemp(dir=CONFIG_PATH.parent, prefix="config-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(config, stream, sort_keys=True)
            os.replace(temp, CONFIG_PATH)
        finally:
            Path(temp).unlink(missing_ok=True)
        return config
    if name == "list_apps":
        windows = s.list_windows()
        active = active_window(s)
        running = []
        for pid in sorted({w["pid"] for w in windows}):
            owned = [w for w in windows if w["pid"] == pid]
            try:
                app_name = (Path("/proc") / str(pid) / "comm").read_text().strip()
            except OSError:
                app_name = owned[0]["title"]
            running.append({"pid": pid, "name": app_name, "running": True,
                            "active": any(w["window_id"] == active for w in owned), "windows": owned})
        installed = [{**entry, "running": any(app["name"].casefold() == entry["name"].casefold() for app in running)} for entry in desktop_entries()]
        return {"running": running, "installed": installed}
    if name == "launch_app":
        require_x11(s)
        try:
            command = application_command(args, desktop_entries())
            before = {w["window_id"] for w in s.list_windows()}
            previous = active_window(s) if before else None
            human_guard(s, args)
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True)
            windows = []
            for _ in range(5):
                windows = [w for w in s.list_windows() if w["pid"] == process.pid and w["window_id"] not in before]
                if windows or process.poll() is not None:
                    break
                time.sleep(0.1)
            if previous is not None and windows and active_window(s) in {w["window_id"] for w in windows}:
                human_guard(s, {"pid": process.pid})
                s.run_cli("wmctrl", "-ia", hex(previous))
            exit_code = process.poll()
            return {"ok": exit_code in (None, 0), "pid": process.pid, "windows": windows,
                    "exit_code": exit_code, "note": "Detached launch; window creation may be asynchronous or owned by another process."}
        except (OSError, ValueError) as exc:
            return {"ok": False, "error": str(exc), "windows": []}
    if name == "kill_app":
        pid = args["pid"]
        if pid <= 1 or pid == os.getpid():
            raise ValueError("pid must identify another process greater than 1.")
        require_x11(s)
        human_guard(s, args)
        try:
            os.kill(pid, signal.SIGTERM)
            for _ in range(10):
                time.sleep(0.1)
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return {"ok": True, "pid": pid, "signal": "SIGTERM"}
            human_guard(s, args)
            os.kill(pid, signal.SIGKILL)
            return {"ok": True, "pid": pid, "signal": "SIGKILL", "termination_verified": False}
        except ProcessLookupError:
            return {"ok": True, "pid": pid, "already_exited": True}
    if name == "bring_to_front":
        window = target(s, args)
        human_guard(s, args)
        s.run_cli("wmctrl", "-ia", hex(window["window_id"]))
        return {"ok": True, "window_id": window["window_id"], "active": active_window(s) == window["window_id"]}
    if name == "get_accessibility_tree":
        windows = s.list_windows()
        stacking = s.run_cli("xprop", "-root", "_NET_CLIENT_LIST_STACKING")
        order = [int(value, 16) for value in re.findall(r"0x[0-9a-fA-F]+", stacking)]
        active = active_window(s)
        return {"windows": [{**w, "stacking_order": order.index(w["window_id"]) if w["window_id"] in order else None,
                             "active": w["window_id"] == active} for w in windows],
                "active_window_id": active, "stacking_order": "bottom_to_top", "backend": "X11 window summary"}
    if name == "get_desktop_state":
        image = root_png(s)
        return {"content": [{"type": "image", "data": s.base64.b64encode(image).decode("ascii"), "mimeType": "image/png"},
                            {"type": "text", "text": json.dumps({"scope": "desktop", "max_image_dimension": get_config(s)["max_image_dimension"]})}]}
    if name == "get_screen_size":
        require_x11(s)
        if shutil.which("xdpyinfo"):
            output = s.run_cli("xdpyinfo")
            match = re.search(r"dimensions:\s+(\d+)x(\d+)", output)
        else:
            output = s.run_cli("xrandr", "--current")
            match = re.search(r"current\s+(\d+)\s+x\s+(\d+)", output)
        if not match:
            raise s.Unsupported("Could not parse X11 screen dimensions.")
        return {"width": int(match[1]), "height": int(match[2]), "scale_factor": 1}
    if name == "get_cursor_position":
        require_x11(s)
        values = dict(re.findall(r"^(X|Y|WINDOW)=(\d+)$", s.run_cli("xdotool", "getmouselocation", "--shell"), re.M))
        if not all(key in values for key in ("X", "Y", "WINDOW")):
            raise s.Unsupported("Could not parse X11 cursor position.")
        return {"x": int(values["X"]), "y": int(values["Y"]), "window_id": int(values["WINDOW"])}
    if name == "move_cursor":
        scope = args.get("scope", "window")
        x, y = args["x"], args["y"]
        if scope == "window":
            window = target(s, args)
            x, y = to_window(window, x, y, pointer_view(s, args, window))
            x += window["geometry"][0]; y += window["geometry"][1]
        else:
            require_x11(s)
            size = dispatch(s, "get_screen_size", {})
            if not (0 <= x < size["width"] and 0 <= y < size["height"]):
                raise ValueError("Coordinates are outside the desktop.")
            human_guard(s, args, all_windows=True)
            inject(s, "xdotool", "mousemove", str(x), str(y))
        CURSOR.update(x=x, y=y, scope=scope)
        return {**overlay_update(), "physical_pointer_moved": scope == "desktop"}
    if name in ("click", "double_click", "right_click", "drag", "type_text", "press_key", "hotkey"):
        return input_action(s, name, args)
    if name == "set_window_frame":
        window = target(s, args)
        frame = [args[key] for key in ("x", "y", "w", "h")]
        human_guard(s, args)
        s.run_cli("wmctrl", "-ir", hex(window["window_id"]), "-e", "0," + ",".join(map(str, frame)))
        after = target(s, {"window_id": window["window_id"], "pid": window["pid"]})
        return {"ok": after["geometry"] == frame, "requested": frame, "actual": after["geometry"], "state_token": s.state_token(after)}
    if name == "verify_state":
        if not args["expect"]:
            raise ValueError("expect must contain at least one condition.")
        if "criteria" in args["expect"] and args.get("browser"):
            if set(args["expect"]) != {"criteria"}:
                raise ValueError("Browser verification supports only criteria.")
            return s.verify_criteria(args["expect"]["criteria"], browser=True)
        require_x11(s)
        wid = args.get("window_id", args.get("target_window_id"))
        pid = args.get("pid", args.get("target_pid"))
        if wid is None and pid is None:
            raise ValueError("verify_state requires window_id or pid.")
        matches = [w for w in s.list_windows() if (wid is None or w["window_id"] == wid) and (pid is None or w["pid"] == pid)]
        checks = {}
        for key, value in args["expect"].items():
            if key == "window_exists":
                checks[key] = bool(matches) == value
            elif len(matches) != 1:
                checks[key] = None if matches else False
            elif key == "title_contains":
                checks[key] = value in matches[0]["title"]
            elif key == "active":
                checks[key] = (active_window(s) == matches[0]["window_id"]) == value
            elif key in ("element_exists", "element_value", "focused_element"):
                checks[key] = element_check(s, matches[0], key, value)
        verification = None
        if "criteria" in args["expect"]:
            verification = s.verify_criteria(args["expect"]["criteria"], windows=matches)
            checks["criteria"] = {"pass": True, "fail": False, "unknown": None}[verification["status"]]
        return {**(verification or {}), "status": "fail" if False in checks.values() else "unknown" if None in checks.values() else "pass", "checks": checks}
    if name in ("clipboard_read", "clipboard_write"):
        return clipboard(s, name, args)
    if name in ("invoke_menu", "set_value"):
        try:
            return atspi_action(s, name, args)
        except (s.Unsupported, ValueError):
            raise
        except Exception as exc:
            raise s.Unsupported(f"AT-SPI provider failed safely: {exc}") from exc
    if name == "start_session":
        if not args["session"].strip():
            raise ValueError("session must be non-empty.")
        if SESSION["session"] is not None:
            raise s.Unsupported("End the existing session before starting another.")
        SESSION.update(session=args["session"], capture_scope=args.get("capture_scope", "desktop"))
        return dict(SESSION)
    if name == "end_session":
        recording_stop(s)
        overlay_stop()
        CURSOR["enabled"] = True
        SESSION.update(session=None, capture_scope="desktop")
        return dict(SESSION)
    if name == "get_session_state":
        return {**SESSION, "cursor": dict(CURSOR), "recording": dict(RECORDING)}
    if name.startswith("set_agent_cursor_"):
        field = name.removeprefix("set_agent_cursor_")
        if field == "theme":
            theme = args.get("theme_id", args.get("theme"))
            if theme not in ("default", "dark", "light"):
                raise ValueError("theme_id must be default, dark, or light.")
            CURSOR.update(theme=theme, theme_id=theme, reduced_motion=args.get("reduced_motion", "auto"))
        elif field == "motion":
            if not any(key in args for key in ("motion", "style", "timing", "glide_duration_ms")):
                raise ValueError("Provide motion, style, timing or glide_duration_ms.")
            CURSOR["motion"] = args.get("motion", "smooth")
            CURSOR["motion_options"] = {key: value for key, value in args.items() if key != "session"}
        else:
            CURSOR[field] = args[field]
        return overlay_update()
    if name == "get_agent_cursor_state":
        available = OVERLAY is not None and OVERLAY.poll() is None and OVERLAY_DIR is not None and (Path(OVERLAY_DIR.name) / "ready").exists()
        CURSOR["overlay_available"] = available
        return {**CURSOR, "status": "available" if available else "overlay_unavailable"}
    if name == "start_recording":
        if RECORDING["active"]:
            raise s.Unsupported("Recording already active.")
        directory = Path(args["output_dir"]).expanduser().resolve()
        directory.mkdir(parents=True, exist_ok=True)
        if any(directory.glob("turn-*")) or (directory / "recording.mp4").exists():
            raise ValueError("Recording output directory already contains trajectory evidence.")
        RECORDING.clear()
        RECORDING.update(active=True, output_dir=str(directory), turn=0, video=False, session=SESSION["session"])
        if args.get("record_video"):
            ffmpeg = shutil.which("ffmpeg")
            if ffmpeg and os.environ.get("DISPLAY"):
                try:
                    require_x11(s)
                    VIDEO = subprocess.Popen([ffmpeg, "-nostdin", "-n", "-f", "x11grab", "-i", os.environ["DISPLAY"], str(directory / "recording.mp4")],
                                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                    RECORDING["video"] = VIDEO.poll() is None
                    if not RECORDING["video"]:
                        RECORDING["video_status"] = "ffmpeg exited before recording started"
                except (OSError, s.Unsupported) as exc:
                    RECORDING["video_status"] = str(exc)
            else:
                RECORDING["video_status"] = "unsupported: ffmpeg or X11 DISPLAY unavailable"
        return dict(RECORDING)
    if name == "stop_recording":
        return recording_stop(s)
    if name == "get_recording_state":
        result = dict(RECORDING)
        if VIDEO is not None:
            result["video_running"] = VIDEO.poll() is None
        return result
    if name == "replay_trajectory":
        directory = Path(args["dir"]).expanduser().resolve(strict=True)
        if not directory.is_dir():
            raise ValueError("dir must be a trajectory directory.")
        actions = []
        for turn in sorted(directory.glob("turn-*")):
            if not re.fullmatch(r"turn-\d{5,}", turn.name):
                continue
            if turn.is_symlink() or (turn / "action.json").is_symlink():
                raise ValueError("Trajectory action paths must not be symlinks.")
            action = json.loads((turn / "action.json").read_text())
            if not isinstance(action, dict) or action.get("name") not in MUTATIONS | LEGACY_MUTATIONS or action["name"] in CONTROL | {"end_session"}:
                raise ValueError("Trajectory contains an invalid or recursive action.")
            if not isinstance(action.get("arguments"), dict):
                raise ValueError("Trajectory action arguments must be an object.")
            actions.append(action)
        if not actions:
            raise ValueError("Trajectory contains no actions.")
        results = []
        for index, action in enumerate(actions):
            if index:
                time.sleep(args.get("delay_ms", 500) / 1000)
            # Escalation was a decision about that moment; a replay yields to the user again.
            arguments = {key: value for key, value in action["arguments"].items() if key != "allow_while_user_active"}
            try:
                result = s.call_tool(action["name"], arguments)
            except (s.Unsupported, ValueError) as exc:
                result = s.text_result(str(exc), error=True)
            results.append(result)
            if result.get("isError") and args.get("stop_on_error", True):
                return {"ok": False, "results": results, "stopped_on_error": True}
        return {"ok": not any(result.get("isError") for result in results), "results": results}
    if name == "run_steps":
        # Acting and looking used to be separate round trips with the window free to change between them.
        steps, results, failed = args["steps"], [], None
        for index, step in enumerate(steps):
            if step["tool"] not in s.BASE_TOOLS or step["tool"] in ("run_steps", "replay_trajectory"):
                results.append({"tool": step["tool"], "ok": False, "text": "not a tool that can run as a step"})
                failed = index
                break
            try:
                result = s.call_tool(step["tool"], step.get("arguments", {}))
            except (s.Unsupported, ValueError) as exc:
                result = s.text_result(str(exc), error=True)
            text = "\n".join(item["text"] for item in result["content"] if item.get("type") == "text")
            results.append({"tool": step["tool"], "ok": not result.get("isError"), "text": text[:1200]})
            if result.get("isError"):
                failed = index
                break
        output = {"completed": len(steps) if failed is None else failed, "total": len(steps), "results": results}
        if failed is not None:
            output["failed_step"] = failed
        observation = []
        if "observe" in args:
            try:
                observed = s.call_tool("screenshot", args["observe"])
            except (s.Unsupported, ValueError) as exc:
                observed = s.text_result(str(exc), error=True)
            if observed.get("isError"):
                output["observation_error"] = observed["content"][0]["text"]
            else:
                observation = observed["content"]
        return {"content": [{"type": "text", "text": json.dumps(output, sort_keys=True)}, *observation], "isError": failed is not None}
    raise ValueError(f"unknown tool: {name}")


def recording_png(s, args):
    if SESSION["capture_scope"] == "window":
        if not any(key in args for key in ("window_id", "pid", "target_window_id", "target_pid")):
            return None
        try:
            window = target(s, {key: value for key, value in args.items() if key != "expected_state_token"})
        except s.Unsupported:
            return None
        return s.screenshot_png(window["window_id"])
    return root_png(s)


def redact_action(value):
    if isinstance(value, dict):
        return {key: "[REDACTED]" if key in {"text", "value", "secret_inputs", "prompt_text", "javascript"} else redact_action(item)
                for key, item in value.items()}
    if isinstance(value, list):
        return [redact_action(item) for item in value]
    return value


def call(s, original, name, args):
    global DISPATCH_DEPTH
    if not isinstance(args, dict):
        raise ValueError("arguments must be an object.")
    if name in PROPERTIES:
        validate(args, schema(name))
    mutation = name in MUTATIONS | LEGACY_MUTATIONS
    record = RECORDING["active"] and mutation and name not in CONTROL and DISPATCH_DEPTH == 0
    turn = None
    evidence = {"name": name, "session": SESSION["session"], "started_at": time.time(), "ok": False}
    if record:
        RECORDING["turn"] += 1
        turn = Path(RECORDING["output_dir"]) / f"turn-{RECORDING['turn']:05d}"
        turn.mkdir()
        action = {"name": name, "arguments": args}
        if name == "native_visual_execute":
            proposal = s.NATIVE_VISUAL_PROPOSALS.get(args.get("proposal_id"))
            if proposal is not None:
                action = {"name": proposal["action"], "arguments": proposal["arguments"]}
        (turn / "action.json").write_text(json.dumps(redact_action(action), sort_keys=True))
        try:
            capture = recording_png(s, args)
            if capture is None:
                evidence["skipped"] = "window_scope_without_target"
            else:
                (turn / "before.png").write_bytes(capture)
        except Exception as exc:
            evidence["error"] = str(exc)
            (turn / "evidence.json").write_text(json.dumps(evidence, sort_keys=True))
            raise
    depth_increment = int(name not in ("replay_trajectory", "run_steps"))  # their steps are recorded
    DISPATCH_DEPTH += depth_increment
    try:
        # Browser activity checks remain owned by the Chrome extension.
        if mutation and not name.startswith("browser_") and name not in {"native_visual_execute", "launch_app", "run_steps"}:
            human_guard(s, args, all_windows=name == "clipboard_write")
        value = dispatch(s, name, args) if name in PROPERTIES else original(name, args)
        result = value if isinstance(value, dict) and "content" in value else s.text_result(value, error=isinstance(value, dict) and value.get("ok") is False)
        evidence["ok"] = not result.get("isError", False)
        evidence["result"] = result
        return result
    except (OSError, subprocess.SubprocessError) as exc:
        evidence["error"] = str(exc)
        raise s.Unsupported(f"Native operation failed safely: {exc}") from exc
    except Exception as exc:
        evidence["error"] = str(exc)
        raise
    finally:
        DISPATCH_DEPTH -= depth_increment
        if turn is not None:
            try:
                capture = recording_png(s, args)
                if capture is None:
                    evidence["skipped"] = "window_scope_without_target"
                else:
                    (turn / "after.png").write_bytes(capture)
            except Exception as exc:
                evidence["after_capture_error"] = str(exc)
                evidence["ok"] = False
                raise s.Unsupported(f"Action attempted but recording after capture failed: {exc}") from exc
            finally:
                evidence["finished_at"] = time.time()
                (turn / "evidence.json").write_text(json.dumps(evidence, sort_keys=True))


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] == "--overlay":
    overlay_main(sys.argv[2])
