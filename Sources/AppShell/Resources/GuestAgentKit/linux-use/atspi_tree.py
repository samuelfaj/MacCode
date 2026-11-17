"""AT-SPI element tree for one exact X11 window.

Each read hands out `ax_<n>` ids and a state token. An id keeps meaning the element it was read for while
the rest of the window changes: the element is looked up in the read that the token names, and its role,
name and description are checked again before it is used.
"""
import importlib
import re
import time
import uuid
from collections import OrderedDict

MAX_DEPTH = 32
MAX_NODES = 1000
DEFAULT_ROWS = 250
MAX_ROWS = 1000
READS_PER_WINDOW = 8
WINDOWS = 16
WRAPPERS = {"filler", "panel", "section", "unknown", "redundant object"}
PREFERRED_ACTIONS = ("click", "press", "activate", "toggle", "jump", "open")
SETTLE_FIRST_EVENT = 0.6
SETTLE_QUIET = 0.15
SETTLE_CAP = 2.0

# window_id -> OrderedDict(token -> {"pid": int, "nodes": {id: (accessible, identity)}})
STORE = OrderedDict()


def load(s):
    try:
        gi = importlib.import_module("gi")
        gi.require_version("Atspi", "2.0")
        return importlib.import_module("gi.repository.Atspi")
    except (ImportError, ValueError) as exc:
        raise s.Unsupported("Unsupported: AT-SPI element tools require python gi Atspi (AT-SPI 2.0).") from exc


def exact_window(s, args):
    pid, wid = args.get("target_pid"), args.get("target_window_id")
    if type(pid) is not int or type(wid) is not int or pid <= 0 or wid <= 0:
        raise ValueError("target_pid and target_window_id are required; no implicit active-window targeting is allowed.")
    matches = [window for window in s.list_windows() if window["pid"] == pid and window["window_id"] == wid]
    if len(matches) != 1:
        raise s.Unsupported("Target window identity is missing or ambiguous; no action was performed.")
    return matches[0]


def _children(node):
    try:
        return [node.get_child_at_index(index) for index in range(node.get_child_count())]
    except Exception:
        return []


def frame_for(s, atspi, window):
    """The AT-SPI frame of the exact window: by on-screen bounds, else by a unique title."""
    desktop = _safe(lambda: atspi.get_desktop(0))
    if desktop is None:
        raise s.Unsupported("The AT-SPI registry is unreachable; use screenshot and pixel tools.")
    apps = [app for app in _children(desktop) if _safe(lambda: app.get_process_id()) == window["pid"]]
    frames = [frame for app in apps for frame in _children(app)]
    if not frames:
        raise s.Unsupported("The window's application exposes no AT-SPI tree; use screenshot and pixel tools.")
    x, y, width, height = window["geometry"]

    def near(frame):
        component = _safe(lambda: frame.get_component_iface())
        extents = _safe(lambda: component.get_extents(atspi.CoordType.SCREEN)) if component else None
        # Window managers report the client area; frames may include decorations on some toolkits.
        return extents is not None and abs(extents.width - width) <= 16 and abs(extents.height - height) <= 48 \
            and abs(extents.x - x) <= 16 and abs(extents.y - y) <= 48
    by_bounds = [frame for frame in frames if near(frame)]
    if len(by_bounds) == 1:
        return by_bounds[0]
    by_title = [frame for frame in (by_bounds or frames) if _safe(lambda: frame.get_name()) == window["title"]]
    if len(by_title) == 1:
        return by_title[0]
    raise s.Unsupported("The window's AT-SPI frame is missing or ambiguous; use screenshot and pixel tools.")


def _safe(call, default=None):
    try:
        return call()
    except Exception:
        return default


def _states(atspi, node):
    state = _safe(lambda: node.get_state_set())
    if state is None:
        return []
    flags = [name for name in ("checked", "selected", "expanded", "focused") if state.contains(getattr(atspi.StateType, name.upper()))]
    if not (state.contains(atspi.StateType.ENABLED) or state.contains(atspi.StateType.SENSITIVE)):
        flags.append("disabled")
    return flags


