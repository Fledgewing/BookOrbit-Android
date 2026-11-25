// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of Orbify's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#include "SettingsPinActivity.h"

#if CROSSINK_TAILNET_SETTINGS_PIN

#include <FreeInkUIIcon.h>
#include <GfxRenderer.h>
#include <I18n.h>
#include <Logging.h>

#include <algorithm>
#include <cstring>

#include "MappedInputManager.h"
#if CROSSINK_TAILNET_ABOUT_CREDIT
#include "activities/settings/AboutActivity.h"
#endif
#include "components/TouchHeaderBackButton.h"
#include "components/UITheme.h"
#include "components/icons/keyboardIcons.h"
#include "fontIds.h"

namespace {
namespace fui = freeink::ui;

constexpr int BOX_SIZE = 60;
constexpr int BOX_GAP = 14;
// The number pad: FrontlightTimePickerActivity's key grid, 1-9 then delete, 0, OK.
constexpr int KEYPAD_ROWS = 4;
constexpr fui::ActionId KEYPAD_ACTION = 1;
constexpr int16_t KEYPAD_DELETE = -1;
constexpr int16_t KEYPAD_OK = -2;

bool contains(const Rect& rect, const int x, const int y) {
  return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
}

// As FrontlightTimePickerActivity's keyboardRect(): the bottom of the safe area.
fui::Rect keypadRect(const GfxRenderer& renderer) {
  const auto& metrics = UITheme::getInstance().getMetrics();
  const int gap = metrics.keyboardKeySpacing;
  const int height = KEYPAD_ROWS * metrics.keyboardKeyHeight + (KEYPAD_ROWS - 1) * gap;
  int width = renderer.getScreenWidth() * metrics.keyboardWidthPercent / 100;
  int x = (renderer.getScreenWidth() - width) / 2;
  int y = renderer.getScreenHeight() - UITheme::getButtonHintsReserve(renderer) - metrics.verticalSpacing - height +
          metrics.keyboardVerticalOffset;
  const auto safe = UITheme::getInstance().getScreenSafeArea(renderer, true, false);
  const int right = std::min(x + width, safe.x + safe.width);
  x = std::max(x, safe.x);
  width = std::max(0, right - x);
  const int bottom = std::min(y + height, safe.y + safe.height);
  y = std::max(safe.y, bottom - height);
  return {static_cast<int16_t>(x), static_cast<int16_t>(y), static_cast<int16_t>(width),
          static_cast<int16_t>(std::max(0, bottom - y))};
}

// The vertical centre of the boxes (or the Change/Remove rows): between the header
// and the number pad when there is one, else the middle of the screen.
int contentCenterY(const GfxRenderer& renderer, const MappedInputManager& mappedInput) {
  if (!mappedInput.hasTouch()) return renderer.getScreenHeight() / 2;
  const Rect header = TouchHeaderBackButton::headerRect(renderer, mappedInput);
  const int top = header.y + header.height;
  return top + (keypadRect(renderer).y - top) / 2;
}

// Stage::Choose's two rows, for drawing and for taps.
Rect chooseRowRect(const GfxRenderer& renderer, const MappedInputManager& mappedInput, const int row,
                   const char* text) {
  const int lineHeight = renderer.getLineHeight(UI_12_FONT_ID);
  const int width = renderer.getTextWidth(UI_12_FONT_ID, text, EpdFontFamily::BOLD);
  const int x = (renderer.getScreenWidth() - width) / 2;
  const int y = contentCenterY(renderer, mappedInput) - lineHeight - 8 + row * (lineHeight + 16);
  return Rect{x - 12, y - 6, width + 24, lineHeight + 12};
}

#if CROSSINK_TAILNET_ABOUT_CREDIT
constexpr StrId GATE_ROWS[2] = {StrId::STR_ENTER_SETTINGS_PIN, StrId::STR_ABOUT};
#endif
constexpr StrId CHOOSE_ROWS[2] = {StrId::STR_CHANGE_PIN, StrId::STR_REMOVE_PIN};
}  // namespace

