#include "SeriesCard.h"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace orbify {

namespace {

// Version 1 records are read as version 2 ones: the layout must not move.
static_assert(offsetof(CardBook, coverVer) == 92 && sizeof(CardBook) == 96, "CardBook keeps version 1's layout");

constexpr uint8_t CARD_MAGIC[4] = {'O', 'S', 'C', '1'};
// 2: CardBook::coverVer, in what version 1 left as padding (its bytes there are not zero).
// 3: the series name, this book's index and the series' size, after `author`.
constexpr uint8_t CARD_VERSION = 3;
constexpr uint8_t CARD_VERSION_NO_SERIES_LINE = 2;
constexpr uint8_t CARD_VERSION_NO_COVERS = 1;
// Versions 1 and 2 end with `author`, padded to the struct's alignment.
constexpr size_t LEGACY_STRUCT = (offsetof(SeriesCard, author) + sizeof(SeriesCard::author) + alignof(SeriesCard) - 1) /
                                 alignof(SeriesCard) * alignof(SeriesCard);
static_assert(offsetof(SeriesCard, seriesName) >= offsetof(SeriesCard, author) + sizeof(SeriesCard::author),
              "version 3 fields follow version 2's");

void copyText(char* dst, size_t capacity, const char* src) {
  if (!src) src = "";
  size_t n = std::strlen(src);
  if (n >= capacity) {
    n = capacity - 1;
    // Never end on half of a UTF-8 sequence.
    while (n > 0 && (static_cast<unsigned char>(src[n]) & 0xC0) == 0x80) --n;
  }
  std::memcpy(dst, src, n);
  dst[n] = '\0';
}

// seriesIndex is a decimal string on the server (book_metadata_series_index_format_chk:
// ^[0-9]+([.][0-9]+)?$); older servers may send a number. NaN when absent or not a number.
double indexOf(JsonVariantConst v) {
  if (v.is<double>() || v.is<long>()) return v.as<double>();
  const char* text = v.as<const char*>();
  if (!text || !*text) return NAN;
  char* end = nullptr;
  const double value = std::strtod(text, &end);
  return end && *end == '\0' ? value : NAN;
}

void indexText(JsonVariantConst v, char* out, size_t capacity) {
  if (const char* text = v.as<const char*>()) {
    copyText(out, capacity, text);
  } else if (!v.isNull()) {
    char buf[24];
    std::snprintf(buf, sizeof(buf), "%g", v.as<double>());
    copyText(out, capacity, buf);
  } else {
    out[0] = '\0';
  }
}

bool isRead(JsonVariantConst member) {
  return parseServerStatus(member["readStatus"].as<const char*>()) == ServerStatus::Read;
}

void setBook(CardBook& book, JsonVariantConst member) {
  book.id = member["id"].as<int64_t>();
  indexText(member["seriesIndex"], book.index, sizeof(book.index));
  copyText(book.title, sizeof(book.title), member["title"].as<const char*>());
}

// The members' read status by id (related books carry none, so a read book is known only
// when it is in this book's series).
bool memberRead(JsonArrayConst members, int64_t id) {
  for (JsonVariantConst m : members) {
    if (m["id"].as<int64_t>() == id) return isRead(m);
  }
  return false;
}

}  // namespace

void cardFilter(JsonDocument& filter) {
  filter["id"] = true;
  filter["authors"] = true;
  filter["seriesId"] = true;
  filter["seriesName"] = true;
  filter["seriesIndex"] = true;
  filter["readStatus"] = true;
  JsonObject member = filter["seriesMembers"].add<JsonObject>();
  member["id"] = true;
  member["title"] = true;
  member["seriesIndex"] = true;
  member["readStatus"] = true;
  JsonObject section = filter["relatedSections"].add<JsonObject>();
  section["id"] = true;
  JsonObject book = section["books"].add<JsonObject>();
  book["id"] = true;
  book["title"] = true;
}

