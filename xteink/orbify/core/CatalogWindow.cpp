// SPDX-License-Identifier: GPL-3.0-or-later
#if __has_include(<CrossInkTailnetCuts.h>)
#include <CrossInkTailnetCuts.h>
#define WINDOW_ENABLED CROSSINK_TAILNET_ORBIFY_CACHE
#else
#define WINDOW_ENABLED 1
#endif
#if WINDOW_ENABLED
#include "CatalogWindow.h"
#include <cstdlib>
#include <map>
namespace orbify::catalog {
namespace {
using Query=std::map<std::string,std::string>;
bool parse(const std::string& url,std::string& base,Query& q,bool& books) {
  const auto mark=url.find('?');base=url.substr(0,mark);
  const auto at=base.find("/plugin/catalog/");if(at==std::string::npos)return false;
  const auto path=base.substr(at+16);books=path=="books";
  if(!books&&(path.find("sections/")!=0||path.find('/',9)!=std::string::npos))return false;
  if(mark==std::string::npos)return true;
  size_t start=mark+1;
  while(start<url.size()) {auto end=url.find('&',start);auto pair=url.substr(start,end-start);auto eq=pair.find('=');
    if(eq!=std::string::npos)q[pair.substr(0,eq)]=pair.substr(eq+1);
    if(end==std::string::npos)break;start=end+1;
  }
  return true;
}
std::string render(const std::string& base,const Query& q) {
  std::string out=base;bool first=true;
  for(const auto& p:q)if(!p.second.empty()){out+=first?'?':'&';first=false;out+=p.first+'='+p.second;}
  return out;
}
std::string direction(const std::string& sort) {
  return sort=="recently_added"||sort=="recently_read"||sort=="recently_updated"?"desc":"asc";
}
}
bool sourceUrls(const std::string& url,size_t page,bool withoutFormat,const std::function<bool(const std::string&)>& visit) {
  Query q;std::string base;bool books;
  if(!parse(url,base,q,books))return false;
  q.erase("offset");q.erase("buckets");if(withoutFormat)q.erase("format");q["size"]=std::to_string(FETCH_SIZE);q["page"]=std::to_string(page);
  const auto defaultSort=books?"recently_added":"name";
  const auto sort=q["sort"].empty()?defaultSort:q["sort"];
  const auto order=q["order"].empty()?direction(sort):q["order"];
  // Probe one key at a time: never retain a vector of URL strings in internal RAM.
  if(visit(render(base,q)))return true;
  auto bare=q;if(sort==defaultSort)bare.erase("sort");if(order==direction(sort))bare.erase("order");
  if(visit(render(base,bare)))return true;
  for(bool omitSort:{false,true})for(bool omitOrder:{false,true})for(bool omitPage:{false,true}) {
    if((omitSort&&sort!=defaultSort)||(omitOrder&&order!=direction(sort))||(omitPage&&page!=1))continue;
    auto candidate=q;
    if(omitSort)candidate.erase("sort");else candidate["sort"]=sort;
    if(omitOrder)candidate.erase("order");else candidate["order"]=order;
    if(omitPage)candidate.erase("page");
    // Older refreshes asked for buckets=1; buckets do not change list identity.
    for(const char* bucket:{"","1","true"}) {candidate["buckets"]=bucket;if(visit(render(base,candidate)))return true;}
  }
  return false;
}
bool readCachedWindow(const std::string& url,const PageReader& read,JsonDocument& out,ArduinoJson::Allocator* allocator) {
  Query q;std::string base;bool books;if(!parse(url,base,q,books))return false;
  const size_t size=std::max(1,std::min(200,q["size"].empty()?(books?int(BROWSE_SIZE):60):atoi(q["size"].c_str())));
  const size_t number=std::max(1,q["page"].empty()?1:atoi(q["page"].c_str()));
  const Window window{q["offset"].empty()?Window::page(number,size).offset:strtoul(q["offset"].c_str(),nullptr,10),size};
  auto load=[&](size_t n,JsonDocument& doc,bool withoutFormat=false) {
    return sourceUrls(url,n,withoutFormat,[&](const std::string& candidate) {
      doc.clear();return read(candidate,doc)&&doc["items"].is<JsonArray>()&&(doc["size"]|size_t(FETCH_SIZE))==FETCH_SIZE;
    });
  };
  auto* arena=allocator?allocator:ArduinoJson::detail::DefaultAllocator::instance();
  auto direct=[&](bool withoutFormat) {
    JsonDocument page(arena);size_t source=window.offset/FETCH_SIZE+1;
    if(!load(source,page,withoutFormat)) {
      if(source==1||!load(1,page,withoutFormat)||(page["total"]|size_t(0))>window.offset)return false;
      source=1;
    }
    const size_t total=page["total"]|page["items"].size();
    out.clear();out["page"]=number;out["size"]=size;out["total"]=total;out["hasNext"]=window.end(total)<total;
    if(!page["buckets"].isNull())out["buckets"].set(page["buckets"]);
    auto items=out["items"].to<JsonArray>();
    for(size_t pos=window.offset;pos<window.end(total);++pos) {
      const size_t wanted=pos/FETCH_SIZE+1;
      if(wanted!=source){if(!load(wanted,page,withoutFormat)||(page["total"]|total)!=total){out.clear();return false;}source=wanted;}
      const size_t at=pos%FETCH_SIZE;
      if(at>=page["items"].size()){out.clear();return false;}
      items.add(page["items"][at]);
    }
    return !out.overflowed();
  };
  if(direct(false))return true;
  if(!books||q["format"].empty())return false;
  // Smart-scope results ignore the separate format selector, as the bulk adapter does.
  if(!q["smartScopeId"].empty())return direct(true);
  // The normal sleep/Home refresh enumerates all formats. Project that saved
  // sequence locally, in bounded PSRAM JSON, before applying browser offsets.
  JsonDocument page(arena);
  if(!load(1,page,true))return false;
  const size_t rawTotal=page["total"]|page["items"].size();
  out.clear();out["page"]=number;out["size"]=size;auto items=out["items"].to<JsonArray>();
  if(!page["buckets"].isNull())out["buckets"].set(page["buckets"]);
  auto buckets=out["buckets"].as<JsonArray>();size_t bucket=0,matched=0;
  for(size_t source=1;;++source) {
    if(source>1&&(!load(source,page,true)||(page["total"]|rawTotal)!=rawTotal)){out.clear();return false;}
    const auto rows=page["items"].as<JsonArrayConst>();
    if(rows.size()==0&&(source-1)*FETCH_SIZE<rawTotal){out.clear();return false;}
    size_t raw=(source-1)*FETCH_SIZE;
    for(JsonObjectConst row:rows) {
      while(bucket<buckets.size()&&(buckets[bucket]["index"]|size_t(0))<=raw)buckets[bucket++]["index"]=matched;
      ++raw;bool match=false;
      for(JsonVariantConst f:row["formats"].as<JsonArrayConst>())if(f==q["format"])match=true;
      for(JsonObjectConst f:row["files"].as<JsonArrayConst>())if(f["format"]==q["format"])match=true;
      if(!match)continue;
      if(matched>=window.offset&&matched-window.offset<size)items.add(row);
      ++matched;
    }
    if(raw>=rawTotal)break;
    if(rows.size()!=FETCH_SIZE){out.clear();return false;}
  }
  // Remove letters with no matching books while preserving the server's buckets.
  for(size_t i=buckets.size();i>0;--i)if((buckets[i-1]["index"]|size_t(0))>=matched||
      (i<buckets.size()&&buckets[i-1]["index"]==buckets[i]["index"]))buckets.remove(i-1);
  out["total"]=matched;out["hasNext"]=window.end(matched)<matched;
  return !out.overflowed();
}
}
#endif
