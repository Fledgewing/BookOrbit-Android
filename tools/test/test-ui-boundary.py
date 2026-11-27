#!/usr/bin/env python3
"""BookSync UI dependency boundary. Complete module roles, never a path/line skip list."""
from pathlib import Path
import importlib.util
import json
import subprocess
import sys
from functools import lru_cache
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / 'android/koreader/orbit.koplugin'
INVENTORY = ROOT / 'android/koreader/module-layers.json'
# Reuse the server guard's Lua lexer: comments alone are ignored, strings retained for imports.
spec = importlib.util.spec_from_file_location('server_boundary', ROOT / 'tools/test/test-server-boundary.py')
sys.dont_write_bytecode = True
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
LAYERS = json.loads(INVENTORY.read_text())


def identifiers(source):
    return server.LUA_STRINGS.sub(lambda m: re.sub(r'[^\n]', ' ', m[0]), server.code_only(source, True))


@lru_cache(maxsize=None)
def bytecode(source):
    # Compile/disassemble only: LuaJIT resolves local/upvalue/global scope for us. Never execute
    # the chunk. This catches aliases without confusing a local `state` or a table's `set` field.
    result = subprocess.run(['luajit', '-bl', '-'], input=source, text=True, errors="replace", capture_output=True)
    if result.returncode: raise ValueError(result.stderr.strip())
    return result.stdout


def globals_used(source, instruction='GGET'):
    return set(re.findall(r'\b' + instruction + r'\s+.*?; "([^"\n]+)"', bytecode(source)))


def exports(source):
    return globals_used(source, 'GSET')


def private_globals(layers=LAYERS):
    private = {'LibraryAdapter', 'io', 'ffi', 'android', 'Sync'}
    for name, role in layers.items():
        source = (PLUGIN / name).read_text()
        if role['layer'] == 'internal' and role.get('kind') != 'util':
            private.update(exports(source))
        elif role['layer'] == 'interface':
            private.update(exports(source) - set(role['public']))
    return private


PRIVATE = private_globals()


def violations(name, source, layers=LAYERS):
    errors = []
    if name not in layers:
        return [f'{name}: unclassified module']
    if layers[name]['layer'] != 'ui':
        return errors
    code = server.code_only(source, True)
    bare = identifiers(source)
    # A bare reference is forbidden even if assigned to an alias, passed as a value, or indexed.
    # Member fields with the same word (model.state, for example) are ordinary UI data.
    try:
        used = globals_used(source) | globals_used(source, 'GSET')
    except ValueError as error:
        return [f'{name}: invalid Lua: {error}']
    for token in sorted(used & PRIVATE):
        errors.append(f'{name}: private global {token}')
    for m in re.finditer(r'\[\s*["\']([^"\']+)["\']\s*\]', code):
        if m[1] in PRIVATE:
            errors.append(f'{name}: indexed private global {m[1]}')
    # UI cannot recover an implementation from its environment or execute/load arbitrary code.
    if re.search(r'\b(?:getfenv|setfenv|loadfile|dofile|loadstring)\s*\(', bare):
        errors.append(f'{name}: dynamic environment/code access bypasses the interface')
    if '_G' in used:
        errors.append(f'{name}: direct global environment access')
    if re.search(r'\bos\s*[.:]\s*(?:execute|remove|rename|tmpname|getenv)\b', bare):
        errors.append(f'{name}: file/process access outside the interface')
    # Include literal package.loaded/module-table access, not just require calls.
    for m in re.finditer(r'["\']((?:ko|logic)[/.][^"\']+)["\']', code):
        module = m[1].replace('.', '/') + '.lua'
        role = layers.get(module)
        if not role or role['layer'] == 'internal' and role.get('kind') != 'util':
            errors.append(f'{name}: private/unclassified module {module}')
    imports = re.finditer(r'(?:\brequire\b\s*\(?|\bpcall\s*\(\s*require\s*,)\s*', code)
    for m in imports:
        literal = re.match(r'(["\'])(.*?)\1', code[m.end():], re.S)
        if not literal:
            errors.append(f'{name}: dynamic module import')
            continue
        module = literal[2]
        if module.startswith(('ko/', 'ko.', 'logic/', 'logic.')):
            continue  # already checked against the role inventory above
        if module not in ('device', 'gettext', 'logger', 'ffi/blitbuffer') and not module.startswith(('ui/', 'apps/', 'document/')):
            errors.append(f'{name}: non-UI/native module import {module}')
    if re.search(r'\bpackage\s*\.\s*(?:loaders|searchers|loadlib)\b', bare):
        errors.append(f'{name}: dynamic package loader')
    return errors


