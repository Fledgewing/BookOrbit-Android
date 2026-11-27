-- SPDX-License-Identifier: AGPL-3.0-or-later
-- One bounded local call at class-load time. Never used by a paint or background timer.
Library={}
function Library.bootstrap()
    local finish=Budgets.span("library.bootstrap",now_s,log)
    if Companion.state()~="ok" then finish();return {ok="0",why="unavailable"} end
    local result=Jni.call(Companion.AUTHORITY,Companion.LIBRARY_BOOTSTRAP,{patch_version=PATCH_VERSION})
    local bytes=result and type(result.body)=="string" and #result.body or 0
    local within=Budgets.check(Budgets.libraryBootstrap,{rows=bytes>0 and 1 or 0,bytes=bytes,spawns=0,roundTrips=1,network=0,snapshotBytes=bytes})
    finish();return within and result or {ok="0",why="budget"}
end
