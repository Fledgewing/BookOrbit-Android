-- SPDX-License-Identifier: AGPL-3.0-or-later
Compat={PAGING={boardPage="function",boardFlip="function",listMode="function",listPaging="function",listGoPage="function"}}
function Compat.callable(v) return type(v)=="function" end
function Compat.missingOn(obj,needs)
    local out={};for key,kind in pairs(needs) do if type((obj or {})[key])~=kind then out[#out+1]=key end end
    table.sort(out);return out
end
HomePlan.SERVER_HOME="server-home"
