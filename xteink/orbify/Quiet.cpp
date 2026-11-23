#include "Quiet.h"

#include <Logging.h>

#include "activities/Activity.h"  // ActivityManager.h needs Activity complete

namespace OrbifyQuiet {

bool reading() { return activityManager.isReaderActivity(); }

bool allow(const orbify::quiet::Event event) {
  const bool isReading = reading();
  if (orbify::quiet::mayShow(event, isReading)) return true;
  // A background sync asks for a repaint at every step: log the other events only.
  if (event != orbify::quiet::Event::BackgroundRender) {
    LOG_INF("ORB", "Quiet: held %s (%s)", orbify::quiet::eventName(event), isReading ? "reading" : "off screen");
  }
  return false;
}

}  // namespace OrbifyQuiet
