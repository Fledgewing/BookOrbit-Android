// Host test for Orbify's finished-book queue (xteink/orbify/core/FinishQueue): the drain table in
// shared/fixtures/bookorbit/finish-cases.json (read by Android's tests too), the stale-push hold,
// the record format and the two-slot file under torn writes.
#include <ArduinoJson.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "FinishQueue.h"
#include "TestSupport.h"

using namespace orbify;

namespace {

// Answers from the fixture's "server" object, and records each request in the fixture's words.
class FixtureTransport : public FinishTransport {
 public:
  explicit FixtureTransport(JsonObjectConst server) : server_(server) {}
  std::vector<std::string> requests;

  int bookStates(const FinishJob& job, bool withStatus, bool withRating) override {
    std::string r = "book-states";
    if (withStatus) r += " complete";
    char day[11];
    if (job.finishedOn && formatDay(job.finishedOn, day)) r += std::string(" ") + day;
    if (withRating) r += job.rating < 0 ? " rating=clear" : " rating=" + std::to_string(job.rating);
    requests.push_back(r);
    return code("book-states");
  }
  int matchCheck(const char*, int64_t& outBookId) override {
    requests.push_back("match-check");
    JsonVariantConst v = server_["match-check"];
    outBookId = v["bookId"].isNull() ? 0 : v["bookId"].as<int64_t>();
    return v.isNull() ? 200 : v["code"].as<int>();
  }
  int readStatus(int64_t, ServerStatus& outStatus) override {
    requests.push_back("detail");
    JsonVariantConst v = server_["detail"];
    outStatus = parseServerStatus(v["readStatus"].as<const char*>());
    return v.isNull() ? 200 : v["code"].as<int>();
  }
  int setRead(int64_t) override {
    requests.push_back("read-status read");
    return code("read-status");
  }
  int setRating(int64_t, int8_t rating) override {
    requests.push_back(rating < 0 ? "rating clear" : "rating " + std::to_string(rating));
    return code("rating");
  }

