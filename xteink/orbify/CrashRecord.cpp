#include "CrashRecord.h"

#include <BoardConfig.h>
#include <Logging.h>

#if FREEINK_MCU_S3 && !defined(SIMULATOR) && CONFIG_ESP_COREDUMP_ENABLE_TO_FLASH && CONFIG_ESP_COREDUMP_DATA_FORMAT_ELF
#include <esp_app_desc.h>
#include <esp_core_dump.h>
#include <esp_flash.h>
#include <nvs.h>

#include <cstdio>
#include <memory>

#include "core/BootTrail.h"

namespace orbify {

void logCrashRecord() {
  size_t addr = 0;
  size_t size = 0;
  if (esp_core_dump_image_get(&addr, &size) != ESP_OK || size < 8) {
    LOG_INF("BOOT", "Crash record: none");
    return;
  }
  // The record ends with its CRC32: it tells a record already reported from a new one.
  uint32_t crc = 0;
  if (esp_flash_read(nullptr, &crc, addr + size - sizeof(crc), sizeof(crc)) != ESP_OK) crc = 0;
  uint32_t reported = 0;
  nvs_handle_t nvs = 0;
  const bool nvsOpen = nvs_open("orbify", NVS_READWRITE, &nvs) == ESP_OK;
  if (nvsOpen) nvs_get_u32(nvs, "crashCrc", &reported);

  std::unique_ptr<esp_core_dump_summary_t> summary(new (std::nothrow) esp_core_dump_summary_t());
  const bool haveSummary = summary && esp_core_dump_get_summary(summary.get()) == ESP_OK;
  const char* dumpSha = haveSummary ? reinterpret_cast<const char*>(summary->app_elf_sha256) : "";
  char runningSha[17] = {};
  esp_app_get_elf_sha256(runningSha, sizeof(runningSha));
  const char* build = boottrail::sameBuild(dumpSha, runningSha) ? "this build" : "an earlier build";

  if (crc != 0 && crc == reported) {
    LOG_INF("BOOT", "Crash record: the one reported before (crc %08lx), from %s (app %s)",
            static_cast<unsigned long>(crc), build, dumpSha);
  } else if (!haveSummary) {
    LOG_ERR("BOOT", "Crash record: new (crc %08lx, %u bytes at 0x%x), unreadable summary",
            static_cast<unsigned long>(crc), static_cast<unsigned>(size), static_cast<unsigned>(addr));
  } else {
    char reason[128] = {};
    if (esp_core_dump_get_panic_reason(reason, sizeof(reason)) != ESP_OK) snprintf(reason, sizeof(reason), "?");
    LOG_ERR("BOOT", "Crash record: new, from %s (app %s, running %.9s): task %s, PC 0x%08lx: %s", build, dumpSha,
            runningSha, summary->exc_task, static_cast<unsigned long>(summary->exc_pc), reason);
    char bt[16 * 11 + 1] = {};
    size_t used = 0;
    const uint32_t depth = summary->exc_bt_info.depth < 16 ? summary->exc_bt_info.depth : 16;
    for (uint32_t i = 0; i < depth && used + 11 < sizeof(bt); ++i) {
      used += snprintf(bt + used, sizeof(bt) - used, " 0x%08lx", static_cast<unsigned long>(summary->exc_bt_info.bt[i]));
    }
    LOG_ERR("BOOT", "Crash record backtrace:%s%s", bt, summary->exc_bt_info.corrupted ? " (corrupted)" : "");
    if (nvsOpen && crc != 0) {
      nvs_set_u32(nvs, "crashCrc", crc);
      nvs_commit(nvs);
    }
  }
  if (nvsOpen) nvs_close(nvs);
}

}  // namespace orbify

#else

namespace orbify {
void logCrashRecord() {}
}  // namespace orbify

#endif