void SettingsPinActivity::onEnter() {
  Activity::onEnter();
  keypadTouchRouter.overrideValue = KEYPAD_DELETE;
  keypadTouchRouter.reset();
  keypadReady.store(false, std::memory_order_release);
#if CROSSINK_TAILNET_ABOUT_CREDIT
  startStage(mode == Mode::Manage ? (SettingsPin::isSet() ? Stage::Choose : Stage::New)
                                 : mode == Mode::Unlock ? Stage::Gate : Stage::Enter);
#else
  startStage(mode == Mode::Manage ? (SettingsPin::isSet() ? Stage::Choose : Stage::New) : Stage::Enter);
#endif
}

void SettingsPinActivity::startStage(const Stage next) {
  stage = next;
  memset(digits, 0, sizeof(digits));
  cursor = 0;
  cursorShown = false;
  requestUpdate();
}

void SettingsPinActivity::done(const bool cancelled) {
  ActivityResult result;
  result.isCancelled = cancelled;
  setResult(std::move(result));
  finish();
}

void SettingsPinActivity::moveCursor(const int delta) {
  cursor = static_cast<uint8_t>((cursor + SettingsPin::DIGITS + delta) % SettingsPin::DIGITS);
  cursorShown = false;
  requestUpdate();
}

void SettingsPinActivity::typeDigit(const uint8_t digit) {
  hasMessage = false;
  digits[cursor] = digit;
  if (cursor + 1 < SettingsPin::DIGITS) {
    cursor++;
    cursorShown = false;
    requestUpdate();
  } else {
    submit();
  }
}

void SettingsPinActivity::backspace() {
  if (cursor > 0 && !cursorShown) cursor--;
  digits[cursor] = 0;
  cursorShown = false;
  requestUpdate();
}

void SettingsPinActivity::handleKeypadValue(const int16_t value) {
#if CROSSINK_TAILNET_ABOUT_CREDIT
  if (stage == Stage::Choose || stage == Stage::Gate) return;
#else
  if (stage == Stage::Choose) return;
#endif
  if (value >= 0 && value <= 9) {
    typeDigit(static_cast<uint8_t>(value));
  } else if (value == KEYPAD_DELETE) {
    backspace();
  } else if (value == KEYPAD_OK) {
    submit();
  }
}

void SettingsPinActivity::submit() {
  hasMessage = false;
  switch (stage) {
#if CROSSINK_TAILNET_ABOUT_CREDIT
    case Stage::Gate:
      if (choice == 0) startStage(Stage::Enter);
      else startActivityForResult(std::make_unique<AboutActivity>(renderer, mappedInput),
                                  [this](const ActivityResult&) { requestUpdate(); });
      return;
#endif
    case Stage::Enter:
      if (!SettingsPin::verify(digits)) {
        LOG_INF("PIN", "Wrong settings PIN");
        message = StrId::STR_WRONG_PIN;
        hasMessage = true;
        startStage(Stage::Enter);
        return;
      }
      LOG_INF("PIN", "Settings PIN accepted (%s)", mode == Mode::Unlock ? "unlocked" : "one action");
      if (mode == Mode::Unlock) SettingsPin::unlock();
      done(false);
      return;
    case Stage::Choose:
      if (choice == 1) {
        SettingsPin::clear();
        done(false);
      } else {
        startStage(Stage::New);
      }
      return;
    case Stage::New:
      memcpy(firstEntry, digits, sizeof(firstEntry));
      startStage(Stage::Repeat);
      return;
    case Stage::Repeat:
      if (memcmp(firstEntry, digits, sizeof(digits)) != 0) {
        message = StrId::STR_PIN_MISMATCH;
        hasMessage = true;
        startStage(Stage::New);
        return;
      }
      SettingsPin::store(digits);
      // Set from inside Settings: it stays unlocked until Settings is left.
      SettingsPin::unlock();
      done(false);
      return;
  }
}

