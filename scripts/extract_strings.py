#!/usr/bin/env python3
"""
Translation Strings Extractor

Extracts translatable strings from Lua source files and generates a POT file.
Supports regular strings with _() and _lc(), and plural strings with N_() and N_lc().
"""

import re
import datetime
import pathlib
from collections import defaultdict

# Plugin root (the .koplugin directory), resolved from this script's own
# location rather than assumed from the current working directory. This is
# what lets the script be run from anywhere — `python3 extract_strings.py`
# from inside scripts/, `python3 scripts/extract_strings.py` from the plugin
# root, an absolute path from a Makefile, etc. — and still find every .lua
# file and write locale/simpleui.pot in the right place, instead of silently
# scanning/writing relative to whatever directory the caller happened to be
# in.
PLUGIN_ROOT = pathlib.Path(__file__).resolve().parent.parent

def strip_lua_line_comments(content):
    """Blank out Lua "--" line comments, preserving line/column positions.

    Tracks whether each character is inside a quoted string so a "--"
    that appears in real code isn't mistaken for one sitting in a
    comment. Once a comment starts, the rest of the line is replaced
    with spaces rather than removed, so line numbers used for #:
    locations stay accurate.
    """
    out_lines = []
    for line in content.split('\n'):
        in_string = None  # holds the active quote char, or None
        comment_start = None
        i = 0
        while i < len(line):
            ch = line[i]
            if in_string:
                if ch == '\\':
                    i += 1  # skip the escaped character too
                elif ch == in_string:
                    in_string = None
            elif ch in ('"', "'"):
                in_string = ch
            elif ch == '-' and line[i:i + 2] == '--':
                comment_start = i
                break
            i += 1
        if comment_start is not None:
            line = line[:comment_start]
        out_lines.append(line)
    return '\n'.join(out_lines)

def extract_strings():
    """Extract translatable strings from Lua files."""
    regular_strings = defaultdict(list)  # string -> [(file, line), ...]
    plural_strings = defaultdict(list)   # (singular, plural) -> [(file, line), ...]

    # Patterns
    regular_pattern = re.compile(r'(?<!\w)(?:_|_lc)\s*\(\s*"((?:[^"\\]|\\.)*)"')
    plural_pattern = re.compile(r'(?<!\w)(?:N_|N_lc)\s*\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"')

    # Sorted so the order of #: references does not depend on the filesystem.
    for lua_file in sorted(PLUGIN_ROOT.rglob('*.lua')):
        if lua_file.name.startswith('.'):  # Skip hidden files
            continue

        try:
            content = lua_file.read_text(encoding='utf-8', errors='ignore')
        except Exception as e:
            print(f"Warning: Could not read {lua_file}: {e}")
            continue

        # Doc comments (e.g. usage examples in a module's header) often show
        # sample code that itself calls _(), which would otherwise be
        # extracted as if it were a real, user-facing string. Strip Lua
        # line comments before matching so only strings that actually run
        # are collected. No string in this codebase contains "--", so
        # truncating each line at its first unquoted "--" is safe and
        # keeps line numbers unchanged.
        content = strip_lua_line_comments(content)

        # #: locations in the .pot are plugin-root-relative (e.g.
        # "modules/module_recent.lua:42"), regardless of where the script
        # was invoked from — keeps the file stable across machines/checkouts
        # and matches the existing convention in locale/simpleui.pot.
        rel_path = lua_file.relative_to(PLUGIN_ROOT)

        lines = content.splitlines()
        for line_num, line in enumerate(lines, 1):
            # Check for regular strings
            for match in regular_pattern.finditer(line):
                string = match.group(1)
                regular_strings[string].append((str(rel_path), line_num))

        # Check for plural strings on the whole content (may span lines)
        for match in plural_pattern.finditer(content):
            singular = match.group(1)
            plural = match.group(2)
            # Calculate line number from match position
            line_num = content[:match.start()].count('\n') + 1
            plural_strings[(singular, plural)].append((str(rel_path), line_num))

    return regular_strings, plural_strings

def generate_pot(regular_strings, plural_strings):
    """Generate POT file content."""
    lines = []

    # Header
    lines.append('# Simple UI — KOReader plugin')
    lines.append('# Translation template')
    lines.append('#')
    lines.append('msgid ""')
    lines.append('msgstr ""')
    lines.append('"Project-Id-Version: simpleui\\n"')
    lines.append(f'"POT-Creation-Date: {datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M%z")}\\n"')
    lines.append('"MIME-Version: 1.0\\n"')
    lines.append('"Content-Type: text/plain; charset=UTF-8\\n"')
    lines.append('"Content-Transfer-Encoding: 8bit\\n"')
    lines.append('')

    # Regular strings
    for string in sorted(regular_strings.keys()):
        locations = regular_strings[string]
        for file_path, line_num in locations:
            normalized_path = file_path.replace('\\', '/')
            lines.append(f'#: {normalized_path}:{line_num}')
        lines.append(f'msgid "{string}"')
        lines.append('msgstr ""')
        lines.append('')

    # Plural strings
    for (singular, plural), locations in sorted(plural_strings.items()):
        for file_path, line_num in locations:
            normalized_path = file_path.replace('\\', '/')
            lines.append(f'#: {normalized_path}:{line_num}')
        lines.append(f'msgid "{singular}"')
        lines.append(f'msgid_plural "{plural}"')
        lines.append('msgstr[0] ""')
        lines.append('msgstr[1] ""')
        lines.append('')

    return '\n'.join(lines)

def main():
    print("Extracting translatable strings...")
    regular_strings, plural_strings = extract_strings()

    total_regular = len(regular_strings)
    total_plural = len(plural_strings)
    total_strings = total_regular + total_plural

    print(f"Found {total_regular} regular strings and {total_plural} plural strings")

    pot_content = generate_pot(regular_strings, plural_strings)

    pot_path = PLUGIN_ROOT / 'locale' / 'simpleui.pot'
    pot_path.write_text(pot_content, encoding='utf-8')

    print(f"{total_strings} strings written to {pot_path}")

if __name__ == '__main__':
    main()
