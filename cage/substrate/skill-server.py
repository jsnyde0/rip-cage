#!/usr/bin/env python3
"""
skill-server.py - MCP stdio shim for Claude Code skill discovery.

Replaces the `ms` (meta-skill) binary inside containers where `ms` is not
available (it is macOS arm64-only). Implements the MCP tools/call protocol
for list, show, load, and search. Zero pip dependencies.

Wire format: newline-delimited JSON (one message per line) on stdio.
All logging goes to stderr; stdout is the protocol channel only.
"""

import json
import re
import signal
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# ANSI sanitization
# ---------------------------------------------------------------------------

def strip_ansi(text):
    """Strip ANSI escape codes from text (for SKILL.md content only)."""
    # CSI sequences: ESC [ ... final-byte (covers all standard sequences)
    # Non-CSI sequences: ESC ( X (charset designations etc.)
    text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)
    text = re.sub(r'\x1b\([A-Z]', '', text)
    return text


# ---------------------------------------------------------------------------
# Frontmatter parsing
# ---------------------------------------------------------------------------

def parse_description(content):
    """Extract the description field from YAML frontmatter, or return ''."""
    m = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
    if not m:
        return ''
    frontmatter = m.group(1)
    lines = frontmatter.splitlines()
    for i, line in enumerate(lines):
        if line.startswith('description:'):
            value = line[len('description:'):].strip()
            # Handle YAML block scalar indicators (>, |, >-, |-) —
            # collect indented continuation lines and join as description text
            if value in ('>', '|', '>-', '|-'):
                collected = []
                for continuation in lines[i + 1:]:
                    # Indented lines belong to the block scalar; stop on non-indented
                    if continuation.startswith(' ') or continuation.startswith('\t'):
                        collected.append(continuation.strip())
                    else:
                        break
                return ' '.join(collected)
            # Strip surrounding quotes from values like: description: "My skill"
            return value.strip('"\'')
    return ''


# ---------------------------------------------------------------------------
# Startup: build in-memory skill index
# ---------------------------------------------------------------------------

def build_index():
    """Glob ~/.claude/skills/*/SKILL.md at startup and build index dict."""
    index = {}
    skills_dir = Path.home() / '.claude' / 'skills'
    try:
        paths = list(skills_dir.glob('*/SKILL.md'))
    except OSError as e:
        print(f'[skill-server] WARN: skills dir not found, starting with 0 skills', file=sys.stderr)
        return index

    for path in paths:
        # Use is_file() to detect broken symlinks (Path.resolve() does NOT raise
        # on broken symlinks in Python 3.11 — it silently returns a non-existent path)
        if not path.is_file():
            print(f'[skill-server] WARN: skipping broken symlink: {path}', file=sys.stderr)
            continue
        dir_name = path.parent.name
        try:
            raw = path.read_text(encoding='utf-8', errors='replace')
        except Exception as e:
            print(f'[skill-server] WARN: could not read {path}: {e}', file=sys.stderr)
            continue
        description = parse_description(raw)
        # Cache ANSI-stripped content at startup (scan-once, serve from memory)
        content = strip_ansi(raw)
        index[dir_name] = {
            'id': dir_name,
            'name': dir_name,
            'description': description,
            'content': content,
        }

    print(f'[skill-server] Loaded {len(index)} skills', file=sys.stderr)
    return index


# ---------------------------------------------------------------------------
# MCP response helpers
# ---------------------------------------------------------------------------

def ok(req_id, result):
    return json.dumps({'jsonrpc': '2.0', 'id': req_id, 'result': result})


def err(req_id, code, message):
    return json.dumps({'jsonrpc': '2.0', 'id': req_id, 'error': {'code': code, 'message': message}})


def text_content(text):
    return {'content': [{'type': 'text', 'text': text}]}


# ---------------------------------------------------------------------------
# Handler dispatch
# ---------------------------------------------------------------------------

TOOLS_LIST_RESULT = {
    'tools': [
        {
            'name': 'list',
            'description': 'List all available skills',
            'inputSchema': {'type': 'object', 'properties': {}},
        },
        {
            'name': 'show',
            'description': 'Show full content of a skill',
            'inputSchema': {'type': 'object', 'properties': {'id': {'type': 'string'}}, 'required': ['id']},
        },
        {
            'name': 'load',
            'description': 'Load a skill (alias for show)',
            'inputSchema': {'type': 'object', 'properties': {'id': {'type': 'string'}}, 'required': ['id']},
        },
        {
            'name': 'search',
            'description': 'Search skills by keyword',
            'inputSchema': {'type': 'object', 'properties': {'query': {'type': 'string'}}, 'required': ['query']},
        },
    ]
}

INITIALIZE_RESULT = {
    'protocolVersion': '2024-11-05',
    'capabilities': {'tools': {}},
    'serverInfo': {'name': 'meta-skill', 'version': '0.1.0'},
}


def handle_initialize(req_id, params):
    return ok(req_id, INITIALIZE_RESULT)


def handle_tools_list(req_id, params):
    return ok(req_id, TOOLS_LIST_RESULT)


def handle_tools_call(req_id, params, index):
    tool_name = params.get('name', '')
    arguments = params.get('arguments') or {}

    if tool_name == 'list':
        skills_list = [
            {
                'id': s['id'],
                'name': s['name'],
                'description': s['description'],
                'layer': 'project',
            }
            for s in index.values()
        ]
        payload = json.dumps({'count': len(skills_list), 'skills': skills_list})
        return ok(req_id, text_content(payload))

    elif tool_name in ('show', 'load'):
        skill_id = arguments.get('id') or arguments.get('name', '')
        skill = index.get(skill_id)
        if skill is None:
            result = {
                'content': [{'type': 'text', 'text': f'Skill not found: {skill_id}'}],
                'isError': True,
            }
            return ok(req_id, result)
        # Serve from cached content (scanned once at startup, no per-call disk reads)
        payload = json.dumps({'content': skill['content']})
        return ok(req_id, text_content(payload))

    elif tool_name == 'search':
        query = (arguments.get('query') or '').lower()
        matched = [
            {
                'id': s['id'],
                'name': s['name'],
                'description': s['description'],
                'layer': 'project',
            }
            for s in index.values()
            if query in s['name'].lower() or query in s['description'].lower()
        ]
        payload = json.dumps({'count': len(matched), 'skills': matched})
        return ok(req_id, text_content(payload))

    else:
        # Unknown tool: return empty success (silent stub)
        return ok(req_id, text_content(''))


def dispatch(msg, index):
    """Dispatch a parsed JSON-RPC message. Returns response string or None."""
    # Notifications have no id field — silently discard
    if 'id' not in msg:
        return None

    req_id = msg['id']
    method = msg.get('method', '')
    params = msg.get('params') or {}

    if method == 'initialize':
        return handle_initialize(req_id, params)
    elif method == 'tools/list':
        return handle_tools_list(req_id, params)
    elif method == 'tools/call':
        return handle_tools_call(req_id, params, index)
    else:
        return err(req_id, -32601, f'Method not found: {method}')


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    index = build_index()

    while True:
        line = sys.stdin.readline()
        if not line:
            # EOF — exit cleanly
            break
        line = line.strip()
        if not line:
            # Blank line — skip silently
            continue
        try:
            msg = json.loads(line)
            response = dispatch(msg, index)
            if response is not None:
                print(response, flush=True)
        except Exception as e:
            print(f'[skill-server] ERROR: {e}', file=sys.stderr)
            continue


if __name__ == '__main__':
    main()
