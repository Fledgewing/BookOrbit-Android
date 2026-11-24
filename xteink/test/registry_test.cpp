// shared/fixtures/REGISTRY.json against the Xteink host tests: every rule table that names "cpp"
// as a reader is marked read ("@fixture <file>#<section>", or "@fixture <file>" for a whole file)
// by a test in xteink/test, and no test marks one the registry does not give to "cpp". The
// plugin's test_registry.lua also checks that every table has a row.
#include <filesystem>
#include <fstream>
#include <map>
#include <regex>
#include <set>
#include <sstream>

#include "TestSupport.h"

namespace fs = std::filesystem;

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  // argv[1] is shared/fixtures/bookorbit, as for the other tests.
  const fs::path root = fs::path(argv[1]).parent_path();
  JsonDocument doc;
  if (!loadJsonFile((root / "REGISTRY.json").string().c_str(), doc)) return 1;

  std::set<std::string> given;
  for (JsonObjectConst r : doc["tables"].as<JsonArrayConst>()) {
    bool mine = false;
    for (JsonVariantConst who : r["readers"].as<JsonArrayConst>()) mine = mine || who == "cpp";
    if (!mine) continue;
    std::string id = r["file"].as<std::string>();
    if (!r["section"].isNull()) id += "#" + r["section"].as<std::string>();
    given.insert(id);
  }

  // The marks in this folder's tests (this file excepted: it names the mark, it reads nothing).
  const fs::path tests = fs::path(__FILE__).parent_path();
  const std::regex mark("@fixture ([\\w./-]+(?:#[\\w.]+)?)");
  std::map<std::string, std::string> marks;
  for (const auto& e : fs::directory_iterator(tests)) {
    const std::string ext = e.path().extension().string();
    if (!e.is_regular_file() || e.path().filename() == "registry_test.cpp") continue;
    if (ext != ".cpp" && ext != ".h" && ext != ".c" && ext != ".sh") continue;
    std::ifstream in(e.path());
    std::stringstream text;
    text << in.rdbuf();
    const std::string s = text.str();
    for (std::sregex_iterator m(s.begin(), s.end(), mark), end; m != end; ++m) {
      marks[(*m)[1].str()] = e.path().filename().string();
    }
  }

  CHECK(!given.empty());
  for (const std::string& id : given) {
    CHECK_NAMED(("no Xteink host test reads " + id + " (mark it '@fixture " + id + "')").c_str(), marks.count(id) == 1);
  }
  for (const auto& [id, where] : marks) {
    CHECK_NAMED((where + " marks " + id + ", which REGISTRY.json does not give to cpp").c_str(), given.count(id) == 1);
  }
  return report("registry");
}
