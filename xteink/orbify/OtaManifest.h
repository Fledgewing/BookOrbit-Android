#pragma once

// esp_http_client emits ON_DATA for redirect/error bodies too. Only feed the
// final success response into the streaming release parser.
namespace orbify::ota_manifest {
template <class Parser>
void feed(Parser& parser, int status, const char* data, int length) {
  if (status == 200 && length > 0) parser.feed(data, length);
}
}  // namespace orbify::ota_manifest
