// SPDX-License-Identifier: GPL-3.0-or-later
// @fixture catalog/bulk-refresh/catalog.json
#include "BulkRefresh.h"
#include "BulkCatalog.h"
#include <sstream>
#include <fstream>
#include <tuple>
#include "TestSupport.h"
#include <filesystem>

struct MemoryFiles : orbify::bulk::Files {
  std::map<std::string,std::string> files;
  bool failWrites=false, failRoom=false;
  bool room(size_t) override {return !failRoom;}
  bool read(const std::string& p,std::string& out) override {auto at=files.find(p);if(at==files.end())return false;out=at->second;return true;}
  bool write(const std::string& p,const std::string& s) override {if(failWrites)return false;files[p]=s;return true;}
  bool exists(const std::string& p) override {return files.count(p);}
  bool erase(const std::string& p) override {for(auto at=files.begin();at!=files.end();)if(at->first==p||at->first.find(p)==0)at=files.erase(at);else ++at;return true;}
};
static std::map<std::string,std::string> params(const std::string& p) {
  std::map<std::string,std::string> q;auto at=p.find('?');if(at==std::string::npos)return q;
  while(++at<p.size()){auto end=p.find('&',at);auto pair=p.substr(at,end-at);auto eq=pair.find('=');q[pair.substr(0,eq)]=eq==std::string::npos?"":pair.substr(eq+1);if(end==std::string::npos)break;at=end;}return q;
}
int main(int argc, char** argv) {
  if (argc < 2) return 2;
  JsonDocument fx;
  CHECK(loadJsonFile((std::filesystem::path(argv[1]).parent_path() / "catalog/bulk-refresh/catalog.json").string().c_str(), fx));
  const auto books = fx["manifest"].as<JsonArrayConst>();
  const auto rows = fx["rows"].as<JsonArrayConst>();
  CHECK(books.size() == rows.size());
  std::map<int64_t, size_t> primary;
  for (JsonObjectConst row : rows) ++primary[row["seriesId"].as<int64_t>()];
  unsigned extra = 0;
  for (JsonObjectConst series : fx["sections"]["series"].as<JsonArrayConst>()) {
    const auto id = series["seriesId"].as<int64_t>();
    if (orbify::bulk::needsSecondary(primary[id], series["count"].as<size_t>())) ++extra;
  }
  CHECK(extra == 1);
  CHECK(!orbify::bulk::reconcileSecondary(true, 5, 5, false));
  CHECK(orbify::bulk::reconcileSecondary(true, 5, 5, true));
  CHECK(orbify::bulk::reconcileSecondary(true, 5, 4, false));
  CHECK(orbify::bulk::status("on_hold") == "reading");
  CHECK(orbify::bulk::status("skimmed") == "finished");
  orbify::bulk::ManifestCursor cursor;
  JsonDocument page;
  page["items"].to<JsonArray>(); page["hasNext"] = true; page["nextCursor"] = "opaque-1";
  std::string error;
  CHECK(cursor.accept(page.as<JsonVariantConst>(), error));
  CHECK(!cursor.accept(page.as<JsonVariantConst>(), error));
  page["restartRequired"] = true;
  CHECK(cursor.accept(page.as<JsonVariantConst>(), error));
  CHECK(cursor.cursor.empty());
  CHECK(!cursor.accept(page.as<JsonVariantConst>(), error));
  orbify::bulk::Progress progress;
  progress.phase(60); progress.phase(20); CHECK(progress.shown == 60);
  progress.publishBase(); CHECK(progress.basePublished && progress.shown == 90);
  progress.finish(false); CHECK(!progress.complete && progress.shown < 100);
  progress.finish(true); CHECK(progress.complete && progress.shown == 100);
  MemoryFiles disk;
  orbify::bulk::Catalog catalog(disk);
  bool baseReady=false;
  auto fetch=[&](const std::string& path,JsonDocument& out) {
    auto q=params(path);
    if(!q["seriesId"].empty()||!q["series"].empty())CHECK(baseReady);
    const size_t size=q["size"].empty()?100:std::stoul(q["size"]);const size_t page=q["page"].empty()?1:std::stoul(q["page"]);
    std::vector<JsonObjectConst> selected;
    if(path.find("/manifest?")!=std::string::npos) {
      size_t offset=q["cursor"].empty()?0:std::stoul(q["cursor"]);
      auto items=out["items"].to<JsonArray>();for(size_t i=offset;i<std::min(offset+size,books.size());++i)items.add(books[i]);
      out["hasNext"]=offset+size<books.size();if(offset+size<books.size())out["nextCursor"]=std::to_string(offset+size);return true;
    }
    if(path.find("/sections/")!=std::string::npos && path.find("/dashboard/")==std::string::npos) {
      const auto start=path.find("/sections/")+10;const auto section=path.substr(start,path.find('?',start)-start);
      for(JsonObjectConst row:fx["sections"][section].as<JsonArrayConst>())selected.push_back(row);
      if(q["sort"]=="name_desc")std::reverse(selected.begin(),selected.end());
    } else if(path.find("/books?")!=std::string::npos) {
      for(JsonObjectConst row:rows) {
        bool include=true;
        for(const char* key:{"libraryId","collectionId","smartScopeId","seriesId"})if(!q[key].empty()) {
          include=false;for(JsonVariantConst id:fx["memberships"][std::string(key)+":"+q[key]].as<JsonArrayConst>())if(id==row["id"])include=true;
        }
        if(!q["readStatus"].empty() && orbify::bulk::status(row["readStatus"]|"")!=q["readStatus"])include=false;
        if(q.count("ids") && row["id"].as<int64_t>()!=std::stoll(q["ids"]))include=false;
        if(include)selected.push_back(row);
      }
      auto ranks=fx["ranks"][q["sort"]+":"+q["order"]].as<JsonArrayConst>();
      auto rank=[&](JsonObjectConst row){size_t i=0;for(JsonVariantConst id:ranks){if(id==row["id"])return i;++i;}return size_t(row["id"].as<int64_t>());};
      if(ranks.size())std::sort(selected.begin(),selected.end(),[&](auto a,auto b){return rank(a)<rank(b);});
      else if(q["order"]=="desc")std::reverse(selected.begin(),selected.end());
      if(!q["seriesId"].empty() || !q["series"].empty()) {
        std::stable_sort(selected.begin(),selected.end(),[&](auto a,auto b){
          auto ix=[&](auto row){JsonVariantConst c=fx["secondary_context"]["seriesId:"+(q["seriesId"].empty()?"202":q["seriesId"])+":"+row["id"].template as<std::string>()];return std::stod(c.isNull()?row["seriesIndex"].template as<std::string>():c["seriesIndex"].template as<std::string>());};return ix(a)<ix(b);
        });
      }
    } else return path.find("/books/")==std::string::npos;
    auto items=out["items"].to<JsonArray>();out["total"]=selected.size();
    for(size_t i=(page-1)*size;i<std::min(page*size,selected.size());++i) {
      auto row=items.add<JsonObject>();row.set(selected[i]);
      if(!q["seriesId"].empty() || !q["series"].empty()) {JsonVariantConst c=fx["secondary_context"]["seriesId:"+(q["seriesId"].empty()?"202":q["seriesId"])+":"+selected[i]["id"].as<std::string>()];if(!c.isNull())for(JsonPairConst f:c.as<JsonObjectConst>())row[f.key()].set(f.value());}
    }
    return true;
  };
  std::vector<unsigned> shown;
  CHECK(catalog.refresh("account-device-variant",fetch,[]{return false;},[&](unsigned p){shown.push_back(p);if(p>=90){baseReady=true;orbify::bulk::Catalog offline(disk);JsonDocument base;CHECK(offline.reply("/plugin/catalog/books?sort=title&size=100",base));CHECK(base["items"].size()==8);}}));
  if(!catalog.error.empty())std::printf("engine error: %s\n",catalog.error.c_str());
  CHECK(catalog.stats.seriesRequests==2);
  CHECK(std::is_sorted(shown.begin(),shown.end()) && shown.back()==100);
  for(JsonObjectConst window:fx["windows"].as<JsonArrayConst>()) {
    JsonDocument out;const auto path=std::string("/plugin/catalog/books?")+(window["query"]|"")+"&size=100";
    CHECK_NAMED(path.c_str(),catalog.reply(path,out));
    std::vector<int64_t> actual,expected;for(JsonObjectConst row:out["items"].as<JsonArrayConst>())actual.push_back(row["id"]);for(JsonVariantConst id:window["ids"].as<JsonArrayConst>())expected.push_back(id);
    CHECK_NAMED(path.c_str(),actual==expected);
    for(size_t offset=0;offset<=expected.size()+1;++offset) {
      JsonDocument later;CHECK(catalog.reply(path+"&offset="+std::to_string(offset)+"&size=1",later));
      CHECK(later["items"].size()==(offset<expected.size()?1:0));
      if(offset<expected.size())CHECK(later["items"][0]["id"]==expected[offset]);
    }
  }
  // Every finite family in the shared browse inventory is evaluated with the
  // transport detached. The reference selects records independently, then uses
  // server fixture ranks for keys the server does not project.
  size_t identities=0;
  const std::vector<std::pair<std::string,std::string>> bases={{"",""},{"author","Author A"},{"author","Author B"},{"seriesId","101"},{"seriesId","202"},{"series","series:202"},{"series","Shared name"},{"collectionId","7"},{"libraryId","1"},{"smartScopeId","9"}};
  for(const auto& base:bases)for(const char* library:{"","1"})for(const char* format:{"","epub","pdf","cbz","cbr","mobi","azw3","fb2","djvu","txt"})for(const char* state:{"","reading","finished","unread"})for(const char* sort:{"title","author","series","published","recently_read","recently_added","recently_updated"})for(const char* dir:{"asc","desc"})for(bool local:{false,true}) {
    std::map<std::string,std::string> q={{"sort",sort},{"order",dir}};
    if(!base.first.empty())q[base.first]=base.second;
    if(*library)q["libraryId"]=library;if(*format)q["format"]=format;if(*state)q["readStatus"]=state;if(local)q["ids"]="2,6,8";
    auto member=[&](const std::string& key,int64_t id){for(JsonVariantConst value:fx["memberships"][key].as<JsonArrayConst>())if(value==id)return true;return false;};
    std::vector<int64_t> expected;
    for(JsonObjectConst row:rows) {
      const int64_t id=row["id"];bool match=true;
      if(q.count("smartScopeId"))match=member("smartScopeId:"+q["smartScopeId"],id);
      else {
        for(const char* selector:{"libraryId","collectionId","seriesId"})if(q.count(selector)&&!member(std::string(selector)+":"+q[selector],id))match=false;
        if(q.count("series")&&q.at("series")=="series:202"&&!member("seriesId:202",id))match=false;
        if(q.count("author")){bool found=false;for(JsonVariantConst a:row["authors"].as<JsonArrayConst>())if(a==q["author"])found=true;if(!found)match=false;}
        if(*format){bool found=false;for(JsonVariantConst f:row["formats"].as<JsonArrayConst>())if(f==format)found=true;if(!found)match=false;}
        if(*state&&orbify::bulk::status(row["readStatus"]|"")!=state)match=false;
        if(local&&id!=2&&id!=6&&id!=8)match=false;
      }
      if(match)expected.push_back(id);
    }
    JsonArrayConst ranks=fx["ranks"][std::string(sort)+":"+dir];
    auto rank=[&](int64_t id){size_t n=0;for(JsonVariantConst value:ranks){if(value==id)return n;++n;}return size_t(id);};
    const bool context=!q.count("smartScopeId")&&(q.count("seriesId")||q.count("series"));
    if(context&&std::string(sort)=="series") {
      auto key=[&](int64_t id){std::string index=rows[size_t(id-1)]["seriesIndex"].as<std::string>();if((q["seriesId"]=="202"||q.count("series"))&&id==2)index="99";auto dot=index.find('.');return std::make_tuple(std::stod(index.substr(0,dot)),dot==std::string::npos?-1:std::stod(index.substr(dot+1)),index);};
      std::sort(expected.begin(),expected.end(),[&](int64_t a,int64_t b){auto x=key(a),y=key(b);return x==y?a<b:std::string(dir)=="asc"?x<y:x>y;});
    } else std::sort(expected.begin(),expected.end(),[&](int64_t a,int64_t b){return ranks.size()?rank(a)<rank(b):std::string(dir)=="asc"?a<b:a>b;});
    std::string path="/plugin/catalog/books?size=100";for(const auto& field:q)path+="&"+field.first+"="+orbify::bulk::encode(field.second);
    JsonDocument out;CHECK_NAMED(path.c_str(),catalog.reply(path,out));std::vector<int64_t> actual;
    for(JsonObjectConst row:out["items"].as<JsonArrayConst>())actual.push_back(row["id"]);
    CHECK_NAMED(path.c_str(),actual==expected);
    JsonDocument later;CHECK(catalog.reply(path+"&offset=2&size=3",later));
    std::vector<int64_t> slice;for(size_t n=2;n<std::min<size_t>(5,expected.size());++n)slice.push_back(expected[n]);actual.clear();for(JsonObjectConst row:later["items"].as<JsonArrayConst>())actual.push_back(row["id"]);CHECK(actual==slice);
    ++identities;
  }
  CHECK(identities==22400);
  std::printf("native offline inventory: %zu identities and later windows\n",identities);
  CHECK(catalog.refresh("account-device-variant",fetch,[]{return false;},[](unsigned){}));
  CHECK(catalog.stats.seriesRequests==0);
  JsonDocument named;
  CHECK(catalog.reply("/plugin/catalog/books?series=Shared%20name&sort=series&size=100",named));
  CHECK(named["items"][7]["id"]==2 && named["items"][7]["seriesIndex"]=="99");
  JsonDocument fields;fields["readStatus"]="unread";CHECK(catalog.patch(2,fields.as<JsonObjectConst>()));
  JsonDocument patched;CHECK(catalog.reply("/plugin/catalog/books?ids=2&readStatus=unread&size=100",patched));CHECK(patched["items"].size()==1);
  CHECK(catalog.refresh("account-device-variant",fetch,[]{return false;},[](unsigned){}));
  std::string published;CHECK(disk.read("bulk/active",published));
  bool cancel=false;
  CHECK(!catalog.refresh("account-device-variant",[&](const std::string& path,JsonDocument& out){const bool ok=fetch(path,out);if(path.find("/manifest?")!=std::string::npos)cancel=true;return ok;},[&]{return cancel;},[](unsigned){}));
  std::string still;CHECK(disk.read("bulk/active",still)&&still==published);
  unsigned manifestRequests=0;
  CHECK(catalog.refresh("account-device-variant",[&](const std::string& path,JsonDocument& out){manifestRequests+=path.find("/manifest?")!=std::string::npos;return fetch(path,out);},[]{return false;},[](unsigned){}));
  CHECK(manifestRequests==0);  // durable manifest checkpoint, then resume
  CHECK(disk.read("bulk/active",published));
  disk.failWrites=true;
  CHECK(!catalog.refresh("account-device-variant",fetch,[]{return false;},[](unsigned){}));
  disk.failWrites=false;CHECK(disk.read("bulk/active",still)&&still==published);
  disk.failRoom=true;CHECK(!catalog.refresh("account-device-variant",fetch,[]{return false;},[](unsigned){}));disk.failRoom=false;
  CHECK(disk.read("bulk/active",still)&&still==published);
  JsonDocument preserved;CHECK(catalog.reply("/plugin/catalog/books?sort=title&size=100",preserved));CHECK(preserved["items"].size()==8);
  CHECK(!catalog.refresh("account-device-variant",[](const std::string&,JsonDocument&){return false;},[]{return false;},[](unsigned){}));
  CHECK(disk.read("bulk/active",still)&&still==published);
  // A complete manifest can race a deletion. An omitted ID batch removes the
  // staged record, never an unrelated published generation or an endless retry.
  CHECK(catalog.refresh("account-device-variant",[&](const std::string& path,JsonDocument& out){
    if(!fetch(path,out))return false;
    if(path.find("/books?")!=std::string::npos) {
      auto items=out["items"].as<JsonArray>();for(size_t i=items.size();i>0;--i)if(items[i-1]["id"]==8)items.remove(i-1);
      out["total"]=items.size();
    }
    if(path.find("/sections/series?")!=std::string::npos)for(JsonObject row:out["items"].as<JsonArray>())if(row["seriesId"]==202)row["count"]=4;
    return true;
  },[]{return false;},[](unsigned){}));
  JsonDocument deleted;CHECK(catalog.reply("/plugin/catalog/books?sort=title&size=100",deleted));CHECK(deleted["items"].size()==7);
  CHECK(!catalog.reply("/plugin/catalog/books/8",deleted));
  auto discover=[&](int64_t id) {return [&,id](const std::string& path,JsonDocument& out){
    const bool ok=fetch(path,out);if(path.find("/dashboard")!=std::string::npos)out["discover"][0]["id"]=id;return ok;
  };};
  CHECK(catalog.refresh("account-device-variant",discover(1),[]{return false;},[](unsigned){},false,true));
  CHECK(catalog.refresh("account-device-variant",discover(2),[]{return false;},[](unsigned){},false,false));
  JsonDocument pick;CHECK(catalog.reply("/plugin/catalog/dashboard",pick));CHECK(pick["discover"][0]["id"]==1);
  CHECK(catalog.refresh("account-device-variant",discover(3),[]{return false;},[](unsigned){},false,true));
  CHECK(catalog.reply("/plugin/catalog/dashboard",pick));CHECK(pick["discover"][0]["id"]==3);
  return report("bulk-refresh");
}
