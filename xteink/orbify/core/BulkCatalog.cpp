// SPDX-License-Identifier: GPL-3.0-or-later
#if __has_include(<CrossInkTailnetCuts.h>)
#include <CrossInkTailnetCuts.h>
#define ORBIFY_BULK_AVAILABLE CROSSINK_TAILNET_ORBIFY_MIRROR
#else
#define ORBIFY_BULK_AVAILABLE 1
#endif
#if ORBIFY_BULK_AVAILABLE
#include "BulkCatalog.h"
#include "BulkRefresh.h"
#include "CatalogCache.h"
#include <cctype>
#include <cstring>
#include <map>
#include <set>

namespace orbify::bulk {
namespace {
struct DefaultArena final : ArduinoJson::Allocator {
  void* allocate(size_t n) override {return std::malloc(n);}
  void deallocate(void* p) override {std::free(p);}
  void* reallocate(void* p,size_t n) override {return std::realloc(p,n);}
};
DefaultArena defaultArena;
const std::string BASE = "/plugin/catalog";
std::string leaf(int64_t id) {return std::to_string(static_cast<uint64_t>(id)&255)+"/"+std::to_string(id);}
std::string text(JsonVariantConst v) { return v.is<const char*>() ? v.as<std::string>() : v.isNull() ? "" : v.as<std::string>(); }
std::map<std::string,std::string> query(const std::string& url) {
  std::map<std::string,std::string> out;
  auto start = url.find('?');
  if(start == std::string::npos) return out;
  auto decode=[](const std::string& s) {
    std::string out;
    for(size_t i=0;i<s.size();++i) {
      if(s[i]=='%' && i+2<s.size() && std::isxdigit(s[i+1]) && std::isxdigit(s[i+2])) {
        out += static_cast<char>(strtoul(s.substr(i+1,2).c_str(),nullptr,16)); i+=2;
      } else out += s[i]=='+' ? ' ' : s[i];
    }
    return out;
  };
  while(++start < url.size()) {
    const auto end=url.find('&',start); const auto pair=url.substr(start,end-start); const auto eq=pair.find('=');
    out[decode(pair.substr(0,eq))]=eq==std::string::npos?"":decode(pair.substr(eq+1));
    if(end==std::string::npos) break;
    start=end;
  }
  return out;
}
std::string direction(const std::string& sort) { return sort=="recently_added" || sort=="recently_read" || sort=="recently_updated" ? "desc" : "asc"; }
}
std::string encode(const std::string& value) {
  constexpr char hex[]="0123456789ABCDEF"; std::string out;
  for(unsigned char c:value) {
    if(std::isalnum(c)||c=='-'||c=='_'||c=='.'||c=='~') out+=c;
    else {out+='%';out+=hex[c>>4];out+=hex[c&15];}
  }
  return out;
}
namespace {
struct SeriesKey {
  int64_t id; bool missing; double major, minor;
  std::string index; size_t title;
};
bool seriesLess(const SeriesKey& a,const SeriesKey& b,bool desc) {
  if(a.missing!=b.missing)return !a.missing;
  if(a.major!=b.major)return desc?a.major>b.major:a.major<b.major;
  if(a.minor!=b.minor)return desc?a.minor>b.minor:a.minor<b.minor;
  if(a.index!=b.index)return desc?a.index>b.index:a.index<b.index;
  return a.title!=b.title?a.title<b.title:a.id<b.id;
}
SeriesKey seriesKey(int64_t id,JsonVariantConst row,size_t title) {
  const std::string ix=text(row["seriesIndex"]);const auto dot=ix.find('.');
  return {id,row["seriesIndex"].isNull(),strtod(ix.substr(0,dot).c_str(),nullptr),dot==std::string::npos?-1:strtod(ix.substr(dot+1).c_str(),nullptr),ix,title};
}
}
Catalog::Catalog(Files& files, ArduinoJson::Allocator* a):fs(files),arena(a?a:&defaultArena),ids(IndexAllocator<int64_t>(a?a:&defaultArena)) {}
std::string Catalog::root(const std::string& gen) const {return "bulk/"+(gen.empty()?generation:gen)+"/";}
std::string Catalog::record(int64_t id,const std::string& gen) const {return root(gen)+"books/"+leaf(id)+".json";}
bool Catalog::save(const std::string& path,JsonVariantConst value) {return fs.writeJson(path,value);}
bool Catalog::load(const std::string& path,JsonDocument& out) {return fs.readJson(path,out);}
bool Catalog::readIds(const std::string& path,Ids& out) {
  if(!fs.exists(path)||fs.size(path)%sizeof(int64_t))return false;
  if(!fs.room(fs.size(path))){error="PSRAM budget";return false;}
  out.resize(fs.size(path)/sizeof(int64_t));return fs.readIds(path,out.data(),out.size()*sizeof(int64_t));
}
bool Catalog::writeIds(const std::string& path,const Ids& values) {
  return fs.writeBytes(path,values.data(),values.size()*sizeof(int64_t));
}
bool Catalog::book(int64_t id,JsonDocument& out,const std::string& gen) {return load(record(id,gen),out);}
bool Catalog::active() const {return fs.exists("bulk/active");}
void Catalog::tick(unsigned n) {shown=std::max(shown,std::min(99u,n));progress(shown);}
bool Catalog::ask(const std::string& path,JsonDocument& out) {
  if(cancelled()) {error="cancelled";return false;}
  out.clear();++stats.requests;
  if(!fetch(path,out)) {error="network";return false;}
  const size_t bytes=measureJson(out);stats.bytes+=bytes;stats.peakPageBytes=std::max(stats.peakPageBytes,bytes);
  stats.peakJsonBytes=std::max(stats.peakJsonBytes,out.size()*sizeof(JsonVariant));
  if(out.overflowed()){error="parser allocation";return false;}return true;
}
bool Catalog::pages(const std::string& endpoint,const std::string& q,const std::string& key,
                    const std::function<bool(JsonObjectConst,size_t)>& row) {
  for(size_t page=1;;++page) {
    const auto marker=root()+"pages/"+encode(key)+"/"+std::to_string(page);
    JsonDocument body(arena);
    if(!load(marker,body)) {
      if(!ask(BASE+endpoint+"?"+q+(q.empty()?"":"&")+"size=100&page="+std::to_string(page),body))return false;
    }
    auto items=body["items"].as<JsonArrayConst>();
    if(items.isNull()) {error="items missing";return false;}
    const size_t total=body["total"]|items.size();
    if(items.size()==0 && (page-1)*100<total) {error="incomplete page";return false;}
    const size_t pageSize=body["size"]|size_t(100);
    if(!pageSize||pageSize>100){error="invalid page size";return false;}
    size_t pos=(page-1)*pageSize;
    for(JsonObjectConst item:items)if(cancelled()||!row(item,pos++))return false;
    // Page data and idempotent rows are durable before a completed page is reused.
    if(endpoint=="/books") {
      const bool seriesContext=key.find("seriesId:")==0||key.find("series:")==0;
      for(JsonObject item:body["items"].as<JsonArray>()) {
        JsonDocument compact(arena);compact["id"].set(item["id"]);
        if(seriesContext)for(const char* field:{"seriesId","seriesName","seriesIndex"})compact[field].set(item[field]);
        item.set(compact.as<JsonObjectConst>());
      }
    }
    if(!save(marker,body.as<JsonVariantConst>()))return false;
    if(page*pageSize>=total && body["hasNext"]!=true)return true;
  }
}
bool Catalog::manifest() {
  ManifestCursor cursor;
  JsonDocument checkpoint(arena);
  if(load(root()+"manifest.state",checkpoint)) {
    cursor.cursor=checkpoint["cursor"]|"";cursor.complete=checkpoint["complete"]|false;
    cursor.restarts=checkpoint["restarts"]|0;
    if(!readIds(root()+"ids",ids))return false;
  }
  if(cursor.complete){stats.rows=ids.size();return true;}
  while(!cursor.complete) {
    JsonDocument page(arena);
    if(!ask(BASE+"/manifest?size=200"+(cursor.cursor.empty()?"":"&cursor="+encode(cursor.cursor)),page))return false;
    const auto next=page["nextCursor"].as<std::string>();
    if(!next.empty() && fs.exists(root()+"cursors/"+encode(next))) {error="manifest cursor loop";return false;}
    if(!cursor.accept(page.as<JsonVariantConst>(),error))return false;
    if(page["restartRequired"]==true) {
      if(!fs.erase(root()))return false;
      ids.clear();if(!writeIds(root()+"ids",ids))return false;
    } else {
      for(JsonObjectConst row:page["items"].as<JsonArrayConst>()) {
        const int64_t id=row["id"]|int64_t(0);
        if(id<=0) {error="invalid book id";return false;}
        // The manifest body is retained separately for exact incremental comparison.
        if(!save(root()+"manifest/"+leaf(id),row)||!save(record(id),row))return false;
        if(!fs.room(2*(ids.size()+1)*sizeof(int64_t))){error="PSRAM budget";return false;}
        ids.push_back(id);
      }
      std::sort(ids.begin(),ids.end());ids.erase(std::unique(ids.begin(),ids.end()),ids.end());
      if(!writeIds(root()+"ids",ids))return false;
      if(!next.empty()&&!fs.write(root()+"cursors/"+encode(next),"1"))return false;
    }
    checkpoint["cursor"]=cursor.cursor;checkpoint["complete"]=cursor.complete;checkpoint["restarts"]=cursor.restarts;
    if(!save(root()+"manifest.state",checkpoint.as<JsonVariantConst>()))return false;
  }
  stats.rows=ids.size();return true;
}
bool Catalog::rich(JsonObjectConst row, bool freshState) {
  const int64_t id=row["id"]|int64_t(0);
  if(!std::binary_search(ids.begin(),ids.end(),id)) {error="catalog changed during enumeration";return false;}
  const auto marker=root()+"rich/"+leaf(id);
  const bool hydrated=fs.exists(marker);
  if(hydrated&&(!freshState||row.size()==1))return true;  // compact durable page replay
  JsonDocument body(arena);
  if(!book(id,body))return false;
  bool changed=false;
  for(const char* key:{"seriesId","progressPercentage","lastReadAt","readStatus","addedAt","updatedAt","hasCover","thumbnailUrl","detailUrl"}) {
    if(body[key]!=row[key]){body[key].set(row[key]);changed=true;}
  }
  return (!changed||save(record(id),body.as<JsonVariantConst>()))&&(hydrated||fs.write(marker,"1"));
}
bool Catalog::metadata() {
  for(const char* section:{"libraries","collections","smart-scopes","authors","series"}) {
    if(!pages(std::string("/sections/")+section,"",std::string("section:")+section,[&](JsonObjectConst row,size_t pos){
      if(std::string(section)=="series" && !row["seriesId"].isNull() && !members("series-name-ids:"+text(row["title"]),row["seriesId"].as<int64_t>()))return false;
      return save(root()+"sections/"+section+"/"+std::to_string(pos),row) &&
        fs.write(root()+"section-pos/"+section+"/"+encode(text(row["id"])),std::to_string(pos));
    }))return false;
  }
  for(const char* section:{"authors","series"}) {
    Ids positions{IndexAllocator<int64_t>(arena)};
    if(!pages(std::string("/sections/")+section,"sort=name_desc",std::string("section-desc:")+section,[&](JsonObjectConst row,size_t){
      std::string pos;if(!fs.read(root()+"section-pos/"+section+"/"+encode(text(row["id"])),pos))return false;
      positions.push_back(strtoll(pos.c_str(),nullptr,10));return true;
    })||!writeIds(root()+"section-ranks/"+section+":name_desc",positions))return false;
  }
  for(const char* entry:{"/root","/dashboard","/dashboard/discover","/dashboard/sections/want-to-read","/dashboard/sections/up-next-in-series"}) {
    const auto path=root()+"entries/"+encode(entry);if(fs.exists(path))continue;
    JsonDocument doc(arena);if(!ask(BASE+entry,doc))return false;
    if(!manualRun&&!previous.empty()) {
      JsonDocument prior(arena);
      if(load(root(previous)+"entries/"+encode(entry),prior)&&!prior["discover"].isNull())doc["discover"].set(prior["discover"]);
    }
    if(!save(path,doc.as<JsonVariantConst>()))return false;
  }
  return true;
}
bool Catalog::members(const std::string& key,int64_t id) {
  Ids values{IndexAllocator<int64_t>(arena)};const auto path=root()+"members/"+encode(key);
  if(fs.exists(path)&&!readIds(path,values)){error="SD read error";return false;}
  // Membership append is idempotent across interrupted page replay.
  auto at=std::lower_bound(values.begin(),values.end(),id);
  if(at==values.end()||*at!=id) {
    if(!fs.room(2*(values.size()+1)*sizeof(int64_t))){error="PSRAM budget";return false;}
    values.insert(at,id);
  }
  return writeIds(path,values);
}
bool Catalog::sources() {
  for(const auto& s:std::vector<std::pair<std::string,std::string>>{{"libraries","libraryId"},{"collections","collectionId"},{"smart-scopes","smartScopeId"}}) {
    for(size_t n=0;;++n) {
      JsonDocument entry(arena);const auto entryPath=root()+"sections/"+s.first+"/"+std::to_string(n);
      if(!fs.exists(entryPath))break;if(!load(entryPath,entry)){error="SD read error";return false;}
      const auto value=text(entry["id"]);
      if(!pages("/books",s.second+"="+encode(value),s.second+":"+value,[&](JsonObjectConst row,size_t){
        return rich(row)&&members(s.second+":"+value,row["id"].as<int64_t>());
      }))return false;
    }
  }
  // Each global sequence is a server rank; no assumptions about database
  // collation, hidden primary-author keys or descending NULL/tie behavior.
  for(const char* sort:{"recently_added","recently_read","recently_updated","title","author","series","published"})for(const char* order:{"asc","desc"}) {
    Ids rank{IndexAllocator<int64_t>(arena)};
    if(!pages("/books",std::string("sort=")+sort+"&order="+order+"&buckets=1",std::string(sort)+":"+order,[&](JsonObjectConst row,size_t){
      if(!fs.room(2*(rank.size()+1)*sizeof(int64_t))){error="PSRAM budget";return false;}
      rank.push_back(row["id"].as<int64_t>());return rich(row);
    }))return false;
    if(!writeIds(root()+"ranks/"+sort+":"+order,rank))return false;
  }
  // Dynamic read-state must be refreshed even if manifest files did not change.
  for(const char* state:{"reading","finished","unread"}) {
    Ids values{IndexAllocator<int64_t>(arena)};
    if(!pages("/books",std::string("sort=recently_read&readStatus=")+state,std::string("status:")+state,[&](JsonObjectConst row,size_t){
      if(!fs.room(2*(values.size()+1)*sizeof(int64_t))){error="PSRAM budget";return false;}
    values.push_back(row["id"].as<int64_t>());return rich(row,true);
    }))return false;
    std::sort(values.begin(),values.end());
    if(!writeIds(root()+"members/"+encode(std::string("status:")+state),values))return false;
  }
  // Only remaining unhydrated manifest IDs use ids[] batches.
  Ids missing{IndexAllocator<int64_t>(arena)};
  for(int64_t id:ids)if(!fs.exists(root()+"rich/"+leaf(id)))missing.push_back(id);
  for(size_t i=0;i<missing.size();i+=100) {
    std::string q;
    for(size_t n=i;n<std::min(i+100,missing.size());++n)q+=(q.empty()?"":",")+std::to_string(missing[n]);
    JsonDocument doc(arena);if(!ask(BASE+"/books?size=100&ids="+q,doc))return false;
    for(JsonObjectConst row:doc["items"].as<JsonArrayConst>())if(!rich(row))return false;
    for(size_t n=i;n<std::min(i+100,missing.size());++n)if(!fs.exists(root()+"rich/"+leaf(missing[n]))) {
      const auto it=std::lower_bound(ids.begin(),ids.end(),missing[n]);if(it!=ids.end()&&*it==missing[n])ids.erase(it);
      if(!fs.erase(record(missing[n]))||!fs.erase(root()+"manifest/"+leaf(missing[n])))return false;
    }
  }
  return writeIds(root()+"ids",ids);
}
bool Catalog::derive() {
  // Rebuild only deterministic local memberships. Scoped server sets stay intact.
  for(int64_t id:ids) {
    if(cancelled())return false;
    JsonDocument row(arena);if(!book(id,row))return false;
    for(JsonVariantConst a:row["authors"].as<JsonArrayConst>())if(!members("author:"+text(a),id))return false;
    for(JsonVariantConst f:row["formats"].as<JsonArrayConst>())if(!members("format:"+text(f),id))return false;
    if(!row["seriesId"].isNull()&&!members("seriesId:"+text(row["seriesId"]),id))return false;
    if(!row["seriesName"].isNull()&&!members("series:"+text(row["seriesName"]),id))return false;
  }
  return true;
}
bool Catalog::secondary() {
  for(size_t n=0;;++n) {
    JsonDocument entry(arena);const auto entryPath=root()+"sections/series/"+std::to_string(n);
    if(!fs.exists(entryPath))break;if(!load(entryPath,entry)){error="SD read error";return false;}
    const std::string value=text(entry["seriesId"].isNull()?entry["id"]:entry["seriesId"]);
    const auto key="seriesId:"+value;Ids primary{IndexAllocator<int64_t>(arena)};readIds(root()+"members/"+encode(key),primary);
    const size_t total=entry["count"]|size_t(0);
    if(!needsSecondary(primary.size(),total))continue;
    bool unchanged=!previous.empty();Ids saved{IndexAllocator<int64_t>(arena)};
    unchanged=unchanged&&readIds(root(previous)+"secondary/"+encode(key)+"/ids",saved)&&saved.size()==total;
    if(unchanged) {
      // A membership replacement advances updatedAt, even when files and the
      // primary series did not change. Compare old/new record state as well as
      // exact manifest records for every known old/primary member.
      Ids affected=primary;affected.insert(affected.end(),saved.begin(),saved.end());
      for(int64_t id:affected) {
        JsonDocument a(arena),b(arena);std::string ma,mb;
        if(!book(id,a)||!book(id,b,previous)||text(a["updatedAt"])!=text(b["updatedAt"])||
           !fs.read(root()+"manifest/"+leaf(id),ma)||!fs.read(root(previous)+"manifest/"+leaf(id),mb)||ma!=mb){unchanged=false;break;}
      }
    }
    if(unchanged) {
      for(int64_t id:saved) {
        std::string s;if(!fs.read(root(previous)+"secondary/"+encode(key)+"/"+leaf(id),s)||!fs.write(root()+"secondary/"+encode(key)+"/"+leaf(id),s))return false;
      }
    } else {
      const auto before=stats.requests;saved.clear();
      if(!pages("/books","seriesId="+encode(value)+"&sort=series&order=asc",key,[&](JsonObjectConst row,size_t){
        const int64_t id=row["id"]|int64_t(0);
        if(!std::binary_search(ids.begin(),ids.end(),id))return false;
        saved.push_back(id);
        JsonDocument context(arena);for(const char* f:{"seriesId","seriesName","seriesIndex"})context[f].set(row[f]);
        return save(root()+"secondary/"+encode(key)+"/"+leaf(id),context.as<JsonVariantConst>());
      }))return false;
      stats.seriesRequests+=stats.requests-before;
      Ids unique=saved;std::sort(unique.begin(),unique.end());
      if(saved.size()!=total||std::adjacent_find(unique.begin(),unique.end())!=unique.end()){error="incomplete series";return false;}
    }
    // A complete contextual series replaces the primary set only at this point.
    if(!writeIds(root()+"secondary/"+encode(key)+"/ids",saved))return false;
    std::sort(saved.begin(),saved.end());
    if(!writeIds(root()+"members/"+encode(key),saved))return false;
  }
  return true;
}
bool Catalog::seriesNames() {
  for(size_t n=0;;++n) {
    const auto entryPath=root()+"sections/series/"+std::to_string(n);
    if(!fs.exists(entryPath))break;
    JsonDocument entry(arena);if(!load(entryPath,entry))return false;
    const auto name=text(entry["title"]),key="series:"+name;
    const auto marker=root()+"named/"+encode(name);
    if(fs.exists(marker))continue;
    Ids series{IndexAllocator<int64_t>(arena)},expected{IndexAllocator<int64_t>(arena)};
    if(!readIds(root()+"members/"+encode("series-name-ids:"+name),series))return false;
    for(int64_t sid:series) {
      Ids set{IndexAllocator<int64_t>(arena)};readIds(root()+"members/"+encode("seriesId:"+std::to_string(sid)),set);
      if(!fs.room(2*(expected.size()+set.size())*sizeof(int64_t))){error="PSRAM budget";return false;}
      expected.insert(expected.end(),set.begin(),set.end());
    }
    std::sort(expected.begin(),expected.end());expected.erase(std::unique(expected.begin(),expected.end()),expected.end());
    Ids selected=expected;
    if(series.size()!=1) {
      Ids oldSeries{IndexAllocator<int64_t>(arena)},oldNames{IndexAllocator<int64_t>(arena)};
      bool reuse=!previous.empty()&&fs.exists(root(previous)+"named/"+encode(name))&&
        readIds(root(previous)+"members/"+encode("series-name-ids:"+name),oldSeries)&&oldSeries==series&&
        readIds(root(previous)+"members/"+encode(key),oldNames)&&oldNames==expected;
      if(reuse)for(int64_t id:expected) {
        JsonDocument a(arena),b(arena);std::string ma,mb;
        if(!book(id,a)||!book(id,b,previous)||text(a["updatedAt"])!=text(b["updatedAt"])||
          !fs.read(root()+"manifest/"+leaf(id),ma)||!fs.read(root(previous)+"manifest/"+leaf(id),mb)||ma!=mb){reuse=false;break;}
      }
      if(reuse) {
        for(int64_t id:expected) {
          JsonDocument context(arena);if(!load(root(previous)+"secondary/"+encode(key)+"/"+leaf(id),context)||
            !save(root()+"secondary/"+encode(key)+"/"+leaf(id),context.as<JsonVariantConst>()))return false;
        }
      } else {
        const auto before=stats.requests;selected.clear();
        if(!pages("/books","series="+encode(name)+"&sort=series&order=asc",key,[&](JsonObjectConst row,size_t){
          const auto id=row["id"].as<int64_t>();
          if(!std::binary_search(ids.begin(),ids.end(),id)){error="catalog changed during enumeration";return false;}
          selected.push_back(id);JsonDocument context(arena);
          for(const char* field:{"seriesId","seriesName","seriesIndex"})context[field].set(row[field]);
          return save(root()+"secondary/"+encode(key)+"/"+leaf(id),context.as<JsonVariantConst>());
        }))return false;
        stats.seriesRequests+=stats.requests-before;
        std::sort(selected.begin(),selected.end());
        if(selected!=expected){error="incomplete series";return false;}
      }
    } else {
      const auto idKey="seriesId:"+std::to_string(series.front());
      for(int64_t id:expected) {
        JsonDocument context(arena);
        if(!load(root()+"secondary/"+encode(idKey)+"/"+leaf(id),context))continue;
        if(!save(root()+"secondary/"+encode(key)+"/"+leaf(id),context.as<JsonVariantConst>()))return false;
      }
    }
    if(!writeIds(root()+"members/"+encode(key),selected)||!fs.write(marker,"1"))return false;
  }
  return true;
}
bool Catalog::refresh(const std::string& owner,const Fetch& transport,const std::function<bool()>& cancel,
                      const std::function<void(unsigned)>& notify,bool fresh,bool manual) {
  fetch=transport;cancelled=cancel;progress=notify;identity=owner;manualRun=manual;stats={};error.clear();shown=0;
  std::string stageOwner;fs.read("bulk/active",previous);fs.read("bulk/stage-owner",stageOwner);
  if(!fresh&&stageOwner==owner&&fs.read("bulk/stage",generation)) {
    fs.read("bulk/stage-previous",previous);
    std::string p;if(fs.read(root()+"percent",p))shown=strtoul(p.c_str(),nullptr,10);
  } else {
    generation=previous=="a"?"b":"a";
    if(!fs.erase(root())||!fs.write("bulk/stage",generation)||!fs.write("bulk/stage-owner",owner)||!fs.write("bulk/stage-previous",previous)||!fs.write(root()+"at",std::to_string(fs.now())))return false;
  }
  auto run=[&] {
    if(!manifest())return false;tick(15);
    if(!metadata())return false;tick(20);
    if(!sources())return false;stats.rows=ids.size();tick(75);
    if(!derive()||!indexes())return false;tick(89);
    // Publish all base lists first. No completion stamp until later series succeeds.
    if(!fs.write("bulk/active",generation)||!fs.write("bulk/owner",owner))return false;tick(90);
    if(!secondary()||!seriesNames()||!indexes())return false;tick(99);
    if(cancelled()||!fs.write(root()+"complete","1"))return false;
    if(!fs.erase("bulk/stage")||!fs.erase("bulk/stage-owner")||!fs.erase("bulk/stage-previous"))return false;
    progress(100);return true;
  };
  const bool ok=run();
  if(!ok){fs.write(root()+"percent",std::to_string(shown));
    if(error=="catalog changed during enumeration" || error=="incomplete series") {fs.erase("bulk/stage");fs.erase("bulk/stage-owner");}
    if(error.empty())error=cancelled()?"cancelled":"SD write error";}
  return ok;
}
bool Catalog::indexes() {
  Ids titles{IndexAllocator<int64_t>(arena)};
  if(!readIds(root()+"ranks/title:asc",titles))return false;
  // Title ranks supply the server's collation/tie breaker without retaining titles.
  struct TitleRank {int64_t id;size_t rank;};
  std::vector<TitleRank,IndexAllocator<TitleRank>> titleRanks{IndexAllocator<TitleRank>(arena)};
  if(!fs.room(2*titles.size()*sizeof(TitleRank))){error="PSRAM budget";return false;}
  titleRanks.reserve(titles.size());
  for(size_t i=0;i<titles.size();++i)titleRanks.push_back({titles[i],i});
  std::sort(titleRanks.begin(),titleRanks.end(),[](const auto& a,const auto& b){return a.id<b.id;});
  auto titleRank=[&](int64_t id) {auto at=std::lower_bound(titleRanks.begin(),titleRanks.end(),id,[](const auto& a,int64_t b){return a.id<b;});return at==titleRanks.end()?size_t(-1):at->rank;};
  for(const char* section:{"libraries","collections","smart-scopes","authors","series"}) {
    Ids positions{IndexAllocator<int64_t>(arena)};
    for(size_t n=0;;++n) {
      JsonDocument row(arena);const auto entryPath=root()+"sections/"+section+"/"+std::to_string(n);
      if(!fs.exists(entryPath))break;if(!load(entryPath,row)){error="SD read error";return false;}
      positions.push_back(n);
      if(std::string(section)!="series")continue;
      for(const auto& key:{"seriesId:"+text(row["seriesId"].isNull()?row["id"]:row["seriesId"]),"series:"+text(row["title"])}) {
        Ids set{IndexAllocator<int64_t>(arena)};readIds(root()+"members/"+encode(key),set);
        std::vector<SeriesKey,IndexAllocator<SeriesKey>> keys{IndexAllocator<SeriesKey>(arena)};
        for(int64_t id:set) {
          if(cancelled()){error="cancelled";return false;}
          JsonDocument b(arena),ctx(arena);if(!book(id,b))return false;
          if(load(root()+"secondary/"+encode(key)+"/"+leaf(id),ctx))b["seriesIndex"].set(ctx["seriesIndex"]);
          if(!fs.room(2*(keys.size()+1)*sizeof(SeriesKey))){error="PSRAM budget";return false;}
          keys.push_back(seriesKey(id,b.as<JsonVariantConst>(),titleRank(id)));
        }
        for(const char* dir:{"asc","desc"}) {
          std::sort(keys.begin(),keys.end(),[&](const auto& a,const auto& b){return seriesLess(a,b,std::string(dir)=="desc");});
          set.clear();for(const auto& k:keys)set.push_back(k.id);
          if(!writeIds(root()+"series-ranks/"+encode(key)+":"+dir,set))return false;
        }
      }
    }
    if(!writeIds(root()+"section-ranks/"+section+":name_asc",positions))return false;
    if(std::string(section)!="authors"&&std::string(section)!="series") {
      std::reverse(positions.begin(),positions.end());if(!writeIds(root()+"section-ranks/"+section+":name_desc",positions))return false;
    }
    for(const char* field:{"count","readingCount","finishedCount","unreadCount"}) {
      struct Key {int64_t pos,count;};std::vector<Key,IndexAllocator<Key>> keys{IndexAllocator<Key>(arena)};
      for(int64_t pos:positions) {
        JsonDocument row(arena);if(!load(root()+"sections/"+section+"/"+std::to_string(pos),row))return false;
        const int64_t value=std::string(field)=="unreadCount" ? (row["count"]|int64_t(0))-(row["readingCount"]|int64_t(0))-(row["finishedCount"]|int64_t(0)) : row[field]|int64_t(0);
        keys.push_back({pos,value});
      }
      for(const char* dir:{"asc","desc"}) {
        std::sort(keys.begin(),keys.end(),[&](const auto& a,const auto& b){return a.count==b.count?a.pos<b.pos:std::string(dir)=="desc"?a.count>b.count:a.count<b.count;});
        Ids order{IndexAllocator<int64_t>(arena)};for(const auto& k:keys)order.push_back(k.pos);
        std::string name=std::string(field)=="count"?"count":std::string(field)=="readingCount"?"reading":std::string(field)=="finishedCount"?"finished":"unread";
        if(!writeIds(root()+"section-ranks/"+section+":"+name+"_"+dir,order))return false;
      }
    }
  }
  return true;
}
bool Catalog::recognizes(const std::string& requested) {
  const auto start=requested.find(BASE);if(start==std::string::npos)return false;
  const auto path=requested.substr(start+BASE.size(),requested.find('?',start)-start-BASE.size());
  auto q=query(requested);
  if(path=="/root"||path=="/dashboard"||path=="/dashboard/discover"||path=="/dashboard/sections/want-to-read"||path=="/dashboard/sections/up-next-in-series")return true;
  if(path.find("/books/")==0)return strtoll(path.substr(7).c_str(),nullptr,10)>0;
  if(path.find("/sections/")==0) {
    const auto section=path.substr(10);
    return (section=="authors"||section=="series"||section=="libraries"||section=="collections"||section=="smart-scopes") &&
      (q["sort"].empty()||q["sort"]=="name"||q["sort"]=="name_desc"||q["sort"]=="books") &&
      (q["filter"].empty()||q["filter"]=="reading"||q["filter"]=="finished");
  }
  const auto sort=q["sort"].empty()?"recently_added":q["sort"];
  return path=="/books"&&q["q"].empty()&&(q["order"].empty()||q["order"]=="asc"||q["order"]=="desc")&&
    (sort=="title"||sort=="author"||sort=="series"||sort=="published"||sort=="recently_read"||sort=="recently_added"||sort=="recently_updated");
}
bool Catalog::reply(const std::string& requested,JsonDocument& out) {
  if(!recognizes(requested))return false;
  if(!fs.read("bulk/active",generation))return false;
  const auto start=requested.find(BASE);if(start==std::string::npos)return false;
  const auto path=requested.substr(start+BASE.size(),requested.find('?',start)-start-BASE.size());
  auto q=query(requested);
  if(path=="/root"||path=="/dashboard"||path.find("/dashboard/")==0)return load(root()+"entries/"+encode(path),out);
  if(path.find("/books/")==0) {
    const auto id=strtoll(path.substr(7).c_str(),nullptr,10);return id>0&&book(id,out);
  }
  const size_t size=std::max(1,std::min(200,q["size"].empty()?20:atoi(q["size"].c_str())));
  const size_t page=std::max(1,q["page"].empty()?1:atoi(q["page"].c_str()));
  const size_t offset=q["offset"].empty()?(page-1)*size:strtoul(q["offset"].c_str(),nullptr,10);
  if(path.find("/sections/")==0) {
    const auto section=path.substr(10);
    if(section.find('/')!=std::string::npos)return false;
    // Stable source positions are the server's index order. Additional index
    // sort orders have their own compact position ranks, generated at refresh.
    Ids positions{IndexAllocator<int64_t>(arena)};
    const std::string sort=(q["sort"].empty()||q["sort"]=="name")?"name_asc":q["sort"]=="books"?"count_desc":q["sort"];
    if(!readIds(root()+"section-ranks/"+section+":"+sort,positions))return false;
    if(!q["filter"].empty()) {
      if(q["filter"]!="reading"&&q["filter"]!="finished")return false;
      Ids filtered{IndexAllocator<int64_t>(arena)};
      for(auto pos:positions){JsonDocument row(arena);if(!load(root()+"sections/"+section+"/"+std::to_string(pos),row))return false;if((row[(q["filter"]+"Count").c_str()]|0)>0)filtered.push_back(pos);}
      positions.swap(filtered);
    }
    out.clear();out["page"]=page;out["size"]=size;out["total"]=positions.size();out["hasNext"]=offset+size<positions.size();
    auto items=out["items"].to<JsonArray>();
    for(size_t i=offset;i<std::min(offset+size,positions.size());++i){JsonDocument row(arena);if(!load(root()+"sections/"+section+"/"+std::to_string(positions[i]),row))return false;items.add(row.as<JsonVariantConst>());}
    return !out.overflowed();
  }
  if(path!="/books"||!q["q"].empty())return false;
  const auto sort=q["sort"].empty()?"recently_added":q["sort"];
  const auto order=q["order"].empty()?direction(sort):q["order"];
  Ids rank{IndexAllocator<int64_t>(arena)};
  if(q["seriesId"].empty() && q["series"].find("series:")==0){q["seriesId"]=q["series"].substr(7);q.erase("series");}
  const bool smart=!q["smartScopeId"].empty();
  const std::string seriesKey=smart?"":!q["seriesId"].empty()?"seriesId:"+q["seriesId"]:!q["series"].empty()?"series:"+q["series"]:"";
  bool contextual=sort=="series"&&!seriesKey.empty();
  if(!readIds(root()+(contextual?"series-ranks/"+encode(seriesKey)+":"+order:"ranks/"+sort+":"+order),rank))return false;
  // Intersections operate only on numeric IDs. No rich row is decoded until it
  // belongs to the requested window.
  std::vector<Ids> filters;
  for(const char* field:{"author","seriesId","series","collectionId","smartScopeId","libraryId","format","readStatus"}) {
    if((smart&&std::string(field)!="smartScopeId") || q[field].empty() || (std::string(field)=="series"&&!q["seriesId"].empty()))continue;
    const std::string key=(std::string(field)=="readStatus"?"status":field)+std::string(":")+q[field];
    Ids set{IndexAllocator<int64_t>(arena)};
    readIds(root()+"members/"+encode(key),set);filters.push_back(std::move(set));
  }
  if(!smart&&!q["ids"].empty()) {
    Ids set{IndexAllocator<int64_t>(arena)};std::string values=q["ids"];size_t at=0;
    while(at<values.size()&&set.size()<200){auto end=values.find(',',at);set.push_back(strtoll(values.substr(at,end-at).c_str(),nullptr,10));if(end==std::string::npos)break;at=end+1;}
    std::sort(set.begin(),set.end());filters.push_back(std::move(set));
  }
  Ids selected{IndexAllocator<int64_t>(arena)};
  for(int64_t id:rank) {
    bool match=true;
    for(const auto& set:filters)if(!std::binary_search(set.begin(),set.end(),id)){match=false;break;}
    if(match){if(!fs.room(2*(selected.size()+1)*sizeof(int64_t)))return false;selected.push_back(id);}
  }
  out.clear();out["page"]=page;out["size"]=size;out["total"]=selected.size();out["hasNext"]=offset+size<selected.size();
  auto items=out["items"].to<JsonArray>();
  for(size_t i=offset;i<std::min(offset+size,selected.size());++i) {
    JsonDocument row(arena);if(!book(selected[i],row))return false;
    if(!seriesKey.empty()) {
      JsonDocument ctx(arena);
      if(load(root()+"secondary/"+encode(seriesKey)+"/"+leaf(selected[i]),ctx))
        for(const char* field:{"seriesId","seriesName","seriesIndex"})row[field].set(ctx[field]);
    }
    items.add(row.as<JsonVariantConst>());
  }
  if((sort=="title"||sort=="author")&&!q["buckets"].empty()) {
    JsonDocument first(arena);
    if(!load(root()+"pages/"+encode(sort+":"+order)+"/1",first))return false;
    auto buckets=out["buckets"].to<JsonArray>();
    size_t selectedAt=0;std::string last;
    for(size_t i=0;i<rank.size();++i) {
      if(selectedAt>=selected.size())break;
      if(rank[i]!=selected[selectedAt])continue;
      std::string letter="#";
      for(JsonObjectConst b:first["buckets"].as<JsonArrayConst>())if((b["index"]|size_t(0))<=i)letter=b["key"]|"#";
      if(letter!=last){auto b=buckets.add<JsonObject>();b["key"]=letter;b["index"]=selectedAt;last=letter;}
      ++selectedAt;
    }
  }
  return !out.overflowed();
}
bool Catalog::patch(int64_t id,JsonObjectConst fields) {
  if(!fs.read("bulk/active",generation))return false;
  JsonDocument row(arena);if(!book(id,row))return false;
  const auto before=status(row["readStatus"]|"");
  for(JsonPairConst f:fields)row[f.key()].set(f.value());
  const auto after=status(row["readStatus"]|"");
  if(!save(record(id),row.as<JsonVariantConst>()))return false;
  if(fields["readStatus"].isNull())return true;
  for(const char* group:{"unread","reading","finished"}) {
    Ids set{IndexAllocator<int64_t>(arena)};const auto path=root()+"members/"+encode(std::string("status:")+group);
    if(!readIds(path,set))return false;
    auto at=std::lower_bound(set.begin(),set.end(),id);
    if(at!=set.end()&&*at==id)set.erase(at);
    if(after==group)set.insert(std::lower_bound(set.begin(),set.end(),id),id);
    if(!writeIds(path,set))return false;
  }
  for(const char* dir:{"asc","desc"}) {
    Ids rank{IndexAllocator<int64_t>(arena)};const auto path=root()+"ranks/recently_read:"+dir;
    if(!readIds(path,rank))return false;
    rank.erase(std::remove(rank.begin(),rank.end(),id),rank.end());
    rank.insert(std::string(dir)=="desc"?rank.begin():rank.end(),id);
    if(!writeIds(path,rank))return false;
  }
  if(before!=after)for(const char* section:{"authors","series"})for(size_t n=0;;++n) {
    const auto path=root()+"sections/"+section+"/"+std::to_string(n);JsonDocument entry(arena);
    if(!load(path,entry))break;
    const auto key=std::string(section)=="authors"?"author:"+text(entry["id"]):"seriesId:"+text(entry["seriesId"]);
    Ids set{IndexAllocator<int64_t>(arena)};if(!readIds(root()+"members/"+encode(key),set)||!std::binary_search(set.begin(),set.end(),id))continue;
    for(const char* group:{"reading","finished"}) {
      const auto field=std::string(group)+"Count";
      if(!entry[field].isNull())entry[field]=std::max<int64_t>(0,(entry[field]|int64_t(0))+(after==group)-(before==group));
    }
    if(!save(path,entry.as<JsonVariantConst>()))return false;
  }
  return true;
}
}  // namespace orbify::bulk

#endif  // ORBIFY_BULK_AVAILABLE: no bulk code or static initialization on X3
