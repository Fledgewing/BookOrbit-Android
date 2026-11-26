#!/usr/bin/env python3
"""Android adapter boundary. No baselines, annotations, environment switches or per-file skips.
Only composition roots may name implementations; protocol belongs to adapter directories.
"""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
KOTLIN = Path('android/companion/app/src/main/java')
LUA = Path('android/koreader/orbit.koplugin')
REGISTRY = KOTLIN / 'net/fledgewing/orbitcompanion/ServerAdapters.kt'
LUA_REGISTRY = LUA / 'main.lua'
PROTOCOL = re.compile(r'/api/v1|/?koreader/plugin\b|/catalog/(?:books|sections|dashboard)|\b(?:readStatus|progressPercentage|smartScopeId|seriesName|seriesId|seriesIndex|lastReadAt|addedAt|updatedAt|contentVersion|hasCover|seriesSummary|libraryVersion|generatedAt|finishedThisYear|readingGoal|thumbnailUrl|detailUrl|downloadUrl|userkey|server_url)\b|BookOrbit|bookorbit[_./]')
IMPLEMENTATION = re.compile(r'(?:net\.fledgewing\.orbitcompanion\.server\.[a-z]+|(?:ko|logic)/server/|[\"\']bookorbit_)')


def code_only(source, lua=False):
    # Tokenize strings before comments: URL // and literal -- are data, not comments.
    pattern = (r'--\[(=*)\[.*?\]\1\]|--[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\[(=*)\[.*?\]\2\]' if lua else
               r'""".*?"""|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|/\*.*?\*/|//[^\n]*')
    return re.sub(pattern, lambda m: re.sub(r'[^\n]', ' ', m[0]) if m[0].startswith(('--', '//', '/*')) else m[0], source, flags=re.S)


def violations(path, source):
    path = Path(path)
    kotlin_adapter = path.is_relative_to(KOTLIN / 'net/fledgewing/orbitcompanion/server')
    lua_adapter = any(path.is_relative_to(LUA / family / 'server') for family in ('ko', 'logic'))
    if kotlin_adapter or lua_adapter:
        if kotlin_adapter:
            expected = '.'.join(path.relative_to(KOTLIN).parent.parts)
            if not re.search(r'^package ' + re.escape(expected) + r'\s*$', source, re.M):
                return [f'{path}: adapter package must match its source directory']
        return []
    lua = path.suffix == '.lua'
    code = code_only(source, lua)
    wiring = path in (REGISTRY, LUA_REGISTRY)
    errors = []
    for n, line in enumerate(code.splitlines(), 1):
        # About's shared credits are data, not a protocol call. The literal credit is the sole
        # permitted brand use, not an exception for the About source file.
        line = line.replace('"bookorbit-credit"', '"credit"')
        protocol_line = line
        if wiring:
            # Remove only implementation identifiers/imports and quoted module paths. Endpoint
            # and field checks run before this mask, so embedding a route in an ID cannot hide it.
            if re.search(r'/api/v1|/?koreader/plugin\b|/catalog/(?:books|sections|dashboard)|\b(?:readStatus|progressPercentage|smartScopeId|seriesName|seriesId|seriesIndex|lastReadAt|addedAt|updatedAt|contentVersion|hasCover|seriesSummary|libraryVersion|generatedAt|finishedThisYear|readingGoal|thumbnailUrl|detailUrl|downloadUrl|userkey|server_url)\b', line):
                errors.append(f'{path}:{n}: protocol in composition root: {line.strip()}')
            protocol_line = re.sub(r'BookOrbit\w*|bookorbit(?:[/._a-z]*)', 'adapter', line)
        if PROTOCOL.search(protocol_line): errors.append(f'{path}:{n}: server protocol outside adapter: {line.strip()}')
        if not wiring and IMPLEMENTATION.search(line): errors.append(f'{path}:{n}: implementation import outside registry: {line.strip()}')
    return errors


class GuardTests(unittest.TestCase):
    def test_rejects_protocol_and_imports_even_with_suppression_comments(self):
        for path in (KOTLIN / 'Widget.kt', LUA / 'ko/widget.lua'):
            for value in ('"/api/v1/books"', '"/koreader/plugin/catalog/books"', '"readStatus"', '"BookOrbit"', '"bookorbit_api"'):
                self.assertTrue(violations(path, '// skip boundary\n-- allow-server\n' + value), value)
        self.assertTrue(violations(KOTLIN / 'Widget.kt', 'import net.fledgewing.orbitcompanion.server.bookorbit.Hidden'))
    def test_comments_are_the_only_ignored_syntax(self):
        self.assertFalse(violations(KOTLIN / 'Widget.kt', '// BookOrbit\n/* readStatus */\nval x="https://library.invalid"'))
        self.assertFalse(violations(LUA / 'ko/widget.lua', '-- BookOrbit\n--[[ readStatus ]]\nlocal x="https://library.invalid"'))
        self.assertTrue(violations(KOTLIN / 'Widget.kt', 'val x="https://library.invalid/api/v1"'))
        self.assertTrue(violations(LUA / 'ko/widget.lua', 'local x="--BookOrbit"'))
    def test_wiring_cannot_hold_protocol(self):
        self.assertTrue(violations(REGISTRY, 'val path="/api/v1"'))
        self.assertTrue(violations(REGISTRY, 'val path="bookorbit/api/v1"'))
        self.assertTrue(violations(LUA_REGISTRY, 'local field="readStatus"'))
    def test_entire_production_tree(self):
        errors = []
        for root in (KOTLIN, LUA):
            for path in sorted((ROOT / root).rglob('*')):
                if path.suffix in ('.kt', '.java', '.lua'):
                    errors.extend(violations(path.relative_to(ROOT), path.read_text()))
        self.assertFalse(errors, '\n' + '\n'.join(errors))

if __name__ == '__main__':
    unittest.main()
