#include "CopyQueue.h"

#include <cstdlib>
#include <cstring>

#include "CopyCheck.h"

namespace orbify::refresh {

namespace {
const char* const HEADER = "orbify-copy-refresh 1";

bool isHash(const char* hash) {
  return orbify::copy::compare(hash, hash) == orbify::copy::Verdict::Same;
}

bool parseInt(const std::string& field, long long& out) {
  if (field.empty()) return false;
  char* end = nullptr;
  out = std::strtoll(field.c_str(), &end, 10);
  return end && *end == '\0';
}
}  // namespace

bool shouldRefresh(const int64_t indexedBookId, const char* cardHash, const Match* match) {
  if (indexedBookId <= 0 || !match || !isHash(cardHash)) return false;
  return match->bookId == indexedBookId && !match->positionCompatible;
}

bool Queue::add(const Entry& entry) {
  for (Entry& e : entries) {
    if (e.path != entry.path) continue;
    if (std::strcmp(e.oldHash, entry.oldHash) == 0) return false;
    e = entry;
    e.attempts = 0;
    return true;
  }
  entries.push_back(entry);
  entries.back().attempts = 0;
  return true;
}

const Entry* Queue::next() const {
  for (const Entry& e : entries) {
    if (e.attempts < MAX_ATTEMPTS) return &e;
  }
  return nullptr;
}

void Queue::done(const std::string& path) {
  for (size_t i = 0; i < entries.size(); ++i) {
    if (entries[i].path == path) {
      entries.erase(entries.begin() + static_cast<long>(i));
      return;
    }
  }
}

void Queue::failed(const std::string& path) {
  for (size_t i = 0; i < entries.size(); ++i) {
    if (entries[i].path != path) continue;
    Entry e = entries[i];
    ++e.attempts;
    entries.erase(entries.begin() + static_cast<long>(i));
    entries.push_back(e);
    return;
  }
}

size_t Queue::pending() const {
  size_t n = 0;
  for (const Entry& e : entries) n += e.attempts < MAX_ATTEMPTS ? 1 : 0;
  return n;
}

std::string Queue::serialize() const {
  std::string out = std::string(HEADER) + "\n";
  for (const Entry& e : entries) {
    out += std::to_string(e.bookId) + "\t" + std::to_string(e.fileId) + "\t" + e.oldHash + "\t" +
           std::to_string(e.attempts) + "\t" + e.path + "\n";
  }
  return out;
}

bool Queue::parse(const std::string& text) {
  entries.clear();
  if (text.empty()) return true;
  size_t pos = text.find('\n');
  if (text.substr(0, pos) != HEADER) return false;
  while (pos != std::string::npos && pos + 1 < text.size()) {
    const size_t start = pos + 1;
    pos = text.find('\n', start);
    const std::string line = text.substr(start, pos == std::string::npos ? std::string::npos : pos - start);
    std::string fields[5];
    size_t from = 0;
    int n = 0;
    for (; n < 4; ++n) {
      const size_t tab = line.find('\t', from);
      if (tab == std::string::npos) break;
      fields[n] = line.substr(from, tab - from);
      from = tab + 1;
    }
    if (n != 4) continue;
    fields[4] = line.substr(from);
    long long book = 0, file = 0, attempts = 0;
    if (!parseInt(fields[0], book) || !parseInt(fields[1], file) || !parseInt(fields[3], attempts)) continue;
    if (book <= 0 || attempts < 0 || fields[4].empty() || !isHash(fields[2].c_str())) continue;
    Entry e;
    e.bookId = book;
    e.fileId = file;
    std::memcpy(e.oldHash, fields[2].c_str(), 32);
    e.attempts = static_cast<uint8_t>(attempts > MAX_ATTEMPTS ? MAX_ATTEMPTS : attempts);
    e.path = fields[4];
    entries.push_back(e);
  }
  return true;
}

BeforeDownload beforeDownload(const char* cardHash, const char* libraryHash) {
  if (!isHash(libraryHash)) return BeforeDownload::CannotVerify;
  return orbify::copy::compare(cardHash, libraryHash) == orbify::copy::Verdict::Same ? BeforeDownload::AlreadyCurrent
                                                                                     : BeforeDownload::Download;
}

AfterDownload afterDownload(const char* newHash, const char* libraryHash) {
  return orbify::copy::compare(newHash, libraryHash) == orbify::copy::Verdict::Same ? AfterDownload::Commit
                                                                                     : AfterDownload::RollBack;
}

}  // namespace orbify::refresh