def _value(atspi, node, role):
    if role == "password text":
        return None  # Never read a secure field.
    if _safe(lambda: node.get_text_iface()) is not None:
        count = _safe(lambda: atspi.Text.get_character_count(node), 0) or 0
        text = _safe(lambda: atspi.Text.get_text(node, 0, min(count, 200)))
        if text:
            return text
    if _safe(lambda: node.get_value_iface()) is not None:
        number = _safe(lambda: atspi.Value.get_current_value(node))
        if number is not None:
            return f"{number:g}"
    return None


def _actions(atspi, node):
    if _safe(lambda: node.get_action_iface()) is None:
        return []
    count = _safe(lambda: atspi.Action.get_n_actions(node), 0) or 0
    return [name for name in (_safe(lambda index=index: atspi.Action.get_action_name(node, index)) for index in range(count)) if name]


def identity(node):
    return (_safe(lambda: node.get_role_name()), _safe(lambda: node.get_name()), _safe(lambda: node.get_description()))


def walk(s, atspi, frame):
    """Depth-first nodes of the frame, capped like mac-use (depth 32, 1000 nodes)."""
    nodes, complete = [], True

    def visit(node, depth, parent):
        nonlocal complete
        if depth > MAX_DEPTH or len(nodes) >= MAX_NODES:
            complete = False
            return
        role = _safe(lambda: node.get_role_name()) or "unknown"
        item = {"id": f"ax_{len(nodes)}", "role": role, "name": _safe(lambda: node.get_name()) or "",
                "description": _safe(lambda: node.get_description()) or "", "value": _value(atspi, node, role),
                "states": _states(atspi, node), "actions": _actions(atspi, node), "depth": depth,
                "parent": parent, "accessible": node}
        nodes.append(item)
        for child in _children(node):
            visit(child, depth + 1, item["id"])
    visit(frame, 0, None)
    return nodes, complete


def remember(window, nodes):
    token = "ax-" + uuid.uuid4().hex[:16]
    reads = STORE.pop(window["window_id"], OrderedDict())
    reads[token] = {"pid": window["pid"], "nodes": {item["id"]: (item["accessible"], identity(item["accessible"])) for item in nodes}}
    while len(reads) > READS_PER_WINDOW:
        reads.popitem(last=False)
    STORE[window["window_id"]] = reads
    while len(STORE) > WINDOWS:
        STORE.popitem(last=False)
    return token


def _row(item, depth):
    text = f"{'  ' * depth}- [{item['id']}] {item['role']}"
    if item["name"]:
        text += f' "{item["name"]}"'
    if item["description"] and item["description"] != item["name"]:
        text += f" ({item['description']})"
    if item["value"] is not None and item["value"] != item["name"]:
        text += f' = "{item["value"]}"'
    if item["states"]:
        text += " {" + ", ".join(item["states"]) + "}"
    if item["actions"]:
        text += " [" + ",".join(item["actions"]) + "]"
    return text


def render_rows(nodes, query=None, max_elements=DEFAULT_ROWS):
    """One row per element; unnamed single-child wrappers are folded, and a query keeps matches with their ancestors."""
    by_id = {item["id"]: item for item in nodes}
    children = {}
    for item in nodes:
        children.setdefault(item["parent"], []).append(item["id"])
    keep = None
    if query:
        terms = [term.strip().lower() for term in query.split("|") if term.strip()]
        keep = set()
        for item in nodes:
            haystack = " ".join(str(item[key] or "") for key in ("role", "name", "description", "value")).lower()
            if any(term in haystack for term in terms):
                cursor = item["id"]
                while cursor is not None and cursor not in keep:
                    keep.add(cursor)
                    cursor = by_id[cursor]["parent"]
    rows, shown = [], 0

    def emit(item_id, depth):
        nonlocal shown
        item = by_id[item_id]
        kids = children.get(item_id, [])
        folded = (item["role"] in WRAPPERS and not item["name"] and not item["actions"] and len(kids) == 1)
        if (keep is None or item_id in keep) and not folded:
            shown += 1
            if len(rows) < max_elements:
                rows.append(_row(item, depth))
            depth += 1
        for kid in kids:
            emit(kid, depth)
    if nodes:
        emit(nodes[0]["id"], 0)
    if shown > len(rows):
        rows.append(f"... {shown - len(rows)} more rows; pass query or a larger max_elements (at most {MAX_ROWS})")
    return "\n".join(rows)


