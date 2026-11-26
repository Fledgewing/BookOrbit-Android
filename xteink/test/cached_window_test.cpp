// SPDX-License-Identifier: GPL-3.0-or-later
#include "CatalogWindow.h"
#include "CatalogCache.h"
#include "TestSupport.h"
#include <map>
#include <cstring>
struct Arena final:ArduinoJson::Allocator {
  struct alignas(std::max_align_t) Header{size_t bytes;};
  size_t live=0,peak=0;
  void* allocate(size_t n) override {auto* h=static_cast<Header*>(std::malloc(sizeof(Header)+n));if(!h)return nullptr;h->bytes=n;live+=n;peak=std::max(peak,live);return h+1;}
  void deallocate(void* p) override {if(p){auto* h=static_cast<Header*>(p)-1;live-=h->bytes;std::free(h);}}
  void* reallocate(void* p,size_t n) override {if(!p)return allocate(n);auto* h=static_cast<Header*>(p)-1;auto old=h->bytes;auto* next=static_cast<Header*>(std::realloc(h,sizeof(Header)+n));if(!next)return nullptr;next->bytes=n;live=live-old+n;peak=std::max(peak,live);return next+1;}
};
int main() {
  using namespace orbify::catalog;
  std::map<std::string,std::string> sd;
  auto key=[](const std::string& url){return orbify::cache::keyForUrl("test","GET",url);};
  // Refresh's exact URLs, including explicit descending order and 100-row pages.
  for(bool books:{false,true})for(size_t page=1;page<=3;++page) {
    JsonDocument doc;doc["page"]=page;doc["size"]=100;doc["total"]=245;doc["hasNext"]=page<3;
    auto items=doc["items"].to<JsonArray>();
    for(size_t i=(page-1)*100;i<std::min(page*100,size_t(245));++i) {
      auto row=items.add<JsonObject>();row["id"]=books?245-i:i+1;row["title"]="Synthetic";row["authors"][0]="Fixture";
    }
    const auto url=books?"/plugin/catalog/books?format=epub&sort=recently_added&order=desc&size=100&page=":
                          "/plugin/catalog/sections/authors?size=100&page=";
    serializeJson(doc,sd[key(url+std::to_string(page))]);
  }
  // The normal refresh's library request has no format selector. EPUB
  // browsing must filter those rows before applying its 20-row offsets.
  for(const char* scope:{"libraryId=7","smartScopeId=9"})for(size_t page=1;page<=3;++page) {
    JsonDocument doc;doc["page"]=page;doc["size"]=100;doc["total"]=245;doc["hasNext"]=page<3;
    auto items=doc["items"].to<JsonArray>();
    for(size_t i=(page-1)*100;i<std::min(page*100,size_t(245));++i) {
      auto row=items.add<JsonObject>();row["id"]=245-i;row["formats"][0]=i%2?"pdf":"epub";
    }
    for(size_t i=0;i<3;++i){doc["buckets"][i]["key"]=std::string(1,char('A'+i));doc["buckets"][i]["index"]=i*100;}
    serializeJson(doc,sd[key(std::string("/plugin/catalog/books?sort=recently_added&order=desc&size=100&")+scope+"&page="+std::to_string(page))]);
  }
  Arena arena;size_t windows=0;
  auto read=[&](const std::string& url,JsonDocument& doc){auto at=sd.find(key(url));return at!=sd.end()&&!deserializeJson(doc,at->second);};
  for(int repeat=0;repeat<3;++repeat)for(bool books:{false,true})for(size_t width:{size_t(20),size_t(60),size_t(31)}) {
    for(size_t page=1;page<=245/width+3;++page) {
      {
        JsonDocument out(&arena);
        const auto path=(books?std::string("/plugin/catalog/books?format=epub&sort=recently_added"):
                               std::string("/plugin/catalog/sections/authors?sort=name"))+
          "&page="+std::to_string(page)+"&size="+std::to_string(width);
        CHECK_NAMED(path.c_str(),readCachedWindow(path,read,out,&arena));
        const size_t offset=(page-1)*width,expected=offset<245?std::min(width,245-offset):0;
        CHECK(out["items"].size()==expected);CHECK(out["total"]==245);CHECK(out["hasNext"]==(offset+width<245));
        for(size_t i=0;i<expected;++i)CHECK(out["items"][i]["id"]==(books?245-offset-i:offset+i+1));
      }
      CHECK(arena.live==0);++windows;
    }
  }
  for(size_t page=1;page<=9;++page) {
    {
      JsonDocument out(&arena);
      CHECK(readCachedWindow("/plugin/catalog/books?libraryId=7&format=epub&sort=recently_added&size=20&page="+std::to_string(page),read,out,&arena));
      CHECK(out["total"]==123);const size_t offset=(page-1)*20,expected=offset<123?std::min(size_t(20),123-offset):0;
      CHECK(out["items"].size()==expected);
      for(size_t i=0;i<expected;++i)CHECK(out["items"][i]["id"]==245-2*(offset+i));
      CHECK(out["buckets"][0]["index"]==0);CHECK(out["buckets"][1]["index"]==50);CHECK(out["buckets"][2]["index"]==100);
      CHECK(readCachedWindow("/plugin/catalog/books?smartScopeId=9&format=epub&size=20&page="+std::to_string(page),read,out,&arena));
      CHECK(out["total"]==245);CHECK(out["items"][0]["id"]==245-offset);
    }
    CHECK(arena.live==0);windows+=2;
  }
  {
    JsonDocument out(&arena);
    CHECK(readCachedWindow("/plugin/catalog/books?format=epub&size=20&buckets=true",read,out,&arena));
    CHECK(out["items"][0]["id"]==245);  // omitted sort, order, page; bucket metadata is optional
    CHECK(readCachedWindow("/plugin/catalog/sections/authors",read,out,&arena));CHECK(out["items"].size()==60);
    for(const char* wrong:{"&order=asc","&libraryId=2","&readStatus=finished","&sort=title"})
      CHECK(!readCachedWindow(std::string("/plugin/catalog/books?format=epub&size=20")+wrong,read,out,&arena));
    // A missing source is a miss, never a partial reply or a wrong-order substitute.
    sd.erase(key("/plugin/catalog/sections/authors?size=100&page=2"));
    CHECK(!readCachedWindow("/plugin/catalog/sections/authors?page=2&size=60",read,out,&arena));
    CHECK(!readCachedWindow("/plugin/catalog/books/3",read,out,&arena));
  }
  CHECK(arena.live==0);CHECK(arena.peak<128*1024);
  std::printf("refreshed SD pages: %zu offline windows, JSON peak %zu bytes, zero retained\n",windows,arena.peak);
  return report("cached-window");
}
