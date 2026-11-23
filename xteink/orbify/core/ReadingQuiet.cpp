#include "ReadingQuiet.h"

#include <cstring>

namespace orbify::quiet {

namespace {
struct Named {
  Event event;
  const char* name;
};
constexpr Named NAMES[] = {
    {Event::BackgroundRender, "background-render"}, {Event::Message, "message"},
    {Event::UpdatePrompt, "update-prompt"},         {Event::NetworkStatus, "network-status"},
    {Event::SyncStatus, "sync-status"},             {Event::Restart, "restart"},
    {Event::EndOfBook, "end-of-book"},              {Event::UserOpened, "user-opened"},
    {Event::DuringSleep, "during-sleep"},
};
}  // namespace

bool mayShow(const Event event, const bool reading) {
  switch (event) {
    case Event::EndOfBook:
    case Event::UserOpened:
    case Event::DuringSleep:
      return true;
    case Event::BackgroundRender:
      return false;  // never on display, reading or not: a repaint would only redraw someone else's screen
    case Event::Message:
    case Event::UpdatePrompt:
    case Event::NetworkStatus:
    case Event::SyncStatus:
    case Event::Restart:
      return !reading;
  }
  return !reading;
}

bool eventFromName(const char* name, Event& out) {
  if (!name) return false;
  for (const Named& n : NAMES) {
    if (std::strcmp(n.name, name) == 0) {
      out = n.event;
      return true;
    }
  }
  return false;
}

const char* eventName(const Event event) {
  for (const Named& n : NAMES) {
    if (n.event == event) return n.name;
  }
  return "?";
}

}  // namespace orbify::quiet
