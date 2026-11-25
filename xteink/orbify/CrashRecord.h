#pragma once
// Orbify: the core dump partition at boot, in the log. A panic writes one; nothing
// read or erased it, so one found later could be from any earlier build (the dump read after the
// .167 hang on the X4 Pro was .141's). Each boot logs whether a record is there, which build wrote
// it (orbify/core/BootTrail.h sameBuild) and whether an earlier boot already reported it; a new
// one gets its task, PC and backtrace in the log. The record stays in flash for a full read.
// S3 boards only (the X4 Pro and X4 Classic): the X3's app slot has no room for it.
namespace orbify {
void logCrashRecord();
}
