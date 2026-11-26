// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the actual patched Memory.h with the pinned upstream capability heap.
#include <esp_heap_caps.h>
#include <cstring>
#include <cstdio>
void* dirtyAllocation(size_t size, uint32_t caps) {
  void* p=heap_caps_malloc(size,caps);
  if(p)std::memset(p,0xA5,size);  // PNG's first previous row must never inherit this.
  return p;
}
#define heap_caps_malloc dirtyAllocation
#include <Memory.h>
#undef heap_caps_malloc
struct Image {
  static inline int live=0;
  int value=17;
  Image(){++live;}
  ~Image(){--live;}
};
int main() {
  fakeheap::reset();
  const auto internal=fakeheap::internal.free;
  for(int page=0;page<100;++page) {
    {
      auto bytes=makeImageByteBufferNoThrow(2048);
      assert(bytes && fakeheap::live.at(bytes.get()).external);
      for(size_t i=0;i<2048;++i)assert(bytes[i]==0);
      auto image=makeImageObjectNoThrow<Image>();
      assert(image && image->value==17 && Image::live==1);
      assert(fakeheap::live.at(image.get()).external);
      assert(fakeheap::internal.free==internal);
    }
    assert(Image::live==0 && fakeheap::live.empty());
  }
  fakeheap::external.fail=1;
  assert(!makeImageByteBufferNoThrow(2048));
  assert(fakeheap::internal.attempts==0);  // fail soft; do not consume the PHY reserve
  fakeheap::reset(false);  // X3: preserve the internal-heap fallback and zeroing.
  {
    auto bytes=makeImageByteBufferNoThrow(2048);
    assert(bytes && !fakeheap::live.at(bytes.get()).external);
    for(size_t i=0;i<2048;++i)assert(bytes[i]==0);
  }
  assert(fakeheap::live.empty());
  assert(!makeImageByteBufferNoThrow(0));
  std::puts("image-memory: PSRAM placement, zeroed PNG rows, cleanup and X3 fallback pass");
}
