#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>

#include "xrt/xrt_bo.h"
#include <experimental/xrt_xclbin.h>
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"

using namespace std;

constexpr unsigned int kDeviceId = 0;
constexpr size_t kBufferBytes = 4096;
constexpr uint32_t kMagic = 0x46503332u;      // "FP32"
constexpr uint32_t kInputMagic0 = 0x13579BDFu;
constexpr uint32_t kInputMagic1 = 0x2468ACE0u;

static uint32_t float_bits(float f) {
  uint32_t u = 0;
  static_assert(sizeof(u) == sizeof(f));
  std::memcpy(&u, &f, sizeof(u));
  return u;
}

static string hex32(uint32_t v) {
  ostringstream oss;
  oss << "0x" << hex << uppercase << setw(8) << setfill('0') << v;
  return oss.str();
}

struct Check32 {
  const char* name;
  uint32_t observed;
  uint32_t expected;
  unsigned bit;
};

static bool test_bit(uint32_t mask, unsigned bit) {
  return (mask >> bit) & 0x1u;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    cout << "Usage: " << argv[0] << " <XCLBIN File Path>\n";
    return EXIT_FAILURE;
  }

  const array<uint32_t, 16> input_lanes{{
      float_bits(1.5f),   // lane 0 : add_a
      float_bits(2.25f),  // lane 1 : add_b
      float_bits(5.5f),   // lane 2 : sub_a
      float_bits(2.25f),  // lane 3 : sub_b
      float_bits(1.5f),   // lane 4 : mul_a
      float_bits(-2.0f),  // lane 5 : mul_b
      float_bits(7.5f),   // lane 6 : div_a
      float_bits(2.5f),   // lane 7 : div_b
      float_bits(9.0f),   // lane 8 : sqrt_a
      float_bits(0.0f),   // lane 9 : exp_a
      float_bits(1.5f),   // lane 10: fma_a
      float_bits(2.0f),   // lane 11: fma_b
      float_bits(0.5f),   // lane 12: fma_c
      float_bits(4.0f),   // lane 13: sqrtcube_a
      kInputMagic0,       // lane 14: host/URAM path sentinel 0
      kInputMagic1        // lane 15: host/URAM path sentinel 1
  }};

  cout << "[Float32 self-test over direct host connection + URAM]\n";
  string xclbin_file = argv[1];

  xrt::device device{kDeviceId};
  xrt::uuid xclbin_uuid = device.load_xclbin(xclbin_file);

  cout << "[STEP 1] Create Kernel\n";
  auto krnl = xrt::kernel(device, xclbin_uuid, "kernel:{kernel_1}");

  cout << "[STEP 2] Allocate HOST[0] native XRT BOs\n";
  xrt::bo::flags flags = xrt::bo::flags::host_only;
  auto boIn  = xrt::bo(device, kBufferBytes, flags, krnl.group_id(1));
  auto boOut = xrt::bo(device, kBufferBytes, flags, krnl.group_id(2));

  auto in  = boIn.map<uint32_t*>();
  auto out = boOut.map<uint32_t*>();
  fill(in,  in  + (kBufferBytes / sizeof(uint32_t)), 0u);
  fill(out, out + (kBufferBytes / sizeof(uint32_t)), 0u);

  for (size_t i = 0; i < input_lanes.size(); ++i)
    in[i] = input_lanes[i];

  cout << "[STEP 3] Sync BOs\n";
  boIn.sync(XCL_BO_SYNC_BO_TO_DEVICE);
  boOut.sync(XCL_BO_SYNC_BO_TO_DEVICE);

  cout << "[STEP 4] Run kernel\n";
  auto run = krnl(static_cast<uint32_t>(kBufferBytes), boIn, boOut);
  run.wait();

  cout << "[STEP 5] Read back results\n";
  boOut.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

  const uint32_t magic        = out[0];
  const uint32_t status       = out[1];
  const uint32_t passMask     = out[2];
  const uint32_t cycles       = out[3];
  const uint32_t addObs       = out[4];
  const uint32_t subObs       = out[5];
  const uint32_t mulObs       = out[6];
  const uint32_t divObs       = out[7];
  const uint32_t sqrtObs      = out[8];
  const uint32_t expObs       = out[9];
  const uint32_t fmaObs       = out[10];
  const uint32_t sqrtCubeObs  = out[11];
  const uint32_t echoedMagic0 = out[12];
  const uint32_t echoedMagic1 = out[13];
  const uint32_t hostPathPass = out[14];

  cout << "magic       : " << hex32(magic) << '\n';
  cout << "status      : " << hex32(status) << "  (3 means PASS)\n";
  cout << "passMask    : " << hex32(passMask) << '\n';
  cout << "cycles      : " << dec << cycles << '\n';
  cout << "host path   : echoed0=" << hex32(echoedMagic0)
       << " echoed1=" << hex32(echoedMagic1)
       << " flag=" << hostPathPass << "\n\n";

  const array<Check32, 8> checks{{
      {"mkFpAdd32",       addObs,      0x40700000u, 0},
      {"mkFpSub32",       subObs,      0x40500000u, 1},
      {"mkFpMult32",      mulObs,      0xC0400000u, 2},
      {"mkFpDiv32",       divObs,      0x40400000u, 3},
      {"mkFpSqrt32",      sqrtObs,     0x40400000u, 4},
      {"mkFpExp32",       expObs,      0x3F800000u, 5},
      {"mkFpFma32",       fmaObs,      0x40600000u, 6},
      {"mkFpSqrtCube32",  sqrtCubeObs, 0x41000000u, 7},
  }};

  bool all_ok = true;

  if (magic != kMagic) {
    cout << "Unexpected magic. The loaded xclbin does not look like this Float32 self-test build.\n";
    all_ok = false;
  }

  const bool host_path_ok =
      (echoedMagic0 == kInputMagic0) &&
      (echoedMagic1 == kInputMagic1) &&
      (hostPathPass == 1u);

  cout << "host->URAM->kernel path : " << (host_path_ok ? "OK" : "FAIL") << '\n';
  all_ok &= host_path_ok;

  for (const auto& c : checks) {
    const bool ok = (c.observed == c.expected) && test_bit(passMask, c.bit);
    cout << left << setw(16) << c.name
         << " observed=" << hex32(c.observed)
         << " expected=" << hex32(c.expected)
         << " bit=" << c.bit
         << " " << (ok ? "OK" : "FAIL")
         << '\n';
    all_ok &= ok;
  }

  all_ok &= (status == 3u);
  all_ok &= (passMask == 0xFFu);

  cout << '\n' << (all_ok ? "TEST PASSED" : "TEST FAILED") << '\n';
  return all_ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
