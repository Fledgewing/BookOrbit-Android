// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cstddef>
namespace orbify::catalog {
// Refresh stores rows plus numeric ranks, never URL-shaped pages. Both source
// pages and browser windows address the same sequence by its absolute offset.
constexpr size_t FETCH_SIZE = 100, BROWSE_SIZE = 20;
struct Window {
  size_t offset, size;
  static Window page(size_t number, size_t size) {
    return {(std::max(size_t(1),number)-1)*size,size};
  }
  size_t end(size_t total) const {return offset>=total?total:offset+std::min(size,total-offset);}
};
}  // namespace orbify::catalog
