BookSync moved: https://github.com/Fledgewing/BookSync. This repo only serves update feeds for older devices.

The scheduled mirror copies public feed bytes without modifying or re-signing them.
It uses this repository's own Actions token; no cross-repository secret is needed.
Keep both feed branches indefinitely: there is no device telemetry to prove that
older readers have stopped using them.
