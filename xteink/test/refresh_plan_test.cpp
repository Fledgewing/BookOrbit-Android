// SPDX-License-Identifier: GPL-3.0-or-later
#include "RefreshPlan.h"
#include "TestSupport.h"
#include <array>
#include <set>
#include <vector>
using namespace orbify::mirror;
struct MemoryJournal final : Journal {
  struct Row { Step step; int page; };
  std::array<std::vector<Row>, 3> rows;
  bool healthy = true;
  bool append(unsigned lane, const Step& s, int p) override { rows[lane].push_back({s, p}); return true; }
  bool read(unsigned lane, size_t offset, Step& s, int& p, size_t& next) override {
    if (offset >= rows[lane].size()) return false;
    const auto& row = rows[lane][offset]; s=row.step; p=row.page; next=offset+1; return true;
  }
  size_t count(unsigned lane) override { return rows[lane].size(); }
  bool contains(unsigned lane, const Step& s, int p) override {
    for (const auto& r : rows[lane]) if (r.step.kind==s.kind && r.step.arg==s.arg && r.page==p) return true;
    return false;
  }
  bool good() const override { return healthy; }
};
int main() {
  MemoryJournal journal;
  RefreshPlan plan(journal);
  plan.add(Kind::Root, "");
  Step step; int page;
  CHECK(plan.next(step,page) && step.kind==Kind::Root);
  for (const char* section : {"authors","series","collections","libraries","smart-scopes"})
    for (int n=1; n<=3; ++n) plan.add(Kind::Section, section, n);
  // 1,030 book pages exceed the old 150-step cap, and every facet's 30 rows
  // exceed the former per-facet cap. Only one response's rows exist in the walker.
  plan.expectDetails(10300);
  for (int list=0; list<150; ++list) {
    plan.add(Kind::Books,std::to_string(list));
    for (int n=2;n<=8;++n) plan.add(Kind::Books,std::to_string(list),n,true);
  }
  plan.advance();
  const size_t fixed = plan.total();
  unsigned previous=0;
  size_t ran=1;
  while (plan.next(step,page)) {
    if (step.kind==Kind::Books) {
      const size_t id=ran%10300;
      plan.add(Kind::Detail,std::to_string(id));
      CHECK(!plan.add(Kind::Detail,std::to_string(id))); // repeated across lists
      CHECK(plan.total()==fixed);
    }
    if (ran==170) {
      RefreshPlan resume(journal);
      CHECK(resume.restore(plan.checkpoint()));
      CHECK(resume.doneCount()==plan.doneCount());
      CHECK(resume.percent()==plan.percent());
    }
    plan.advance(); ++ran;
    CHECK(plan.percent()>=previous); previous=plan.percent();
  }
  CHECK(plan.finished() && plan.percent()==100);
  CHECK(journal.count(0)==166 && journal.count(1)==1050);
  CHECK(ran==plan.doneCount());
  const uint64_t MB=1024*1024;
  CHECK(budget(249*MB,0,2*MB,250*MB,1000*MB)==Stop::StorageLimit);
  CHECK(budget(250*MB,2*MB,MB,250*MB,1000*MB)==Stop::None); // replacement, not growth
  CHECK(budget(10240*MB,0,MB,0,1000*MB)==Stop::None); // unlimited, no uint32 overflow
  CHECK(budget(0,0,1,250*MB,SD_MARGIN)==Stop::SdFull);
  CHECK(budget(0,0,0,0,SD_MARGIN-1)==Stop::SdFull);
  CHECK(stopText(Stop::StorageLimit,150,12000)=="Stopped at storage limit: 150 of 12000 saved — raise it in Settings");
  CHECK(stopText(Stop::SdFull,9,200).find("SD card full")!=std::string::npos);
  journal.healthy=false;
  CHECK(!journal.good());
  return report("refresh_plan");
}
