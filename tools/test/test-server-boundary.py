#!/usr/bin/env python3
"""Android adapter boundary. No baselines, annotations, environment switches or per-file skips.
Only composition roots may name implementations; protocol belongs to adapter directories.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPANION = Path('android/companion/app/src')
KOTLIN = COMPANION / 'main/java'
LUA = Path('android/koreader/orbit.koplugin')
REGISTRY = KOTLIN / 'net/fledgewing/orbitcompanion/ServerAdapters.kt'
LUA_REGISTRY = LUA / 'main.lua'
ABOUT_CREDIT = Path('shared/about/credits.json')
RESOURCE_ROOTS = (Path('shared/settings'), Path('shared/ui'), Path('shared/about'))
# Protocol inventory, not a file baseline. Every consumer is checked for every token.
FIELDS = ("readStatus", "progressPercentage", "smartScopeId", "seriesName", "seriesId",
          "seriesIndex", "lastReadAt", "addedAt", "updatedAt", "contentVersion", "hasCover",
          "seriesSummary", "libraryVersion", "generatedAt", "finishedThisYear", "readingGoal",
          "thumbnailUrl", "detailUrl", "downloadUrl", "userkey", "server_url",
          "accessToken", "refreshToken", "accessTokenExpiresAt", "refreshTokenExpiresAt",
          "clientKind", "deviceLabel", "readingSeconds", "durationSeconds", "sessionId", "dashboardConfig",
          "hasNext", "hasPrevious")
WIRE_PROTOCOL = re.compile(
    r'/api/v1|/?koreader/plugin\b|\bcatalog/(?:books|sections|dashboard)|\b(?:' + '|'.join(FIELDS) +
    r')\b|smart[ _-]?scopes?|x-auth-user|x-auth-key|/koreader/(?:users|syncs|credentials)|'
    r'/auth/(?:login|refresh|logout)|/opds(?:-users\b|[/?\"\']|$)', re.I)
PROTOCOL = re.compile(WIRE_PROTOCOL.pattern + r'|bookorbit', re.I)
IMPLEMENTATION = re.compile(r'(?:net\.fledgewing\.orbitcompanion\.server\.[a-z]+|(?:ko|logic)[/.]server[/.]|[\"\']bookorbit_|\bServerCache\b)')
# Reviewed legacy facade consumers: permissions to call the facade, never protocol exemptions.
# main.lua is the only implementation loader; owned Home/Details/widget modules are absent.
LUA_COMPAT_CONSUMERS = frozenset(LUA / 'ko' / name for name in (
    'home.lua', 'notices.lua', 'sleepscreen.lua',
    'endsheet.lua',
))

LEGACY_GLOBALS = r'OC|Mirror|OSM|Copies|LF|Grouping|Rec|EOB|Sync'
LUA_STRINGS = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\[(=*)\[.*?\]\1\]', re.S)

LEGACY_API = re.compile(r'\b(?:requestLifecycleOutboxDrain|requestProgressPull|requestProgressPush|fetchRemoteProgress|getLifecycleOutbox|getSyncCoordinator|last_remote_progress|pull_timestamp|push_timestamp|promptLogin|startSweep|enqueueLifecycleSnapshot|catalogSetReadStatus|catalogSetRating|catalogBooks|catalogBook|newClient|getDocumentDigest|remoteProgressIsNewer|isSamePlace|pages_before_update|isLoggedIn|_onSuspend)\b')



def code_only(source, lua=False):
    # Tokenize strings before comments: URL // and literal -- are data, not comments.
    pattern = (r'--\[(=*)\[.*?\]\1\]|--[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\[(=*)\[.*?\]\2\]' if lua else
               r'""".*?"""|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|/\*.*?\*/|//[^\n]*')
    return re.sub(pattern, lambda m: re.sub(r'[^\n]', ' ', m[0]) if m[0].startswith(('--', '//', '/*')) else m[0], source, flags=re.S)


def violations(path, source):
    path = Path(path)
    # Sync ownership has completed its cutover. This check precedes adapter handling:
    # no Lua adapter/facade can resurrect the retired client's server-call primitives.
    if path.is_relative_to(LUA) and path.suffix == '.lua':
        code = code_only(source, True)
        identifiers = LUA_STRINGS.sub(lambda m: re.sub(r'[^\n]', ' ', m[0]), code)
        if re.search(r'[:.]\s*(?:requestLifecycleOutboxDrain|requestProgressPull|requestProgressPush|fetchRemoteProgress|'
                     r'getLifecycleOutbox|getSyncCoordinator|enqueueLifecycleSnapshot|startSweep|'
                     r'getProgress|updateProgress|matchCheck|uploadPageStats|uploadAnnotations|exchangeAnnotations|'
                     r'exchangeAck|exchangeBookmarks|exchangeBookmarksAck|uploadBookStates|bulkProgress|sweepComplete)\s*\(', identifiers):
            return [f'{path}: retired server sync call in the Android plugin; use Library companion commands']
        if re.search(r'/koreader/(?:syncs\b|plugin/(?:match-check|page-stats|annotations(?:/|[\"\'])|bookmarks(?:/|[\"\'])|book-states|bulk-progress|sweep-complete))', code):
            return [f'{path}: sync route in Android plugin']
    relative = path.relative_to(COMPANION) if path.is_relative_to(COMPANION) else None
    source_root = COMPANION / relative.parts[0] / relative.parts[1] if relative and len(relative.parts) > 2 and relative.parts[1] in ('java', 'kotlin') else None
    kotlin_adapter = source_root is not None and path.is_relative_to(source_root / 'net/fledgewing/orbitcompanion/server')
    lua_adapter = any(path.is_relative_to(LUA / family / 'server') for family in ('ko', 'logic'))
    cover_errors = []
    if path.is_relative_to(LUA) and path.suffix == '.lua':
        code = code_only(source, True)
        if re.search(r'\b(?:httpCover|coverDownload|CoverChild)\b|[:.]downloadCatalog(?:Thumbnail|AuthorPhoto)\s*\(|[\"\']/(?:thumbnail|photo)[\"\']|/catalog/(?:books|authors)/[^\s\"\']+/(?:thumbnail|photo)', code):
            cover_errors.append(f'{path}: plugin cover transport is companion-owned; use the neutral library command')
        if re.search(r'\b(?:Store[.:](?:read|search)|Server[.:]bulkList)\s*\(|\bCompanion\.ACTION\.(?:MIRROR|CHECK)\b|\b(?:FROM|JOIN)\s+(?:bulk_\w+|list_items|books)\b', code, re.I):
            cover_errors.append(f'{path}: catalog interpretation/transport is companion-owned; consume a bounded library snapshot')
        if re.search(r'\bCompanion\.ACTION\.COPIES\b|[:.]catalogSet(?:ReadStatus|Rating)\s*\(|[:.]downloadCatalogFile\s*\(|[\"\']/koreader/plugin/catalog/(?:files|books)/', code):
            cover_errors.append(f'{path}: catalog copy/finish transport is companion-owned; use Library commands/snapshots')
    if kotlin_adapter or lua_adapter:
        if kotlin_adapter and path.suffix in ('.kt', '.java'):
            expected = '.'.join(path.relative_to(source_root).parent.parts)
            if not re.search(r'^package ' + re.escape(expected) + r'\s*$', source, re.M):
                return [f'{path}: adapter package must match its source directory']
        return cover_errors
    lua = path.suffix == '.lua'
    if path.suffix in ('.xml', '.html'):
        source = re.sub(r'<!--.*?-->', lambda m: re.sub(r'[^\n]', ' ', m[0]), source, flags=re.S)
    code = code_only(source, lua)
    wiring = path in (REGISTRY, LUA_REGISTRY)
    errors = list(cover_errors)
    if lua and re.search(r'(?:require\s*\(?|pcall\s*\(\s*require\s*,)\s*["\'](?:socket\.http|bookorbit)["\']|\bhttp\.request\s*[({]', code):
        errors.append(f'{path}: direct server transport/import outside the adapter')
    if lua and re.search(r'\bLibraryAdapter[.:]', code) and path != LUA / 'ko/library.lua':
        errors.append(f'{path}: only the library interface may call its adapter binding')
    if lua and re.search(r'\bServer[.:]|\b(?:serverPlugin|serverOverBook|serverScreen)\s*\(', code) and path not in LUA_COMPAT_CONSUMERS:
        errors.append(f'{path}: unreviewed legacy adapter facade consumer; owned UI must use Library')
    if lua:
        # These are implementation objects exported by old shared-environment modules,
        # not neutral services. Quoted UI labels such as "Sync" are still ordinary data.
        identifiers = LUA_STRINGS.sub(lambda m: re.sub(r'[^\n]', ' ', m[0]), code)
        if re.search(r'\bServerCache[.:]', identifiers):
            errors.append(f'{path}: protocol cache policy outside adapter')
        if re.search(r'\b(?:' + LEGACY_GLOBALS + r')\b', identifiers) or re.search(
                r'\[\s*["\'](?:' + LEGACY_GLOBALS + r')["\']\s*\]', code):
            errors.append(f'{path}: shared backend implementation outside adapter; use Library or reviewed Server facade')
        if re.search(r'\bStore[.:](?:read|search)\b', identifiers):
            errors.append(f'{path}: legacy protocol lookup outside adapter')
        if path != LUA / 'ko/store.lua' and re.search(r'\bStore[.:](?:conn|rows|within|meta)\b', identifiers) or path not in (LUA / 'ko/store.lua', LUA / 'ko/library.lua') and re.search(r'\bStore[.:]library\b', identifiers):
            errors.append(f'{path}: owned UI must read through Library, not persistence internals')
    for n, line in enumerate(code.splitlines(), 1):
        # About's shared credits are data, not a protocol call. The literal credit is the sole
        # permitted brand use, not an exception for the About source file.
        line = line.replace('"bookorbit-credit"', '"credit"')
        protocol_line = line
        if wiring:
            # Remove only implementation identifiers/imports and quoted module paths. Endpoint
            # and field checks run before this mask, so embedding a route in an ID cannot hide it.
            if WIRE_PROTOCOL.search(line):
                errors.append(f'{path}:{n}: protocol in composition root: {line.strip()}')
            protocol_line = re.sub(r'BookOrbit\w*|bookorbit(?:[/._a-z]*)', 'adapter', line, flags=re.I)
        if lua and LEGACY_API.search(line): errors.append(f'{path}:{n}: upstream sync/catalog primitive outside adapter: {line.strip()}')
        # About credit prose may name its credited project; routes and fields remain forbidden.
        protocol = WIRE_PROTOCOL if path == ABOUT_CREDIT else PROTOCOL
        if protocol.search(protocol_line): errors.append(f'{path}:{n}: server protocol outside adapter: {line.strip()}')
        if not wiring and IMPLEMENTATION.search(line): errors.append(f'{path}:{n}: implementation import outside registry: {line.strip()}')
    return errors


class GuardTests(unittest.TestCase):
    def test_sync_transport_cannot_hide_inside_a_lua_adapter(self):
        for name in ('ko/sync.lua','ko/server/hidden.lua','ko/server/bookorbit.lua'):
            for code in ('p:requestProgressPull()', 'api:updateProgress(doc, .5)', 'api:exchangeBookmarks({})', '"/koreader/syncs/progress"', '"/koreader/plugin/page-stats"', '"/koreader/plugin/annotations/exchange"'):
                self.assertTrue(violations(LUA / name, code), (name,code))
        # These are native KOReader locator captures, also used by its independent built-in sync.
        self.assertFalse(violations(LUA / 'ko/position_sync.lua','engine:getLastProgress(); engine:getLastPercent()'))
    def test_rejects_protocol_and_imports_even_with_suppression_comments(self):
        for path in (KOTLIN / 'Widget.kt', LUA / 'ko/widget.lua'):
            for value in ('"/api/v1/books"', '"catalog/books"', '"/auth/login"', '"/opds/catalog"', '"x-auth-key"', '"Smart Scopes"', '"/koreader/plugin/catalog/books"', '"readStatus"', '"BookOrbit"', '"bookorbit"', '"BOOKORBIT"', '"bookorbit_api"'):
                self.assertTrue(violations(path, '// skip boundary\n-- allow-server\n' + value), value)
        self.assertTrue(violations(KOTLIN / 'Widget.kt', 'import net.fledgewing.orbitcompanion.server.bookorbit.Hidden'))
        self.assertTrue(violations(COMPANION / 'debug/kotlin/Widget.kt', 'val path="/api/v1"'))
    def test_only_reviewed_legacy_modules_can_call_the_lua_facade(self):
        self.assertTrue(violations(LUA / 'ko/home_widgets.lua', 'Server.loaded("api")'))
        self.assertTrue(violations(LUA / 'ko/home_widgets.lua', 'LibraryAdapter.read("x")'))
        self.assertTrue(violations(LUA / 'ko/home_widgets.lua', 'serverPlugin()'))
        self.assertFalse(violations(LUA / 'ko/home.lua', 'Server.loaded("toast")'))
        # Reviewed facade consumers still cannot contain protocol data or direct imports.
        self.assertTrue(violations(LUA / 'ko/home.lua', 'local field="readStatus"'))
        self.assertTrue(violations(LUA / 'ko/home.lua', 'require("bookorbit_api")'))
        self.assertTrue(violations(LUA / 'ko/widget.lua', 'require("ko.server.bookorbit")'))
        self.assertTrue(violations(LUA / 'ko/widget.lua', 'require("socket.http")'))
        self.assertTrue(violations(LUA / 'ko/widget.lua', 'http.request{}'))
        self.assertTrue(violations(LUA / 'ko/home.lua', 'p:fetchRemoteProgress(digest, callback)'))
    def test_shared_environment_cannot_bypass_adapter_import_guards(self):
        for value in ('OC.client()', 'Mirror.catalog()', 'OSM.pullThenDrain()', 'Sync.waitOutbox()',
                      'EOB.actions.book()', 'Rec.report()', 'quiet(Copies)', 'env["OC"].request()', 'ServerCache.normalize(reply)',
                      'Store.read(owner,key,path)', 'Store.search(owner,path)', 'Store.library(owner,key)'):
            self.assertTrue(violations(LUA / 'ko/home_widgets.lua', value), value)
            self.assertTrue(violations(LUA / 'ko/home.lua', value), value)
        self.assertFalse(violations(LUA / 'ko/home_editor.lua', 'Store.readFile(path)'))
        self.assertFalse(violations(LUA / 'ko/menu.lua', 'local label="Sync"'))
    def test_comments_are_the_only_ignored_syntax(self):
        self.assertFalse(violations(KOTLIN / 'Widget.kt', '// BookOrbit\n/* readStatus */\nval x="https://library.invalid"'))
        self.assertFalse(violations(LUA / 'ko/widget.lua', '-- BookOrbit\n--[[ readStatus ]]\nlocal x="https://library.invalid"'))
        self.assertTrue(violations(KOTLIN / 'Widget.kt', 'val x="https://library.invalid/api/v1"'))
        self.assertTrue(violations(LUA / 'ko/widget.lua', 'local x="--BookOrbit"'))
    def test_wiring_cannot_hold_protocol(self):
        self.assertTrue(violations(REGISTRY, 'val path="/api/v1"'))
        self.assertTrue(violations(REGISTRY, 'val path="bookorbit/api/v1"'))
        self.assertTrue(violations(LUA_REGISTRY, 'local field="readStatus"'))
        self.assertTrue(violations(LUA_REGISTRY, 'ServerCache.normalize(reply)'))
    def test_resources_cannot_hide_protocol(self):
        for path in (Path('shared/settings/schema.json'), COMPANION / 'main/res/values/strings.xml',
                     COMPANION / 'debug/assets/settings.json', LUA / 'settings_schema.json'):
            for value in ('BookOrbit', '/api/v1', 'smart scope', 'readStatus'):
                self.assertTrue(violations(path, value), (path, value))
        self.assertFalse(violations(COMPANION / 'main/AndroidManifest.xml', '<!-- BookOrbit https://library.invalid -->'))
        self.assertFalse(violations(ABOUT_CREDIT, '{"paragraphs":["BookOrbit credit"]}'))
        self.assertTrue(violations(ABOUT_CREDIT, '{"url":"/api/v1"}'))
    def test_cover_transport_cannot_hide_inside_a_lua_adapter(self):
        for path in (LUA / 'ko/covers.lua', LUA / 'ko/server/bookorbit/hidden.lua', LUA / 'logic/server/bookorbit/hidden.lua'):
            for source in ('OC.httpCover(client,path)', 'OC.coverDownload(client,stock,id,path)',
                           'client:downloadCatalogThumbnail(id,path)', 'client:downloadCatalogAuthorPhoto(id,path)',
                           'local route="/catalog/books/" .. id .. "/thumbnail"',
                           'local route="/catalog/books/7/thumbnail"', 'local route="/catalog/authors/7/photo"'):
                self.assertTrue(violations(path,source), (path,source))
        self.assertFalse((ROOT / LUA / 'ko/server/bookorbit/cache.lua').exists())
        self.assertFalse((ROOT / LUA / 'ko/cover_child.lua').exists())

    def test_catalog_interpreter_cannot_be_reintroduced_in_any_lua_adapter(self):
        for path in (LUA / 'ko/library.lua', LUA / 'ko/server/bookorbit/other.lua'):
            for source in ('Store.read(owner,key,path)', 'Store.search(owner,path)', 'Server.bulkList(conn,window)',
                           'Companion.send(Companion.ACTION.MIRROR,{})', 'Companion.send(Companion.ACTION.CHECK,{})',
                           'local sql="SELECT item FROM bulk_books"'):
                self.assertTrue(violations(path,source), (path,source))
        for name in ('mirror','store','library_bookorbit'):
            retired=LUA / 'ko/server/bookorbit' / (name+'.lua')
            self.assertFalse((ROOT / retired).exists())
            self.assertNotIn(str(retired.relative_to(LUA)),(ROOT / LUA_REGISTRY).read_text())
        self.assertFalse(violations(LUA / 'ko/library.lua','Store.library(owner,request)'))
        self.assertTrue(violations(LUA / 'ko/library.lua','Store.rows(conn,sql)'))

    def test_copy_and_finish_transport_cannot_hide_in_any_lua_adapter(self):
        for path in (LUA / 'ko/library.lua',LUA / 'ko/server/bookorbit/other.lua'):
            for source in ('Companion.send(Companion.ACTION.COPIES,{})','client:catalogSetReadStatus(id,status)',
                           'client:catalogSetRating(id,rating)','client:downloadCatalogFile(id,path)',
                           'local route="/koreader/plugin/catalog/files/7/download"'):
                self.assertTrue(violations(path,source),(path,source))
        for name in ('copies','grouping','recommended','endofbook'):
            retired=LUA / 'ko/server/bookorbit' / (name+'.lua')
            self.assertFalse((ROOT / retired).exists())
            self.assertNotIn(str(retired.relative_to(LUA)),(ROOT / LUA_REGISTRY).read_text())
        for name in ('finish','recommendations'):
            self.assertFalse(violations(LUA / 'ko' / (name+'.lua'),(ROOT / LUA / 'ko' / (name+'.lua')).read_text()))

    def test_entire_production_tree(self):
        errors = []
        for root in (COMPANION, LUA, *RESOURCE_ROOTS):
            for path in sorted((ROOT / root).rglob('*')):
                # Test source sets hold deliberate protocol fixtures, not app code. All production
                # variants and both supported JVM source folders are scanned, not just main/java.
                if root == COMPANION and path.relative_to(ROOT / COMPANION).parts[0].lower().startswith(('test', 'androidtest')):
                    continue
                if path.suffix in ('.kt', '.java', '.lua', '.json', '.xml', '.html', '.properties'):
                    errors.extend(violations(path.relative_to(ROOT), path.read_text()))
        self.assertFalse(errors, '\n' + '\n'.join(errors))

if __name__ == '__main__':
    unittest.main()
