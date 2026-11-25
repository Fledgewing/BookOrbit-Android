// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>
namespace OrbifySettings {
std::string get(const char* key);
std::string label(const char* key);
void cycle(const char* key);
uint64_t storageBytes();
unsigned idleSeconds();
}