def render_json(nodes):
    built = {}
    root = None
    for item in nodes:
        node = {key: item[key] for key in ("id", "role", "name", "description", "value", "states", "actions")}
        node["children"] = []
        built[item["id"]] = node
        if item["parent"] is None:
            root = node
        else:
            built[item["parent"]]["children"].append(node)
    return root


def read(s, args):
    query, max_elements, fmt = args.get("query"), args.get("max_elements", DEFAULT_ROWS), args.get("format", "rows")
    if query is not None and (not isinstance(query, str) or not query.strip()):
        raise ValueError("query must be a non-empty string; separate alternatives with |.")
    if type(max_elements) is not int or not 1 <= max_elements <= MAX_ROWS:
        raise ValueError(f"max_elements must be an integer from 1 to {MAX_ROWS}.")
    if fmt not in ("rows", "json"):
        raise ValueError("format must be rows or json.")
    atspi = load(s)
    window = exact_window(s, args)
    nodes, complete = walk(s, atspi, frame_for(s, atspi, window))
    token = remember(window, nodes)
    result = {"state_token": token, "window": {key: window[key] for key in ("window_id", "pid", "title", "geometry")},
              "elements": len(nodes), "complete": complete,
              "ids": "Pass element_id with this state_token as expected_state_token to click_element or set_value."}
    result["ui_tree"] = render_json(nodes) if fmt == "json" else render_rows(nodes, query, max_elements)
    return result


def actionable(nodes):
    """Enabled, showing controls a person could press, as (node, label) — the candidates for a decision."""
    roles = {"button", "push button", "toggle button", "menu item", "check menu item", "radio menu item", "check box",
             "radio button", "combo box", "link", "page tab", "switch", "spin button"}
    found = []
    for item in nodes:
        if item["role"] in roles and "disabled" not in item["states"]:
            label = item["name"] or item["description"]
            if not label and item["role"] in ("toggle button", "switch", "check box"):
                label = _nearby_label(nodes, item)
            if label:
                found.append((item, label))
    return found


def _nearby_label(nodes, item):
    """GTK switches carry no name; the label beside them in the same row names them."""
    siblings = [other for other in nodes if other["parent"] == item["parent"] and other is not item]
    labels = [other["name"] for other in siblings if other["role"] == "label" and other["name"]]
    return labels[0] if len(labels) == 1 else ""


def has_secure_field(nodes):
    return any(item["role"] == "password text" for item in nodes)


def snapshot(s, window):
    """Read the exact window's tree and remember it; returns (token, nodes)."""
    atspi = load(s)
    nodes, _complete = walk(s, atspi, frame_for(s, atspi, window))
    return remember(window, nodes), nodes


