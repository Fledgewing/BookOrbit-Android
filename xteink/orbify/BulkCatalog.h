// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <CrossInkTailnetCuts.h>
#include <ArduinoJson.h>
#include <cstdint>
#include <functional>
#include <string>
#if CROSSINK_TAILNET_ORBIFY_MIRROR
namespace OrbifyBulk {
bool refresh(bool fresh, bool (*cancelled)(), const std::function<void(unsigned)>& progress, bool manual = true);
bool available(const std::string& url,bool detailSaved);
bool read(const std::string& url,JsonVariantConst filter,JsonDocument& out);
bool networkFetch();
bool detailCurrent(const std::string& url,const std::string& path);
bool active();
std::string generation();
uint32_t savedAt();
bool wasObserved(const std::string& url,const std::string& generation);
void noteObserved(const std::string& url,const std::string& generation);
void patch(int64_t id,JsonObjectConst fields);
void dropAll();
uint64_t bytes();
}
#endif
