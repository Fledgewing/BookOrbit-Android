// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "core/OrbiSmart.h"
#include <Epub.h>
#include <KOReaderSyncClient.h>
#include <ProgressMapper.h>
#include <memory>
#include <string>

class GfxRenderer;
namespace OrbiSmartSync {
using namespace orbify::orbismart;
bool enabled();
uint32_t generation();
bool checkOnOpen(const std::string &path);
// All network work runs on the existing sync task. The reader consumes only
// saved places.
Result evaluate(const std::shared_ptr<Epub> &epub,
                const CrossPointPosition &local, const KOReaderProgress *remote,
                const CrossPointPosition &mapped, Moment moment);
bool pushAllowed(const std::shared_ptr<Epub> &epub,
                 const CrossPointPosition &local,
                 const KOReaderProgress *remote,
                 const CrossPointPosition &mapped, bool exempt);
void remember(const std::string &path, const KOReaderProgress &remote,
              bool wake);
bool pending(const std::string &path, KOReaderProgress &out, bool &wake);
void resolve(const std::string &path, const KOReaderProgress &remote,
             const CrossPointPosition &mapped, bool yes);
void noteTurn(const std::string &path);
bool queueOverride(const std::string &path, const KOReaderPosition &place,
                   const CrossPointPosition &local);
void drainOverrides(bool (*stop)());
void prefetch(const std::string &openPath, bool (*stop)());
// Offline before the first draw: only prefetched other books; sleep discoveries
// ask at wake.
bool prerender(const std::shared_ptr<Epub> &epub, GfxRenderer &renderer);
} // namespace OrbiSmartSync
