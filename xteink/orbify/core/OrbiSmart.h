#pragma once
// BookSync OrbiSmart sync (docs/design/position-sync.md §3): which way a book's place moves, when a
// move is shown, and whether a push may go. OrbiSmartSync wires this pure policy into the
// reader, background task and sleep sync. The table is
// shared/fixtures/orbismart/cases.json, which Android's logic/orbismart.lua runs too
// (xteink/test/orbismart_test.cpp).
#include <cstddef>
#include <cstdint>

namespace orbify::orbismart {

constexpr int64_t SKEW_S = 600;  // rule 6: R dated this far after the last turn here was deliberate

enum class Decision : uint8_t {
  Same,      // both at one place: refresh the marker
  Take,      // move forward to R
  Follow,    // move back to R (a reset, or an override elsewhere)
  Push,      // send L
  Hold,      // keep L, no push, no move (finished book, end-of-book hold)
  Stay,      // keep L, no push, no move (the reader declined this remote place)
  Override,  // send L, skipping the behind-hold once
};

enum class Rule : uint8_t { Rule1, Rule2, Rule3, Rule4, Rule5, Rule6, Rule7, Declined, Override, Percent, NoServer };

// When a move is shown, by the moment it was found (ruling 1).
enum class Moment : uint8_t { Prerender, Open, Wake, Reading, Pause, Sleep, Manual, Close };
enum class Applied : uint8_t {
  Now,   // silently, before the page rendered
  Ask,   // the Yes / No popup
  Wake,  // asked at the next wake
  No,    // nothing to show
};

// Places are in local pages (a linear page ordinal on the Xteink; percent when percentOnly).
struct Input {
  double local = 0;           // L
  bool hasServer = false;     // the server has a place
  double server = 0;          // R, mapped to local pages
  double tolerance = 1;       // same place within this (1 page; 2 for percent-only)
  int64_t serverAt = 0;       // R's server timestamp
  bool hasMarker = false;     // M: this device's last sync of the book
  int64_t markerAt = 0;
  double markerPlace = 0;
  int64_t turnAt = 0;         // this device's last page turn, 0 = none
  bool reset = false;         // R is BookOrbit's reset
  bool redated = false;       // R was only re-dated (BookOrbitSmartSync::onlyRedated)
  bool finished = false;      // the book is finished (server or here)
  bool released = false;      // the end-of-book hold is released (reread)
  int64_t declinedAt = 0;     // serverAt of the place the reader answered No to, 0 = none
  bool hasOverride = false;   // a queued "Read from here everywhere"
  int64_t overrideAt = 0;
  bool percentOnly = false;   // R has no position
};

struct Result {
  Decision decision = Decision::Same;
  Rule rule = Rule::Rule1;
  bool dropped = false;  // a queued override was dropped (reading elsewhere came after it)
};

Result decide(const Input& in);
Applied apply(Decision decision, Moment moment);
// The behind-hold: false when place is behind the last known server place (exempt: an override
// or a released reread).
bool mayPush(double place, bool hasServer, double server, double tolerance, bool exempt);

// "orbismart: rule3 L=120 R=214 -> take (open, ask)". Returns the length written (NUL-terminated).
size_t formatLine(const Input& in, const Result& r, Moment moment, char* out, size_t capacity);

// The fixture's names; false when unknown.
const char* decisionName(Decision d);
const char* ruleName(Rule r);
const char* momentName(Moment m);
const char* appliedName(Applied a);
bool decisionFromName(const char* name, Decision& out);
bool momentFromName(const char* name, Moment& out);

}  // namespace orbify::orbismart
