-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Only selects companion-formatted rows; no capacity arithmetic or catalog work.
StoragePlan = {}
function StoragePlan.page(data)
    data=data or {}
    if data.pending then return {message="Loading…",parts={},actions={}} end
    if data.error and not data.freshness then return {message="Storage unavailable · Retry",parts={},actions={}} end
    return {message=data.error,caption=data.caption or "Space unavailable",warning=data.warning,
        parts=data.parts or {},actions=data.actions or {},folder=data.folder_label or "Not selected"}
end
function StoragePlan.confirm(action)
    if action.id=="covers" then return "Clear the cover cache?",action.detail .. ". Covers download again when you browse. Your books, progress and the server copies are not touched." end
    return action.id=="old" and "Remove books you haven't opened in 6 months?" or "Remove finished books?",
        action.detail .. ". They leave this device. They stay in your library on the server, and your progress, highlights and notes are kept."
end
