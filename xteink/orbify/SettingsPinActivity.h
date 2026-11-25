// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of Orbify's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#pragma once

#include <FreeInkUIGfxRenderer.h>
#include <I18n.h>

#include <atomic>
#include <cstdint>

#include "activities/Activity.h"
#include "util/ButtonNavigator.h"
#include "SettingsPin.h"

// CrossInk-Tailnet settings PIN entry (hooked in by the settings-pin patch): four digits in boxes, Up/Down
// change the one under the cursor, Confirm moves on and submits after the last, Left/Right
// move between them, Back cancels. Laid out like FrontlightTimePickerActivity's fields. On a
// touch screen a number pad (FrontlightTimePickerActivity's key grid) types the digits too.
class SettingsPinActivity final : public Activity {
 public:
  enum class Mode : uint8_t {
    Unlock,  // the gate in front of a locked screen: a right PIN unlocks Settings
    Verify,  // one action (SettingsPin::ask): a right PIN only lets that action go ahead
    Manage,  // Settings > Settings PIN: set one, or change or remove the one set
  };

  SettingsPinActivity(GfxRenderer& renderer, MappedInputManager& mappedInput, Mode mode)
      : Activity(mode == Mode::Unlock ? "SettingsPinGate" : "SettingsPin", renderer, mappedInput), mode(mode) {}

  void onEnter() override;
  void loop() override;
  void render(RenderLock&&) override;

 private:
#if CROSSINK_TAILNET_ABOUT_CREDIT
  enum class Stage : uint8_t { Enter, Choose, New, Repeat, Gate };
#else
  enum class Stage : uint8_t { Enter, Choose, New, Repeat };
#endif

  const Mode mode;
  Stage stage = Stage::Enter;
  uint8_t digits[SettingsPin::DIGITS] = {};
  uint8_t firstEntry[SettingsPin::DIGITS] = {};
  uint8_t cursor = 0;
  uint8_t choice = 0;     // Stage::Choose: 0 = change, 1 = remove
  StrId message{};        // under the boxes; empty id = none
  bool hasMessage = false;
  bool cursorShown = false;  // Up/Down changed the digit under the cursor: show it
  ButtonNavigator buttonNavigator;
  freeink::ui::InteractionBuffer<48> keypadInteractions;
  freeink::ui::TouchHoldRouter keypadTouchRouter;
  std::atomic<bool> keypadReady{false};

  void startStage(Stage next);
  void moveCursor(int delta);
  void typeDigit(uint8_t digit);
  void backspace();
  void handleKeypadValue(int16_t value);
  bool handleTouch();
  void drawHints();
  void submit();
  void done(bool cancelled);
};