// Taps: a Change/Remove row, or a key of the number pad (FrontlightTimePickerActivity::loop()).
bool SettingsPinActivity::handleTouch() {
  if (!mappedInput.hasTouch()) return false;
  int tapX = 0;
  int tapY = 0;
  const bool tapped = mappedInput.wasScreenTapped(tapX, tapY);
#if CROSSINK_TAILNET_ABOUT_CREDIT
  if (stage == Stage::Choose || stage == Stage::Gate) {
#else
  if (stage == Stage::Choose) {
#endif
    if (!tapped) return false;
    for (int i = 0; i < 2; i++) {
#if CROSSINK_TAILNET_ABOUT_CREDIT
      if (contains(chooseRowRect(renderer, mappedInput, i, I18N.get(stage == Stage::Gate ? GATE_ROWS[i] : CHOOSE_ROWS[i])), tapX, tapY)) {
#else
      if (contains(chooseRowRect(renderer, mappedInput, i, I18N.get(CHOOSE_ROWS[i])), tapX, tapY)) {
#endif
        choice = static_cast<uint8_t>(i);
        submit();
        return true;
      }
    }
    return false;
  }
  if (!keypadReady.load(std::memory_order_acquire)) return false;
  unsigned long heldMs = 0;
  int candidateX = 0;
  int candidateY = 0;
  const bool tapCandidate = mappedInput.isScreenTouchTapCandidate(candidateX, candidateY, heldMs);
  int heldX = 0;
  int heldY = 0;
  const bool inContact = mappedInput.isScreenTouchHeld(heldX, heldY);
  const fui::TouchHoldRouter::Result result = keypadTouchRouter.update(
      keypadInteractions, tapCandidate, static_cast<int16_t>(candidateX), static_cast<int16_t>(candidateY), tapped,
      static_cast<int16_t>(tapX), static_cast<int16_t>(tapY), inContact, millis());
  if (result.event) {
    handleKeypadValue(result.event.value);
    return true;
  }
  if (result.activeChanged) requestUpdate();
  return false;
}

void SettingsPinActivity::loop() {
  if (TouchHeaderBackButton::wasTapped(mappedInput, renderer) ||
      mappedInput.wasPressed(MappedInputManager::Button::Back)) {
    mappedInput.suppressNextBackRelease();
    done(true);
    return;
  }
  if (mappedInput.wasReleased(MappedInputManager::Button::Confirm)) {
#if CROSSINK_TAILNET_ABOUT_CREDIT
    if (stage != Stage::Choose && stage != Stage::Gate && cursor + 1 < SettingsPin::DIGITS) {
#else
    if (stage != Stage::Choose && cursor + 1 < SettingsPin::DIGITS) {
#endif
      moveCursor(+1);
    } else {
      submit();
    }
    return;
  }
  if (handleTouch()) return;
#if CROSSINK_TAILNET_ABOUT_CREDIT
  if (stage == Stage::Choose || stage == Stage::Gate) {
#else
  if (stage == Stage::Choose) {
#endif
    buttonNavigator.onNextRelease([this] {
      choice ^= 1;
      requestUpdate();
    });
    buttonNavigator.onPreviousRelease([this] {
      choice ^= 1;
      requestUpdate();
    });
    return;
  }
  if (mappedInput.wasReleased(MappedInputManager::Button::Left)) {
    moveCursor(-1);
    return;
  }
  if (mappedInput.wasReleased(MappedInputManager::Button::Right)) {
    moveCursor(+1);
    return;
  }
  // Up (previous) and Down (next): the digit under the cursor down and up by one.
  buttonNavigator.onNextRelease([this] {
    digits[cursor] = static_cast<uint8_t>((digits[cursor] + 1) % 10);
    cursorShown = true;
    requestUpdate();
  });
  buttonNavigator.onPreviousRelease([this] {
    digits[cursor] = static_cast<uint8_t>((digits[cursor] + 9) % 10);
    cursorShown = true;
    requestUpdate();
  });
}

// What each physical button does here, matching loop(). The theme's button hints draw
// nothing on a touch screen (BaseTheme::drawButtonHints / drawSideButtonHints return when
// gpio.hasTouch()), so a touch reader (the X4 Pro: two side buttons, no Back/Confirm) gets
// the same information as one line of text above the number pad.
void SettingsPinActivity::drawHints() {
#if CROSSINK_TAILNET_ABOUT_CREDIT
  const bool choosing = stage == Stage::Choose || stage == Stage::Gate;
#else
  const bool choosing = stage == Stage::Choose;
#endif
  if (!mappedInput.hasTouchHardware()) {
    const char* confirm = choosing || cursor + 1 >= SettingsPin::DIGITS ? tr(STR_OK) : tr(STR_PIN_NEXT_DIGIT);
    const auto labels = choosing ? mappedInput.mapLabels(mappedInput.withBackArrow(tr(STR_BACK)), confirm,
                                                         tr(STR_DIR_UP), tr(STR_DIR_DOWN))
                                 : mappedInput.mapLabels(mappedInput.withBackArrow(tr(STR_BACK)), confirm,
                                                         tr(STR_PIN_PREV_DIGIT), tr(STR_PIN_NEXT_DIGIT));
    GUI.drawButtonHints(renderer, labels.btn1, labels.btn2, labels.btn3, labels.btn4);
    // Up (top) lowers the digit under the cursor, Down raises it.
    if (choosing) {
      GUI.drawSideButtonHints(renderer, tr(STR_DIR_UP), tr(STR_DIR_DOWN));
    } else {
      GUI.drawSideButtonHints(renderer, "-1", "+1");
    }
    return;
  }
  const char* text = I18N.get(choosing ? StrId::STR_PIN_TOUCH_HINT_CHOOSE : StrId::STR_PIN_TOUCH_HINT);
  const int lineHeight = renderer.getLineHeight(UI_10_FONT_ID);
  const int bottom = mappedInput.hasTouch() ? keypadRect(renderer).y : renderer.getScreenHeight() - lineHeight * 3;
  const int width = renderer.getTextWidth(UI_10_FONT_ID, text);
  renderer.drawText(UI_10_FONT_ID, std::max(0, (renderer.getScreenWidth() - width) / 2), bottom - lineHeight - 12,
                    text);
}

void SettingsPinActivity::render(RenderLock&&) {
  renderer.clearScreen();
  const StrId titleId = stage == Stage::New      ? StrId::STR_NEW_PIN
                        : stage == Stage::Repeat ? StrId::STR_REPEAT_PIN
                        : stage == Stage::Choose ? StrId::STR_SETTINGS_PIN
                                                 : StrId::STR_ENTER_SETTINGS_PIN;
  const Rect header = TouchHeaderBackButton::headerRect(renderer, mappedInput);
  if (mappedInput.hasTouchHardware()) {
    TouchHeaderBackButton::draw(renderer, header, I18N.get(titleId), false);
  } else {
    GUI.drawHeader(renderer, header, I18N.get(titleId));
  }

  const bool touch = mappedInput.hasTouch();
  const int lineHeight = renderer.getLineHeight(UI_12_FONT_ID);
  const int centerY = contentCenterY(renderer, mappedInput);
#if CROSSINK_TAILNET_ABOUT_CREDIT
  if (stage == Stage::Choose || stage == Stage::Gate) {
#else
  if (stage == Stage::Choose) {
#endif
    for (int i = 0; i < 2; i++) {
#if CROSSINK_TAILNET_ABOUT_CREDIT
      const char* text = I18N.get(stage == Stage::Gate ? GATE_ROWS[i] : CHOOSE_ROWS[i]);
#else
      const char* text = I18N.get(CHOOSE_ROWS[i]);
#endif
      const Rect row = chooseRowRect(renderer, mappedInput, i, text);
      if (i == choice) renderer.drawRect(row.x, row.y, row.width, row.height, true);
      renderer.drawText(UI_12_FONT_ID, row.x + 12, row.y + 6, text, true, EpdFontFamily::BOLD);
    }
    keypadReady.store(false, std::memory_order_release);
  } else {
    const int rowWidth = SettingsPin::DIGITS * BOX_SIZE + (SettingsPin::DIGITS - 1) * BOX_GAP;
    const int left = (renderer.getScreenWidth() - rowWidth) / 2;
    const int top = centerY - BOX_SIZE / 2;
    for (int i = 0; i < SettingsPin::DIGITS; i++) {
      const int x = left + i * (BOX_SIZE + BOX_GAP);
      renderer.drawRect(x, top, BOX_SIZE, BOX_SIZE, true);
      if (i == cursor) renderer.drawRect(x + 2, top + 2, BOX_SIZE - 4, BOX_SIZE - 4, true);
      // The digit under the cursor shows once Up/Down set it (always with buttons only);
      // typed ones are masked; with a number pad the ones still to type stay empty.
      char shown = '*';
      if (i == cursor) {
        shown = (cursorShown || !touch) ? static_cast<char>('0' + digits[i]) : '_';
      } else if (touch && i > cursor) {
        shown = ' ';
      }
      char text[2] = {shown, '\0'};
      const int width = renderer.getTextWidth(UI_12_FONT_ID, text, EpdFontFamily::BOLD);
      renderer.drawText(UI_12_FONT_ID, x + (BOX_SIZE - width) / 2, top + (BOX_SIZE - lineHeight) / 2, text, true,
                        EpdFontFamily::BOLD);
    }
    if (hasMessage) {
      const char* text = I18N.get(message);
      const int width = renderer.getTextWidth(UI_10_FONT_ID, text);
      renderer.drawText(UI_10_FONT_ID, (renderer.getScreenWidth() - width) / 2, top + BOX_SIZE + 24, text);
    }

    if (touch) {
      fui::GfxRendererTarget target(renderer);
      target.setFont(fui::GfxRendererTarget::FONT_SMALL, SMALL_FONT_ID);
      target.setFont(fui::GfxRendererTarget::FONT_BODY, UI_12_FONT_ID);
      const fui::DeviceContext device = target.deviceContext();
      const fui::InputSnapshot noInput{};
      keypadInteractions.beginPublishCycle();
      fui::Frame<48> frame(target, device, noInput, keypadInteractions);
      static constexpr const char* DIGIT_LABELS[] = {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"};
      fui::KeyGridKey keys[12];
      for (int i = 0; i < 9; ++i) {
        keys[i].label = DIGIT_LABELS[i + 1];
        keys[i].value = static_cast<int16_t>(i + 1);
      }
      keys[9].icon = fui::bitmapFromIcon(icon_backspace_28);
      keys[9].kind = fui::KeyKind::Delete;
      keys[9].value = KEYPAD_DELETE;
      keys[10].label = DIGIT_LABELS[0];
      keys[10].value = 0;
      keys[11].label = tr(STR_OK);
      keys[11].kind = fui::KeyKind::Ok;
      keys[11].value = KEYPAD_OK;

      fui::KeyGridProps props;
      props.keys = keys;
      props.rows = KEYPAD_ROWS;
      props.cols = 3;
      props.action = KEYPAD_ACTION;
      props.inputMask = static_cast<uint16_t>(fui::InputTouch | fui::InputLongPress);
      props.labelText.font = fui::GfxRendererTarget::FONT_BODY;
      props.gap = static_cast<int16_t>(UITheme::getInstance().getMetrics().keyboardKeySpacing);
      fui::keyGrid(frame, keypadRect(renderer), props);
      keypadInteractions.publish();
      keypadReady.store(true, std::memory_order_release);
    }
  }

  drawHints();
  renderer.displayBuffer();
}

#endif  // CROSSINK_TAILNET_SETTINGS_PIN