bool pickCard(JsonObjectConst detail, size_t maxSuggestions, SeriesCard& out) {
  out = SeriesCard{};
  out.bookId = detail["id"].as<int64_t>();
  if (out.bookId <= 0) return false;
  out.status = parseServerStatus(detail["readStatus"].as<const char*>());
  JsonArrayConst authors = detail["authors"].as<JsonArrayConst>();
  if (!authors.isNull() && authors.size() > 0) copyText(out.author, sizeof(out.author), authors[0].as<const char*>());

  JsonArrayConst members = detail["seriesMembers"].as<JsonArrayConst>();
  copyText(out.seriesName, sizeof(out.seriesName), detail["seriesName"].as<const char*>());
  indexText(detail["seriesIndex"], out.seriesIndex, sizeof(out.seriesIndex));
  out.seriesCount = members.isNull() ? 0 : static_cast<uint16_t>(members.size() > 0xFFFF ? 0xFFFF : members.size());
  const double c = indexOf(detail["seriesIndex"]);
  int64_t nextId = 0;
  if (!detail["seriesId"].isNull() && !std::isnan(c)) {
    // Next: the smallest index above c, ties to the lowest id.
    JsonVariantConst best;
    double bestIndex = 0;
    bool unreadEarlier = false;
    JsonVariantConst firstUnread;
    double firstUnreadIndex = 0;
    for (JsonVariantConst m : members) {
      const int64_t id = m["id"].as<int64_t>();
      if (id == out.bookId) continue;  // the finished book counts as read
      const double i = indexOf(m["seriesIndex"]);
      if (std::isnan(i)) continue;
      if (i > c) {
        if (best.isNull() || i < bestIndex || (i == bestIndex && id < best["id"].as<int64_t>())) {
          best = m;
          bestIndex = i;
        }
      } else if (!isRead(m)) {
        if (!unreadEarlier || i < firstUnreadIndex ||
            (i == firstUnreadIndex && id < firstUnread["id"].as<int64_t>())) {
          firstUnread = m;
          firstUnreadIndex = i;
        }
        unreadEarlier = true;
      }
    }
    if (!best.isNull()) {
      const double wanted = std::floor(c) + 1;
      if (bestIndex > wanted) {
        out.next = SeriesCard::Next::Gap;
        out.missing = static_cast<uint16_t>(wanted);
      } else {
        out.next = SeriesCard::Next::Next;
        setBook(out.nextBook, best);
        out.nextRead = isRead(best);
        nextId = out.nextBook.id;
      }
    } else if (unreadEarlier) {
      out.next = SeriesCard::Next::LastUnread;
      setBook(out.nextBook, firstUnread);
      nextId = out.nextBook.id;
    } else {
      out.next = SeriesCard::Next::SeriesDone;
    }
  }

  // Suggestions: "author" books, then "similar", skipping this book, the next one and read ones.
  if (maxSuggestions > SeriesCard::MAX_SUGGESTIONS) maxSuggestions = SeriesCard::MAX_SUGGESTIONS;
  static const char* const ORDER[] = {"author", "similar"};
  for (uint8_t s = 0; s < 2 && out.suggestionCount < maxSuggestions; ++s) {
    for (JsonVariantConst section : detail["relatedSections"].as<JsonArrayConst>()) {
      const char* id = section["id"].as<const char*>();
      if (!id || std::strcmp(id, ORDER[s]) != 0) continue;
      for (JsonVariantConst book : section["books"].as<JsonArrayConst>()) {
        if (out.suggestionCount >= maxSuggestions) break;
        const int64_t bookId = book["id"].as<int64_t>();
        if (bookId <= 0 || bookId == out.bookId || bookId == nextId || memberRead(members, bookId)) continue;
        bool seen = false;
        for (uint8_t k = 0; k < out.suggestionCount; ++k) seen = seen || out.suggestions[k].id == bookId;
        if (seen) continue;
        CardBook& slot = out.suggestions[out.suggestionCount];
        slot.id = bookId;
        copyText(slot.title, sizeof(slot.title), book["title"].as<const char*>());
        out.sources[out.suggestionCount] = s == 0 ? SeriesCard::Source::Author : SeriesCard::Source::Similar;
        ++out.suggestionCount;
      }
    }
  }
  return true;
}

size_t serializeCard(const SeriesCard& card, uint8_t* out, const size_t capacity) {
  if (capacity < CARD_BYTES) return 0;
  std::memcpy(out, CARD_MAGIC, 4);
  out[4] = CARD_VERSION;
  out[5] = static_cast<uint8_t>(sizeof(SeriesCard) & 0xFF);
  out[6] = static_cast<uint8_t>(sizeof(SeriesCard) >> 8);
  out[7] = 0;
  std::memcpy(out + 8, &card, sizeof(SeriesCard));
  const uint32_t crc = slot::crc32(out, 8 + sizeof(SeriesCard));
  for (int i = 0; i < 4; ++i) out[8 + sizeof(SeriesCard) + i] = static_cast<uint8_t>(crc >> (8 * i));
  return CARD_BYTES;
}

size_t legacyCardBytes() { return 8 + LEGACY_STRUCT + 4; }

bool deserializeCard(const uint8_t* data, const size_t size, SeriesCard& out) {
  if (size < 8 || std::memcmp(data, CARD_MAGIC, 4) != 0) return false;
  const uint8_t version = data[4];
  const size_t structBytes = version == CARD_VERSION ? sizeof(SeriesCard) : LEGACY_STRUCT;
  if (version != CARD_VERSION && version != CARD_VERSION_NO_SERIES_LINE && version != CARD_VERSION_NO_COVERS) {
    return false;
  }
  if (size != 8 + structBytes + 4 || (data[5] | (data[6] << 8)) != static_cast<int>(structBytes)) return false;
  uint32_t crc = 0;
  for (int i = 0; i < 4; ++i) crc |= static_cast<uint32_t>(data[8 + structBytes + i]) << (8 * i);
  if (crc != slot::crc32(data, 8 + structBytes)) return false;
  out = SeriesCard{};
  std::memcpy(static_cast<void*>(&out), data + 8, structBytes);
  if (version != CARD_VERSION) {
    // The legacy record's tail padding lies where the series fields are now: they stay empty.
    std::memset(out.seriesName, 0, sizeof(out.seriesName));
    std::memset(out.seriesIndex, 0, sizeof(out.seriesIndex));
    out.seriesCount = 0;
  }
  out.author[sizeof(out.author) - 1] = '\0';
  out.seriesName[sizeof(out.seriesName) - 1] = '\0';
  out.seriesIndex[sizeof(out.seriesIndex) - 1] = '\0';
  out.nextBook.title[sizeof(out.nextBook.title) - 1] = '\0';
  if (out.suggestionCount > SeriesCard::MAX_SUGGESTIONS) return false;
  if (data[4] == CARD_VERSION_NO_COVERS) {
    out.nextBook.coverVer = 0;
    for (CardBook& book : out.suggestions) book.coverVer = 0;
  }
  return true;
}

}  // namespace orbify