class UIBoundaryTests(unittest.TestCase):
    def test_inventory_is_complete_and_typed(self):
        actual = {str(p.relative_to(PLUGIN)) for folder in ('ko', 'logic') for p in (PLUGIN / folder).rglob('*.lua')}
        self.assertEqual(actual, set(LAYERS), 'Every module needs an explicit role; stale entries fail too')
        for name, role in LAYERS.items():
            self.assertIn(role['layer'], ('ui', 'interface', 'internal'), name)
            self.assertTrue(role['purpose'], name)
            if role['layer'] == 'interface': self.assertTrue(role['public'], name)
            if role.get('kind') == 'util':
                used = globals_used((PLUGIN/name).read_text())
                self.assertFalse(used & (PRIVATE | {'require'}), name)

    def test_globals_aliases_callbacks_and_environment_access_fail(self):
        for value in ('Companion.state()', 'local c=Companion; c.send()', 'pcall(Store.readFile,path)',
                      'Cache.count(n)', 'SettingsSync.toWire(d,v)', 'Jni.startActivity{}', 'ReadingSync.run()',
                      'Shared.set(key,value)', 'S[key]=value', 'saveSettings()', 'LibraryAdapter.read(request)', 'OrbiSmart.decide()', 'Schedule.new()', 'WifiPlan.decide()',
                      'env["Companion"].send()', '_G["Store"].readFile(path)', 'getfenv()[key]',
                      'rawget(_G,"Companion")', 'io.open(path)', 'os.rename(a,b)', 'loadfile(path)()'):
            self.assertTrue(violations('ko/home.lua', value), value)

    def test_imports_and_module_table_access_fail(self):
        for source in ('require("ko.companion")', 'pcall(require,"ko/store")',
                       'package.loaded["ko.shared"].set(key,value)', 'require("ko/new_backend")',
                       'pcall(require,"ffi")', 'require(name)', 'require("new_backend")', 'require("dkjson").decode(raw)', 'require("datastorage")', 'require("ffi")'):
            self.assertTrue(violations('ko/home_widgets.lua', source), source)

    def test_all_ui_roles_receive_the_same_rules(self):
        for name, role in LAYERS.items():
            if role['layer'] == 'ui':
                self.assertTrue(violations(name, 'Store.readFile(path)'), name)
        self.assertTrue(violations('ko/new_screen.lua', 'Library.paint("home")'))

    def test_native_interface_ui_and_neutral_utilities_work(self):
        self.assertFalse(violations('ko/home.lua', '''
            -- Store.readFile(path)
            local label="Companion and Cache"
            Library.settings.write(key,value)
            UIManager:show(HomeWidgets.canvas(w,h))
            local widget=require("ui/widget/buttondialog")
            local bb=require("ffi/blitbuffer")
            UIUtil.count(3); Device.screen:getWidth(); model.state="ready"
        '''))

    def test_production(self):
        errors = []
        for name in LAYERS:
            errors.extend(violations(name, (PLUGIN/name).read_text()))
        self.assertFalse(errors, '\n'+'\n'.join(errors))


if __name__ == '__main__':
    unittest.main()
