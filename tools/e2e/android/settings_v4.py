#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""V4 settings acceptance and native screenshots; explicit emulator targets only."""
import argparse
import json
from pathlib import Path
import time
from run import Emulator


def review(d, out):
    out.mkdir(parents=True, exist_ok=True)
    d.wait_companion()
    d.dismiss_color_notice()
    checks = []
    def step(name, code):
        result = d.command(code + ';return true')
        time.sleep(.3)
        d.shot(out / (name + '.png'))
        checks.append({'screen': name, 'result': result})
        (out / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
        print(name, flush=True)
    def clean():
        d.command('if AccountView.active then AccountView.active:close() end;if ReaderCompanionView.active then ReaderCompanionView.active:close() end;while SettingsView.active do local v=SettingsView.active;v.onBack=nil;v:close() end;return true')
    clean()
    time.sleep(2)
    d.command('local w=top();if w and type(w.text)=="string" and w.text:find("setup steps",1,true) then click("Later") end;Library.companion.setupLater();return true')
    step('settings-root', 'Library.companion.setupLater();plugin:showSettings()')
    # Exercise actual native hit geometry once, rather than only calling callbacks.
    d.shell('input', 'tap', '350', '240')
    d.command('assert(AccountView.active and top()==AccountView.active.dialog);return true')
    clean()
    for group in ('sync', 'library', 'reading', 'home', 'sleep', 'updates', 'about'):
        step('settings-' + group, 'plugin:showSettings(' + json.dumps(group) + ')')
        v = int(d.command('return #SettingsView.active.dialog.buttons'))
        if group in ('sync', 'reading', 'sleep') and v > 1:
            # Capture every bounded page, retaining the exact production page partition.
            page = 2
            while d.command('local b=SettingsView.active.dialog:getButtonById("next");return b and b.enabled and "more" or "done"') == 'more':
                index = page
                page += 1
                step('settings-' + group + '-' + str(index), 'SettingsView.active.dialog:getButtonById("next"):onKitTap()')
        clean()
    d.command('AccountView.open();AccountView.active:command("account.signOut",{});return true')
    deadline = time.monotonic() + 40
    while d.command('return AccountView.active.busy and "pending" or "ready"') != 'ready':
        if time.monotonic() > deadline: raise TimeoutError('Sign-out did not finish')
        time.sleep(.2)
    step('account-off', 'assert(not AccountView.active.state.signedIn);AccountView.active:paint()')
    step('signin', 'AccountView.active:form("account")')
    step('signin-result', 'AccountView.active:command("account.signIn",{server="https://fixture.example.test",username="reader",password="fixture"})')
    deadline = time.monotonic() + 40
    while d.command('return AccountView.active.busy and "pending" or "ready"') != 'ready':
        if time.monotonic() > deadline: raise TimeoutError('Sign-in did not finish')
        time.sleep(.2)
    step('signin-result', 'assert(AccountView.active.state.signedIn);assert(AccountView.active.password==nil)')
    step('account', 'AccountView.active.page="summary";AccountView.active:paint()')
    step('signin-sync', 'AccountView.active:form("sync")')
    step('signin-opds', 'AccountView.active:form("opds")')
    step('signout', 'AccountView.active.page="signout";AccountView.active:paint()')
    clean()
    for key in ('font', 'spacing', 'contrast', 'margins'):
        step('custom-' + key, 'plugin:showSettings("reading");SettingsView.active.dialog:getButtonById("setting-' + str({'font': 2, 'margins': 4, 'spacing': 6, 'contrast': 8}[key]) + '"):onKitTap();assert(CustomReading.editor.key==' + json.dumps(key) + ')' )
        d.command('local e=CustomReading.editor;local before=Library.readingCustom("reading-custom-"..e.key);e:onStepMore();e:onStepLess();assert(ReadingStyle.label(Library.readingCustom("reading-custom-"..e.key),e.key)==ReadingStyle.label(before,e.key));CustomReading.close();return true')
        clean()
    for group, row in (('updates', 2), ('home', 4), ('reading', 1)):
        step('choice-' + group, 'plugin:showSettings(' + json.dumps(group) + ');SettingsView.active.dialog:getButtonById("setting-' + str(row) + '"):onKitTap()')
        clean()
    step('goal-off', 'LocalReadingSettings.open()')
    deadline = time.monotonic() + 40
    while d.command('local r=SettingsView.active.make()[1];return r.pending and "pending" or "ready"') != 'ready':
        if time.monotonic() > deadline: raise TimeoutError('Local goal did not publish')
        time.sleep(.2)
    step('goal-editor', 'SettingsView.active.dialog:getButtonById("setting-1"):onKitTap()')
    step('goal-keyboard', 'top():getButtonById("goal-number"):onKitTap()')
    d.command('local input;for _,w in ipairs(UI._window_stack) do if w.widget.setInputText then input=w.widget end end;assert(input and input.input_type=="number");input:setInputText("12");input.buttons[1][2].callback();return true')
    step('goal-number', 'assert(top():getButtonById("goal-save"));top():getButtonById("goal-save"):onKitTap()')
    time.sleep(1)
    step('goal-on', 'SettingsView.active:paint()')
    d.command('SettingsView.active.dialog:getButtonById("setting-1"):onKitTap();top():getButtonById("goal-off"):onKitTap();return true')
    clean()
    step('full-reader-helpers', 'ReaderCompanionView.open("helpers")')
    step('permission-explanation', 'ReaderCompanionView.active.page="permission";ReaderCompanionView.active:paint()')
    d.command('ReaderCompanionView.active.dialog:getButtonById("later"):onKitTap();assert(ReaderCompanionView.active.page=="helpers");return true')
    clean()
    # Locked groups may be inspected, but every mutating leaf stays disabled.
    d.command('local rows=OrbitAndroid.readOnly({{text="Change",callback=function() error("PIN bypass") end}});assert(rows[1].enabled_func()==false);return true')
    return checks


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial', required=True)
    p.add_argument('--out', required=True, type=Path)
    args = p.parse_args()
    review(Emulator(args.serial), args.out)
