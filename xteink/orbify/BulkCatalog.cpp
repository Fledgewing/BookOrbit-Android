// SPDX-License-Identifier: GPL-3.0-or-later
#include "BulkCatalog.h"
#if CROSSINK_TAILNET_ORBIFY_MIRROR
#include <HalStorage.h>
#include <Logging.h>
#include <WiFi.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <atomic>
#include <cstddef>
#include <cstdio>
#include <ctime>
#include <mutex>
#include "BookOrbitCredentialStore.h"
#include "BookOrbitSyncClient.h"
#include "CacheStore.h"
#include "Settings.h"
#include "HeapFloor.h"
#include "core/BulkCatalog.h"
#include "network/BookOrbitCatalogClient.h"
namespace OrbifyBulk {
namespace {
constexpr const char* DIR="/.crosspoint/orbify-catalog";
std::atomic<uint64_t> diskBytes{0};
std::atomic<bool> diskKnown{false};
#ifdef SIMULATOR
unsigned writesSinceClear=0;
#endif
std::atomic<TaskHandle_t> fetching{nullptr};
class Arena final:public ArduinoJson::Allocator {
 public:
  struct alignas(std::max_align_t) Header {size_t size;};
  static_assert(sizeof(Header)%alignof(std::max_align_t)==0,"PSRAM allocation alignment");
  size_t live=0,peak=0;
  void* allocate(size_t n) override {
    auto p=static_cast<Header*>(heap_caps_malloc(n+sizeof(Header),MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT));
    if(!p)return nullptr;p->size=n;live+=n;peak=std::max(peak,live);return p+1;
  }
  void deallocate(void* p) override {if(!p)return;auto base=static_cast<Header*>(p)-1;live-=base->size;heap_caps_free(base);}
  void* reallocate(void* p,size_t n) override {
    if(!p)return allocate(n);auto base=static_cast<Header*>(p)-1;const size_t old=base->size;
    auto result=static_cast<Header*>(heap_caps_realloc(base,n+sizeof(Header),MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT));
    if(!result)return nullptr;result->size=n;live=live-old+n;peak=std::max(peak,live);return result+1;
  }
};
uint64_t treeBytes(const std::string& path) {
  if(!Storage.exists(path.c_str()))return 0;
  HalFile file=Storage.open(path.c_str());if(!file)return 0;
  if(!file.isDirectory())return file.fileSize64();
  uint64_t total=0;
  while(HalFile child=file.openNextFile()) {
    char name[256]{};child.getName(name,sizeof(name));child.close();
    total+=treeBytes(path+"/"+name);
  }
  return total;
}
std::string owner() {
  return BOOKORBIT_STORE.getBaseUrl()+"|"+BOOKORBIT_STORE.getUsername()+"|"+BookOrbitSyncClient::deviceId()+"|bulk-v1";
}
class SdFiles final:public orbify::bulk::Files {
 public:
  uint32_t now() const override {const auto t=std::time(nullptr);return t>1700000000?static_cast<uint32_t>(t):0;}
  bool room(size_t n) override {
    return heap_caps_get_free_size(MALLOC_CAP_SPIRAM)>n+1024*1024 &&
      heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM)>n+16*1024;
  }
  std::string path(const std::string& p) {
    std::string result=DIR;size_t start=0;
    while(start<p.size()) {
      const auto end=p.find('/',start);auto part=p.substr(start,end-start);
      // FAT components have a finite length. Keep arbitrary UTF-8 facet/query
      // identities bounded in the filesystem without truncating their names.
      if(part.size()>120) {
        uint64_t a=14695981039346656037ULL,b=7809847782465536322ULL;
        for(unsigned char c:part){a=(a^c)*1099511628211ULL;b=(b+c)*14029467366897019727ULL;}
        char digest[40];snprintf(digest,sizeof(digest),"k%016llx%016llx",static_cast<unsigned long long>(a),static_cast<unsigned long long>(b));part=digest;
      }
      result+="/"+part;if(end==std::string::npos)break;start=end+1;
    }
    return result;
  }
  bool exists(const std::string& p) override {
    const auto file=path(p);if(!Storage.exists(file.c_str())&&Storage.exists((file+".bak").c_str()))Storage.rename((file+".bak").c_str(),file.c_str());
    return Storage.exists(file.c_str());
  }
  size_t size(const std::string& p) override {if(!exists(p))return 0;HalFile file=Storage.open(path(p).c_str());return file?file.fileSize():0;}
  bool read(const std::string& p,std::string& out) override {
    if(!exists(p))return false;
    // Only small records/markers use strings. Pages stream through readJson;
    // numeric indexes read directly into PSRAM.
    if(size(p)>16*1024)return false;
    return Storage.readFileToString("ORBB",path(p),16*1024,out);
  }
  bool readJson(const std::string& p,JsonDocument& out) override {
    if(!exists(p))return false;HalFile file;if(!Storage.openFileForRead("ORBB",path(p),file))return false;
    return !deserializeJson(out,file)&&!out.overflowed();
  }
  bool readIds(const std::string& p,void* out,size_t length) override {
    if(!exists(p))return false;HalFile file;if(!Storage.openFileForRead("ORBB",path(p),file)||file.fileSize()!=length)return false;
    return !length||file.read(out,length)==static_cast<int>(length);
  }
  bool put(const std::string& p,size_t length,const std::function<bool(HalFile&)>& body) {
    // All generated and temporary bytes participate in the existing shared
    // storage budget. Refuse before writing; the published generation survives.
#ifdef SIMULATOR
    if(const char* count=std::getenv("ORBIFY_SIM_SD_FULL_AFTER"))if(writesSinceClear>=strtoul(count,nullptr,10)) {
      OrbifyCache::setStorageStop(orbify::mirror::Stop::SdFull);return false;
    }
#endif
    if(!OrbifyCache::roomForReply())return false;
    const uint64_t limit=OrbifySettings::storageBytes();
    const auto used=OrbifyCache::bytesOnSd();const auto total=Storage.totalBytes(),taken=Storage.usedBytes();
    const auto budget=orbify::mirror::budget(used,0,length+4096,limit,total>taken?total-taken:0);
    if(budget!=orbify::mirror::Stop::None){OrbifyCache::setStorageStop(budget);return false;}
    const auto file=path(p),tmp=file+".tmp",bak=file+".bak";const auto parent=file.substr(0,file.find_last_of('/'));
    if(!Storage.mkdir(parent.c_str()))return false;
    const size_t old=size(p);HalFile f;if(!Storage.openFileForWrite("ORBB",tmp,f))return false;
    const bool ok=body(f)&&f.sync();f.close();if(!ok){Storage.remove(tmp.c_str());return false;}
    Storage.remove(bak.c_str());
    if(Storage.exists(file.c_str())&&!Storage.rename(file.c_str(),bak.c_str()))return false;
    if(!Storage.rename(tmp.c_str(),file.c_str())){if(Storage.exists(bak.c_str()))Storage.rename(bak.c_str(),file.c_str());return false;}
    Storage.remove(bak.c_str());
#ifdef SIMULATOR
    ++writesSinceClear;
#endif
    diskBytes.fetch_add(length);diskBytes.fetch_sub(std::min<uint64_t>(diskBytes.load(),old));return true;
  }
  bool write(const std::string& p,const std::string& s) override {return writeBytes(p,s.data(),s.size());}
  bool writeBytes(const std::string& p,const void* data,size_t length) override {
    return put(p,length,[&](HalFile& f){return !length||f.write(data,length)==length;});
  }
  bool writeJson(const std::string& p,JsonVariantConst value) override {
    const size_t length=measureJson(value);return put(p,length,[&](HalFile& f){return serializeJson(value,f)==length;});
  }
  bool erase(const std::string& p) override {
    const auto file=path(p);if(!Storage.exists(file.c_str()))return true;
    HalFile f=Storage.open(file.c_str());const bool directory=f.isDirectory();f.close();
    const auto old=treeBytes(file);const bool ok=directory?Storage.removeDir(file.c_str()):Storage.remove(file.c_str());
    if(ok)diskBytes.fetch_sub(std::min<uint64_t>(diskBytes.load(),old));return ok;
  }
};
SdFiles files;
}
uint64_t bytes(){
  if(!diskKnown.exchange(true)) {
    std::string usage;if(Storage.readFileToString("ORBB",std::string(DIR)+"/usage",128,usage))diskBytes.store(strtoull(usage.c_str(),nullptr,10));
  }
  return diskBytes.load();
}
bool active(){std::string saved;return files.exists("bulk/active")&&files.read("bulk/owner",saved)&&saved==owner();}
std::string generation(){std::string g;if(active())files.read("bulk/active",g);return g;}
uint32_t savedAt(){const auto g=generation();std::string at;return !g.empty()&&files.read("bulk/"+g+"/at",at)?strtoul(at.c_str(),nullptr,10):0;}
bool wasObserved(const std::string& url,const std::string& g){return !g.empty()&&files.exists("bulk/"+g+"/observed/"+std::to_string(orbify::cache::keyHash(url)));}
void noteObserved(const std::string& url,const std::string& g){
  if(!g.empty()&&g==generation())files.write("bulk/"+g+"/observed/"+std::to_string(orbify::cache::keyHash(url)),"1");
}
bool networkFetch(){return fetching.load()==xTaskGetCurrentTaskHandle();}
bool refresh(bool fresh,bool (*cancelled)(),const std::function<void(unsigned)>& progress,bool manual) {
#ifdef SIMULATOR
  writesSinceClear=0;
#endif
  diskBytes.store(treeBytes(DIR));diskKnown.store(true);Arena arena;orbify::bulk::Catalog catalog(files,&arena);
  const auto start=millis();
  const bool ok=catalog.refresh(owner(),[&](const std::string& path,JsonDocument& out){
    if(!OrbifyHeap::roomForRequest("Full refresh"))return false;
    fetching.store(xTaskGetCurrentTaskHandle());
    const bool result=BookOrbitCatalogClient::fetchBulk(path+(path.find("/manifest?")!=std::string::npos?"&deviceId="+orbify::bulk::encode(BookOrbitSyncClient::deviceId()):""),out);
    fetching.store(nullptr);return result;
  },[&]{return cancelled()||heap_caps_get_free_size(MALLOC_CAP_SPIRAM)<1024*1024;},progress,fresh,manual);
  LOG_INF("ORB","Bulk catalog: ok=%d requests=%llu secondaryRequests=%llu bytes=%llu elapsedMs=%lu rows=%llu psramPeakBytes=%u bytesOnSD=%llu result=%s",ok,
    static_cast<unsigned long long>(catalog.stats.requests),static_cast<unsigned long long>(catalog.stats.seriesRequests),
    static_cast<unsigned long long>(catalog.stats.bytes),millis()-start,static_cast<unsigned long long>(catalog.stats.rows),
    static_cast<unsigned>(arena.peak),static_cast<unsigned long long>(bytes()),catalog.error.c_str());
  HalFile usage;if(Storage.openFileForWrite("ORBB",std::string(DIR)+"/usage",usage)) {
    const auto count=std::to_string(bytes());usage.write(count.data(),count.size());usage.sync();
  }
  return ok;
}
bool available(const std::string& url,bool detailSaved) {
  if(networkFetch()||!active()||!orbify::bulk::Catalog::recognizes(url))return false;
  const bool detail=url.find("/plugin/catalog/books/")!=std::string::npos;
  return !detail || (!detailSaved && WiFi.status()!=WL_CONNECTED);
}
bool read(const std::string& url,JsonVariantConst filter,JsonDocument& out) {
  Arena arena;JsonDocument reply(&arena);orbify::bulk::Catalog catalog(files,&arena);
  if(!catalog.reply(url,reply))return false;
  out.clear();orbify::bulk::project(reply.as<JsonVariantConst>(),filter,out.to<JsonVariant>());
  return !out.overflowed();
}
bool detailCurrent(const std::string& url,const std::string& path) {
  if(url.find("/plugin/catalog/books/")==std::string::npos||!active())return true;
  Arena arena;JsonDocument canonical(&arena),saved(&arena);orbify::bulk::Catalog catalog(files,&arena);
  if(!catalog.reply(url,canonical))return true;
  HalFile file;if(!Storage.openFileForRead("ORBB",path,file)||deserializeJson(saved,file))return false;
  for(const char* key:{"updatedAt","title","authors"}) {
    if(orbify::cache::canonicalHash(canonical[key])!=orbify::cache::canonicalHash(saved[key]))return false;
  }
  for(JsonObjectConst file:canonical["files"].as<JsonArrayConst>()) {
    bool found=false;
    for(JsonObjectConst old:saved["files"].as<JsonArrayConst>())if(old["id"]==file["id"]) {
      found=true;
      for(const char* key:{"contentVersion","fileHash","devicePath"})if(old[key]!=file[key])return false;
    }
    if(!found)return false;
  }
  return true;
}
void patch(int64_t id,JsonObjectConst fields) {
  Arena arena;orbify::bulk::Catalog catalog(files,&arena);catalog.patch(id,fields);
}
void dropAll(){files.erase("bulk/");diskBytes.store(treeBytes(DIR));}
}  // namespace OrbifyBulk
#endif
