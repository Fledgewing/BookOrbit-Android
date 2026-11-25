#include "OrbiSmart.h"

#include <cstdio>
#include <cstring>

namespace orbify::orbismart {

namespace {
double absd(const double x) { return x < 0 ? -x : x; }

Result make(const Decision d, const Rule r, const bool dropped) {
  Result out;
  out.decision = d;
  out.rule = r;
  out.dropped = dropped;
  return out;
}

const char* const DECISIONS[] = {"same", "take", "follow", "push", "hold", "stay", "override"};
const char* const RULES[] = {"rule1",    "rule2",    "rule3",   "rule4",    "rule5",    "rule6",
                             "rule7",    "declined", "override", "percent", "no-server"};
const char* const MOMENTS[] = {"prerender", "open", "wake", "reading", "pause", "sleep", "manual", "close"};
const char* const APPLIED[] = {"now", "ask", "wake", "no"};
}  // namespace

Result decide(const Input& in) {
  const double L = in.local;
  const double R = in.server;
  const bool moved = in.hasMarker && in.hasServer && in.serverAt != in.markerAt && !in.redated;
  bool dropped = false;
  // A queued "Read from here everywhere" goes first, unless reading elsewhere came after it.
  if (in.hasOverride) {
    if (moved && in.serverAt > in.overrideAt) {
      dropped = true;
    } else {
      return make(Decision::Override, Rule::Override, false);
    }
  }
  if (!in.hasServer) return make(Decision::Push, Rule::NoServer, dropped);
  const bool declined = in.declinedAt != 0 && in.declinedAt == in.serverAt;
  auto move = [&](const Decision d, const Rule r) {
    return declined ? make(Decision::Stay, Rule::Declined, dropped) : make(d, r, dropped);
  };
  if (absd(L - R) <= in.tolerance) return make(Decision::Same, Rule::Rule1, dropped);
  if (in.reset) return move(Decision::Follow, Rule::Rule2);
  if (in.finished && L < R) return make(in.released ? Decision::Push : Decision::Hold, Rule::Rule7, dropped);
  if (R > L) return move(Decision::Take, Rule::Rule3);
  // L is further.
  if (!moved) return make(Decision::Push, Rule::Rule4, dropped);
  if (in.percentOnly) return make(Decision::Push, Rule::Percent, dropped);
  const bool readHere = absd(L - in.markerPlace) > in.tolerance;
  if (!readHere) return move(Decision::Follow, Rule::Rule5);
  if (in.serverAt > in.turnAt + SKEW_S) return move(Decision::Follow, Rule::Rule6);
  return make(Decision::Push, Rule::Rule6, dropped);
}

Applied apply(const Decision decision, const Moment moment) {
  if (decision != Decision::Take && decision != Decision::Follow) return Applied::No;
  switch (moment) {
    case Moment::Prerender:
      return Applied::Now;
    case Moment::Sleep:
      return Applied::Wake;
    case Moment::Close:
      return Applied::No;
    default:
      return Applied::Ask;
  }
}

bool mayPush(const double place, const bool hasServer, const double server, const double tolerance,
             const bool exempt) {
  if (exempt || !hasServer) return true;
  return place >= server - tolerance;
}

size_t formatLine(const Input& in, const Result& r, const Moment moment, char* out, const size_t capacity) {
  if (!out || capacity == 0) return 0;
  char server[24];
  if (in.hasServer) {
    std::snprintf(server, sizeof(server), "%g", in.server);
  } else {
    std::snprintf(server, sizeof(server), "none");
  }
  const int n = std::snprintf(out, capacity, "orbismart: %s%s L=%g R=%s -> %s (%s, %s)",
                              r.dropped ? "override-dropped " : "", ruleName(r.rule), in.local, server,
                              decisionName(r.decision), momentName(moment), appliedName(apply(r.decision, moment)));
  if (n < 0) {
    out[0] = '\0';
    return 0;
  }
  return static_cast<size_t>(n) < capacity ? static_cast<size_t>(n) : capacity - 1;
}

const char* decisionName(const Decision d) { return DECISIONS[static_cast<int>(d)]; }
const char* ruleName(const Rule r) { return RULES[static_cast<int>(r)]; }
const char* momentName(const Moment m) { return MOMENTS[static_cast<int>(m)]; }
const char* appliedName(const Applied a) { return APPLIED[static_cast<int>(a)]; }

bool decisionFromName(const char* name, Decision& out) {
  if (!name) return false;
  for (size_t i = 0; i < sizeof(DECISIONS) / sizeof(DECISIONS[0]); i++) {
    if (std::strcmp(DECISIONS[i], name) == 0) {
      out = static_cast<Decision>(i);
      return true;
    }
  }
  return false;
}

bool momentFromName(const char* name, Moment& out) {
  if (!name) return false;
  for (size_t i = 0; i < sizeof(MOMENTS) / sizeof(MOMENTS[0]); i++) {
    if (std::strcmp(MOMENTS[i], name) == 0) {
      out = static_cast<Moment>(i);
      return true;
    }
  }
  return false;
}

}  // namespace orbify::orbismart