 private:
  int code(const char* key) { return server_[key].isNull() ? 200 : server_[key].as<int>(); }
  JsonObjectConst server_;
};

FinishJob jobFrom(JsonObjectConst j, const char* hash, uint32_t now) {
  FinishJob job;
  strncpy(job.hash, hash, 32);
  job.bookId = j["bookId"].isNull() ? 0 : j["bookId"].as<int64_t>();
  job.finishedOn = parseDay(j["finishedOn"].as<const char*>());
  if (j["rating"].is<const char*>()) {
    job.rating = -1;  // "clear"
  } else if (!j["rating"].isNull()) {
    job.rating = static_cast<int8_t>(j["rating"].as<int>());
  }
  job.statusSeen = parseServerStatus(j["statusSeen"].as<const char*>());
  job.attempts = j["attempts"] | 0;
  if (j["parked"] | false) job.flags |= FinishJob::PARKED;
  if (!j["retryIn"].isNull()) job.nextTryAt = now + j["retryIn"].as<uint32_t>();
  job.finalPermille = j["finalPermille"] | 0;
  job.pagesAtFinish = j["pagesAtFinish"] | 0;
  return job;
}

void drainCases(JsonDocument& doc) {
  const uint32_t now = doc["now"];
  const char* hash = doc["hash"];
  for (JsonObjectConst c : doc["cases"].as<JsonArrayConst>()) {
    const char* name = c["name"];
    FinishJob job = jobFrom(c["job"], hash, now);
    FixtureTransport transport(c["server"].as<JsonObjectConst>());
    DrainOptions options;
    options.now = now;
    options.manual = c["manual"] | false;
    options.knownHash = (c["hashKnown"] | false) ? hash : "";
    options.sendRatings = c["ratings"] | true;
    const DrainOutcome outcome = drainOne(job, transport, options);

    JsonObjectConst expect = c["expect"];
    std::vector<std::string> want;
    for (JsonVariantConst r : expect["requests"].as<JsonArrayConst>()) want.push_back(r.as<std::string>());
    CHECK_NAMED(name, transport.requests == want);
    if (transport.requests != want) {
      for (const auto& r : transport.requests) std::printf("    got:  %s\n", r.c_str());
      for (const auto& r : want) std::printf("    want: %s\n", r.c_str());
    }
    CHECK_NAMED(name, strcmp(drainOutcomeName(outcome), expect["outcome"].as<const char*>()) == 0);
    if (!expect["attempts"].isNull()) CHECK_NAMED(name, job.attempts == expect["attempts"].as<int>());
    if (!expect["retryIn"].isNull()) CHECK_NAMED(name, job.nextTryAt == now + expect["retryIn"].as<uint32_t>());
    if (!expect["bookId"].isNull()) CHECK_NAMED(name, job.bookId == expect["bookId"].as<int64_t>());
    if (outcome == DrainOutcome::Sent) CHECK_NAMED(name, job.sent() && !job.parked());
  }
}

void holdCases(JsonDocument& doc) {
  for (JsonObjectConst c : doc["holdCases"].as<JsonArrayConst>()) {
    FinishJob job;
    const bool hasJob = !c["job"].isNull();
    if (hasJob) job = jobFrom(c["job"], doc["hash"], 0);
    const bool held = holdAutomaticPush(hasJob ? &job : nullptr, c["finishedLocally"], c["pushPermille"].as<uint16_t>(),
                                        c["pagesTurned"].as<uint32_t>());
    CHECK_NAMED(c["name"].as<const char*>(), held == c["hold"].as<bool>());
  }
}

FinishJob sample(int i) {
  FinishJob j;
  snprintf(j.hash, sizeof(j.hash), "%032x", i + 1);
  j.bookId = 1000 + i;
  j.finishedOn = 20261100 + (i % 28) + 1;
  j.rating = static_cast<int8_t>(i % 6);
  j.statusSeen = ServerStatus::Reading;
  j.createdAt = 1795377600u + i;
  j.finalPermille = 1000;
  j.pagesAtFinish = 77u * i;
  return j;
}

void queueTests() {
  FinishQueue q;
  for (int i = 0; i < 3; i++) q.upsert(sample(i));
  CHECK(q.size() == 3 && q.pending() == 3);

  // Newest local intent wins: one job per book.
  FinishJob again = sample(1);
  again.rating = 5;
  q.upsert(again);
  CHECK(q.size() == 3 && q.find(again.hash)->rating == 5);

  // Undo forgets it.
  CHECK(q.remove(sample(0).hash));
  CHECK(!q.remove(sample(0).hash));
  CHECK(q.size() == 2 && q.find(sample(0).hash) == nullptr);

  // Round trip.
  uint8_t buf[FinishQueue::MAX_PAYLOAD_BYTES];
  const size_t n = q.serialize(buf, sizeof(buf));
  CHECK(n == FinishQueue::HEADER_BYTES + 2 * FinishQueue::RECORD_BYTES);
  FinishQueue back;
  CHECK(back.deserialize(buf, n));
  CHECK(back.size() == 2);
  const FinishJob* b = back.find(sample(2).hash);
  CHECK(b && b->bookId == 1002 && b->finishedOn == sample(2).finishedOn && b->pagesAtFinish == 154 &&
        b->statusSeen == ServerStatus::Reading && b->finalPermille == 1000);

  // Unknown versions and damaged records read as empty, never as garbage.
  buf[4] = 2;
  CHECK(!back.deserialize(buf, n) && back.size() == 0);
  buf[4] = 1;
  buf[FinishQueue::HEADER_BYTES] = 'Z';
  CHECK(!back.deserialize(buf, n));

  // A full queue drops its oldest sent job first, then its oldest.
  FinishQueue full;
  for (int i = 0; i < (int)FinishQueue::MAX_JOBS; i++) full.upsert(sample(i));
  full.at(5).flags = FinishJob::SENT;
  full.upsert(sample(100));
  CHECK(full.size() == FinishQueue::MAX_JOBS && full.find(sample(5).hash) == nullptr && full.find(sample(0).hash));
  full.upsert(sample(101));
  CHECK(full.size() == FinishQueue::MAX_JOBS && full.find(sample(0).hash) == nullptr);
  CHECK(full.serialize(buf, sizeof(buf)) == FinishQueue::MAX_PAYLOAD_BYTES);
}

// Two slot files, each save overwriting the older one: a write torn at any byte leaves the
// newest complete save readable.
void tornWriteTests() {
  FinishQueue q;
  for (int i = 0; i < 4; i++) q.upsert(sample(i));
  uint8_t payload[FinishQueue::MAX_PAYLOAD_BYTES];
  const size_t n = q.serialize(payload, sizeof(payload));
  uint8_t slotA[FinishQueue::MAX_PAYLOAD_BYTES + slot::TRAILER_BYTES];
  const size_t a = slot::encode(payload, n, 7, slotA, sizeof(slotA));
  CHECK(a == n + slot::TRAILER_BYTES);

  q.upsert(sample(9));
  uint8_t payload2[FinishQueue::MAX_PAYLOAD_BYTES];
  const size_t n2 = q.serialize(payload2, sizeof(payload2));
  uint8_t slotB[FinishQueue::MAX_PAYLOAD_BYTES + slot::TRAILER_BYTES];
  const size_t b = slot::encode(payload2, n2, 8, slotB, sizeof(slotB));

  int failures = 0;
  for (size_t cut = 0; cut < b; cut++) {
    // Slot B is torn after `cut` bytes, over whatever it held before (zeros here).
    uint8_t torn[sizeof(slotB)] = {};
    memcpy(torn, slotB, cut);
    uint32_t seqA = 0, seqB = 0;
    const size_t pa = slot::decode(slotA, a, seqA);
    const size_t pb = slot::decode(torn, b, seqB);
    FinishQueue got;
    // The newest valid slot wins.
    const bool useB = pb && (!pa || seqB > seqA);
    const bool okRead = useB ? got.deserialize(torn, pb) : got.deserialize(slotA, pa);
    if (!okRead || (got.size() != 4 && got.size() != 5)) failures++;
  }
  CHECK(failures == 0);
  uint32_t seq = 0;
  CHECK(slot::decode(slotB, b, seq) == n2 && seq == 8);
  slotB[3] ^= 1;
  CHECK(slot::decode(slotB, b, seq) == 0);
}

void dayTests() {
  CHECK(parseDay("2026-11-22") == 20261122);
  CHECK(parseDay("2026-13-01") == 0 && parseDay("") == 0 && parseDay(nullptr) == 0 && parseDay("1970-01-01") == 0);
  char out[11];
  CHECK(formatDay(20260105, out) && strcmp(out, "2026-01-05") == 0);
  CHECK(!formatDay(0, out));
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s shared/fixtures/bookorbit/finish-cases.json\n", argv[0]);
    return 2;
  }
  JsonDocument doc;
  if (!loadJsonFile(argv[1], doc)) return 2;
  drainCases(doc);
  holdCases(doc);
  queueTests();
  tornWriteTests();
  dayTests();
  return report("finish");
}
