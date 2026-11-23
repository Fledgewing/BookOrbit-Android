#include "LocalFirst.h"

#include <cstdio>
#include <cstring>
#include <string>

namespace orbify {

size_t formatAge(const uint32_t seconds, char* out, const size_t capacity) {
  int n;
  if (seconds < 60) {
    n = std::snprintf(out, capacity, "just now");
  } else if (seconds < 3600) {
    n = std::snprintf(out, capacity, "%u min", static_cast<unsigned>(seconds / 60));
  } else if (seconds < 86400) {
    n = std::snprintf(out, capacity, "%u h", static_cast<unsigned>(seconds / 3600));
  } else {
    n = std::snprintf(out, capacity, "%u d", static_cast<unsigned>(seconds / 86400));
  }
  return n < 0 ? 0 : (static_cast<size_t>(n) < capacity ? static_cast<size_t>(n) : capacity - 1);
}

size_t formatStamp(const bool online, const uint32_t fetchedAt, const uint32_t now, const bool failed, char* out,
                   const size_t capacity) {
  if (!capacity) return 0;
  char age[24];
  const bool known = fetchedAt != 0 && now >= fetchedAt;
  if (known) formatAge(now - fetchedAt, age, sizeof(age));
  const bool justNow = known && now - fetchedAt < 60;
  int n;
  if (online && !failed) {
    n = !known ? std::snprintf(out, capacity, "updated earlier")
        : justNow ? std::snprintf(out, capacity, "updated just now")
                  : std::snprintf(out, capacity, "updated %s ago", age);
  } else {
    const char* lead = online ? "Not updated \xC2\xB7 saved" : "Offline, saved";
    if (!known) {
      n = std::snprintf(out, capacity, "%s", online ? "Not updated" : "Offline");
    } else if (justNow) {
      n = std::snprintf(out, capacity, "%s just now", lead);
    } else {
      n = std::snprintf(out, capacity, "%s %s ago", lead, age);
    }
  }
  return n < 0 ? 0 : (static_cast<size_t>(n) < capacity ? static_cast<size_t>(n) : capacity - 1);
}

ShownBook overlayBook(const ServerBook& server, const DeviceBook& device, const bool autoSync) {
  ShownBook shown;
  shown.percent = server.percent;
  shown.state = server.state;
  if (!device.known) return shown;
  shown.deviceWins = device.pending || device.changedAt > server.lastReadAt;
  if (shown.deviceWins) {
    shown.percent = device.percent;
    if (device.state != BookState::Unknown) shown.state = device.state;
  }
  shown.notSynced = device.pending && (device.blocked || !autoSync);
  return shown;
}

bool catalogOpensInPlace(const bool hasSavedRoot, const bool hasCredentials) { return hasSavedRoot && hasCredentials; }

OfflineTap offlineTapAction(const RowTarget target, const bool saved, const bool onCard) {
  if (target == RowTarget::Book) return onCard ? OfflineTap::OpenBook : OfflineTap::ConnectAndDownload;
  return saved ? OfflineTap::Open : OfflineTap::ConnectAndOpen;
}

bool canSortLocally(const size_t savedRows, const size_t total) { return total > 0 && savedRows >= total; }

namespace {

// Lower-case ASCII and fold the Latin-1 letters (UTF-8 C3 xx) to their base letter.
std::string fold(const char* text) {
  static const char LATIN1[] = "aaaaaaaceeeeiiiidnooooo/ouuuuyty";  // U+00E0..U+00FF
  std::string out;
  if (!text) return out;
  for (const unsigned char* p = reinterpret_cast<const unsigned char*>(text); *p; ++p) {
    if (p[0] == 0xC3 && p[1] >= 0x80 && p[1] <= 0xBF) {
      const unsigned lower = (p[1] | 0x20) - 0xA0;  // C3 80..9F are the capitals of C3 A0..BF
      out += lower < 32 ? LATIN1[lower] : static_cast<char>(p[1]);
      ++p;
    } else {
      out += static_cast<char>(*p >= 'A' && *p <= 'Z' ? *p + 32 : *p);
    }
  }
  return out;
}

}  // namespace

bool searchMatches(const char* query, const char* title, const char* author) {
  const std::string haystack = fold(title) + "\n" + fold(author);
  const std::string q = fold(query);
  size_t start = 0;
  bool any = false;
  while (start < q.size()) {
    size_t end = q.find(' ', start);
    if (end == std::string::npos) end = q.size();
    if (end > start) {
      any = true;
      if (haystack.find(q.substr(start, end - start)) == std::string::npos) return false;
    }
    start = end + 1;
  }
  return any;
}

size_t pagesToEvict(const uint32_t* savedAt, const size_t count, size_t* drop, const size_t capacity) {
  if (count <= MAX_SAVED_PAGES) return 0;
  size_t n = 0;
  const size_t want = count - MAX_SAVED_PAGES;
  // Selection of the `want` oldest, ties to the lower index; count is at most a few hundred.
  while (n < want && n < capacity) {
    size_t oldest = count;
    for (size_t i = 0; i < count; ++i) {
      bool taken = false;
      for (size_t k = 0; k < n; ++k) taken = taken || drop[k] == i;
      if (taken) continue;
      if (oldest == count || savedAt[i] < savedAt[oldest]) oldest = i;
    }
    drop[n++] = oldest;
  }
  return n;
}

uint32_t ownerKey(const char* serverUrl, const char* username) {
  uint32_t h = 2166136261u;
  const auto mix = [&h](const char* s) {
    for (; s && *s; ++s) {
      h ^= static_cast<unsigned char>(*s);
      h *= 16777619u;
    }
  };
  mix(serverUrl);
  mix("\n");
  mix(username);
  return h;
}

}  // namespace orbify