def resolve(s, window, element_id, token):
    if not isinstance(element_id, str) or not re.fullmatch(r"ax_\d+", element_id):
        raise ValueError("element_id must look like ax_<n> from get_ui_tree.")
    reads = STORE.get(window["window_id"])
    if not reads:
        raise s.Unsupported("stale_state_token: read the window with get_ui_tree first, then pass its element ids.")
    if token is None:
        token = next(reversed(reads))
    read_entry = reads.get(token)
    if read_entry is None or read_entry["pid"] != window["pid"]:
        raise s.Unsupported("stale_state_token: that read is older than the last eight or belongs to another window; "
                            "read the window again with get_ui_tree and retry with what it returns.")
    entry = read_entry["nodes"].get(element_id)
    if entry is None:
        raise s.Unsupported(f"{element_id} is not in that read; read the window again with get_ui_tree.")
    accessible, expected = entry
    if identity(accessible) != expected:
        raise s.Unsupported(f"stale_state_token: {element_id} changed or is gone; read the window again with get_ui_tree.")
    return accessible


def settle(s, atspi, pid, act):
    """Run `act` and wait for the window to react: up to 0.6 s for a first event, then 0.15 s of quiet,
    at most 2 s. `ui_changed` means AT-SPI events arrived; `unverified` never means "no effect"."""
    events = []

    def on_event(event):
        source = getattr(event, "source", None)
        if source is not None and _safe(lambda: source.get_process_id()) == pid:
            events.append(time.monotonic())
    kinds = ("object:state-changed", "object:children-changed", "object:property-change", "object:text-changed",
             "object:visible-data-changed", "focus:", "window:create")
    listener = _safe(lambda: atspi.EventListener.new(on_event))
    registered = [kind for kind in kinds if listener is not None and _safe(lambda kind=kind: listener.register(kind), False)]
    glib = _safe(lambda: importlib.import_module("gi.repository.GLib"))
    context = _safe(lambda: glib.MainContext.default()) if glib else None
    started = time.monotonic()
    try:
        result = act()
        while time.monotonic() - started < SETTLE_CAP:
            while context is not None and context.pending():
                context.iteration(False)
            now = time.monotonic()
            if not events and now - started >= SETTLE_FIRST_EVENT:
                break
            if events and now - events[-1] >= SETTLE_QUIET:
                break
            time.sleep(0.02)
    finally:
        for kind in registered:
            _safe(lambda kind=kind: listener.deregister(kind))
    elapsed = time.monotonic()
    return result, {"effect": "ui_changed" if events else "unverified", "settle_ms": int((elapsed - started) * 1000),
                    "settled": not events or elapsed - events[-1] >= SETTLE_QUIET}


def click_element(s, args, guard):
    atspi = load(s)
    window = exact_window(s, args)
    node = resolve(s, window, args.get("element_id"), args.get("expected_state_token"))
    state = _safe(lambda: node.get_state_set())
    if state is not None and not (state.contains(atspi.StateType.ENABLED) or state.contains(atspi.StateType.SENSITIVE)):
        raise s.Unsupported(f"{args['element_id']} is disabled; no action was performed.")
    names = _actions(atspi, node)
    preferred = [index for name in PREFERRED_ACTIONS for index, value in enumerate(names) if value == name]
    if preferred:
        index = preferred[0]
    elif len(names) == 1:
        index = 0
    else:
        raise s.Unsupported(f"{args['element_id']} has no single press action ({names or 'none'}); "
                            "take a screenshot and use click with its pixel coordinates.")
    guard()
    ok, observed = settle(s, atspi, window["pid"], lambda: bool(atspi.Action.do_action(node, index)))
    if not ok:
        raise s.Unsupported(f"AT-SPI refused the {names[index]} action; no retry was sent.")
    return {"ok": True, "element_id": args["element_id"], "action": names[index], **observed,
            "hint": "Read the window again with get_ui_tree before the next element action."}


def press(s, window, element_id, token, action_name):
    """Run one named AT-SPI action of an element from a read, such as activate on a text field for Enter."""
    atspi = load(s)
    node = resolve(s, window, element_id, token)
    names = _actions(atspi, node)
    if action_name not in names:
        raise s.Unsupported(f"{element_id} has no {action_name} action; no key was sent.")
    if not atspi.Action.do_action(node, names.index(action_name)):
        raise s.Unsupported(f"AT-SPI refused the {action_name} action; no retry was sent.")
