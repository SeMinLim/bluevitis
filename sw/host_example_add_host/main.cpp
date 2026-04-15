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
constexpr size_t kBeatBytes = 64;

constexpr uint32_t kMagic = 0x46505832u;   // "FPX2"
constexpr uint32_t kInputMagic0 = 0x13579BDFu;
constexpr uint32_t kInputMagic1 = 0x2468ACE0u;
constexpr uint64_t kInputMagic64_0 = 0x0123456789ABCDEFULL;
constexpr uint64_t kInputMagic64_1 = 0x0FEDCBA987654321ULL;

static uint32_t float_bits(float f) {
  uint32_t u = 0;
  static_assert(sizeof(u) == sizeof(f));
  std::memcpy(&u, &f, sizeof(u));
  return u;
}

static uint64_t double_bits(double d) {
  uint64_t u = 0;
  static_assert(sizeof(u) == sizeof(d));
  std::memcpy(&u, &d, sizeof(u));
  return u;
}

static string hex32(uint32_t v) {
  ostringstream oss;
  oss << "0x" << hex << uppercase << setw(8) << setfill('0') << v;
  return oss.str();
}

static string hex64(uint64_t v) {
  ostringstream oss;
  oss << "0x" << hex << uppercase << setw(16) << setfill('0') << v;
  return oss.str();
}

struct Check32 {
  const char* name;
  uint32_t observed;
  uint32_t expected;
  unsigned bit;
};

struct Check64 {
  const char* name;
  uint64_t observed;
  uint64_t expected;
  unsigned bit;
};

static bool test_bit(uint32_t mask, unsigned bit) {
  return ((mask >> bit) & 0x1u) != 0;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    cout << "Usage: " << argv[0] << " <XCLBIN File Path>\n";
    return EXIT_FAILURE;
  }

  // Beat 0: Float32 inputs
  const array<uint32_t, 16> input32{{
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
      kInputMagic0,       // lane 14: 32-bit path sentinel 0
      kInputMagic1        // lane 15: 32-bit path sentinel 1
  }};

  // Beat 1: Float64 inputs for binary ops
  const array<uint64_t, 8> input64_a{{
      double_bits(1.5),   // lane 0 : add_a
      double_bits(2.25),  // lane 1 : add_b
      double_bits(5.5),   // lane 2 : sub_a
      double_bits(2.25),  // lane 3 : sub_b
      double_bits(1.5),   // lane 4 : mul_a
      double_bits(-2.0),  // lane 5 : mul_b
      double_bits(7.5),   // lane 6 : div_a
      double_bits(2.5)    // lane 7 : div_b
  }};

  // Beat 2: Float64 inputs for unary / ternary ops + sentinels
  const array<uint64_t, 8> input64_b{{
      double_bits(9.0),   // lane 0 : sqrt_a
      double_bits(0.0),   // lane 1 : exp_a
      double_bits(1.5),   // lane 2 : fma_a
      double_bits(2.0),   // lane 3 : fma_b
      double_bits(0.5),   // lane 4 : fma_c
      double_bits(4.0),   // lane 5 : sqrtcube_a
      kInputMagic64_0,    // lane 6 : 64-bit path sentinel 0
      kInputMagic64_1     // lane 7 : 64-bit path sentinel 1
  }};

  cout << "[Float32 + Float64 self-test over direct host connection + URAM]\n";
  string xclbin_file = argv[1];

  xrt::device device{kDeviceId};
  xrt::uuid xclbin_uuid = device.load_xclbin(xclbin_file);

  cout << "[STEP 1] Create Kernel\n";
  auto krnl = xrt::kernel(device, xclbin_uuid, "kernel:{kernel_1}");

  cout << "[STEP 2] Allocate HOST[0] native XRT BOs\n";
  xrt::bo::flags flags = xrt::bo::flags::host_only;
  auto boIn  = xrt::bo(device, kBufferBytes, flags, krnl.group_id(1));
  auto boOut = xrt::bo(device, kBufferBytes, flags, krnl.group_id(2));

  auto inBytes  = boIn.map<uint8_t*>();
  auto outBytes = boOut.map<uint8_t*>();
  std::memset(inBytes,  0, kBufferBytes);
  std::memset(outBytes, 0, kBufferBytes);

  std::memcpy(inBytes + 0 * kBeatBytes, input32.data(),   kBeatBytes);
  std::memcpy(inBytes + 1 * kBeatBytes, input64_a.data(), kBeatBytes);
  std::memcpy(inBytes + 2 * kBeatBytes, input64_b.data(), kBeatBytes);

  cout << "[STEP 3] Sync BOs\n";
  boIn.sync(XCL_BO_SYNC_BO_TO_DEVICE);
  boOut.sync(XCL_BO_SYNC_BO_TO_DEVICE);

  cout << "[STEP 4] Run kernel\n";
  auto run = krnl(static_cast<uint32_t>(kBufferBytes), boIn, boOut);
  run.wait();

  cout << "[STEP 5] Read back results\n";
  boOut.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

  array<uint32_t, 16> beat0{};
  array<uint64_t, 8> beat1{};
  array<uint64_t, 8> beat2{};
  std::memcpy(beat0.data(), outBytes + 0 * kBeatBytes, kBeatBytes);
  std::memcpy(beat1.data(), outBytes + 1 * kBeatBytes, kBeatBytes);
  std::memcpy(beat2.data(), outBytes + 2 * kBeatBytes, kBeatBytes);

  const uint32_t magic        = beat0[0];
  const uint32_t status       = beat0[1];
  const uint32_t passMask     = beat0[2];
  const uint32_t cycles       = beat0[3];
  const uint32_t addObs32     = beat0[4];
  const uint32_t subObs32     = beat0[5];
  const uint32_t mulObs32     = beat0[6];
  const uint32_t divObs32     = beat0[7];
  const uint32_t sqrtObs32    = beat0[8];
  const uint32_t expObs32     = beat0[9];
  const uint32_t fmaObs32     = beat0[10];
  const uint32_t scubeObs32   = beat0[11];
  const uint32_t echoMagic0   = beat0[12];
  const uint32_t echoMagic1   = beat0[13];
  const uint32_t hostPath32   = beat0[14];
  const uint32_t hostPath64   = beat0[15];

  cout << "magic       : " << hex32(magic) << '\n';
  cout << "status      : " << hex32(status) << "  (3 means PASS)\n";
  cout << "passMask    : " << hex32(passMask) << '\n';
  cout << "cycles      : " << dec << cycles << '\n';
  cout << "host path32 : echoed0=" << hex32(echoMagic0)
       << " echoed1=" << hex32(echoMagic1)
       << " flag=" << hostPath32 << '\n';
  cout << "host path64 : echoed0=" << hex64(beat2[0])
       << " echoed1=" << hex64(beat2[1])
       << " flag=" << hostPath64 << "\n\n";

  const array<Check32, 8> checks32{{
      {"mkFpAdd32",       addObs32,   float_bits(3.75f), 0},
      {"mkFpSub32",       subObs32,   float_bits(3.25f), 1},
      {"mkFpMult32",      mulObs32,   float_bits(-3.0f), 2},
      {"mkFpDiv32",       divObs32,   float_bits(3.0f), 3},
      {"mkFpSqrt32",      sqrtObs32,  float_bits(3.0f), 4},
      {"mkFpExp32",       expObs32,   float_bits(1.0f), 5},
      {"mkFpFma32",       fmaObs32,   float_bits(3.5f), 6},
      {"mkFpSqrtCube32",  scubeObs32, float_bits(8.0f), 7},
  }};

  const array<Check64, 8> checks64{{
      {"mkFpAdd64",       beat1[0], double_bits(3.75),  8},
      {"mkFpSub64",       beat1[1], double_bits(3.25),  9},
      {"mkFpMult64",      beat1[2], double_bits(-3.0), 10},
      {"mkFpDiv64",       beat1[3], double_bits(3.0),  11},
      {"mkFpSqrt64",      beat1[4], double_bits(3.0),  12},
      {"mkFpExp64",       beat1[5], double_bits(1.0),  13},
      {"mkFpFma64",       beat1[6], double_bits(3.5),  14},
      {"mkFpSqrtCube64",  beat1[7], double_bits(8.0),  15},
  }};

  bool all_ok = true;

  if (magic != kMagic) {
    cout << "Unexpected magic. The loaded xclbin does not look like this Float32/Float64 self-test build.\n";
    all_ok = false;
  }

  const bool host_path_32_ok =
      (echoMagic0 == kInputMagic0) &&
      (echoMagic1 == kInputMagic1) &&
      (hostPath32 == 1u);

  const bool host_path_64_ok =
      (beat2[0] == kInputMagic64_0) &&
      (beat2[1] == kInputMagic64_1) &&
      (hostPath64 == 1u);

  cout << "host->URAM->kernel path (32-bit beat): "
       << (host_path_32_ok ? "OK" : "FAIL") << '\n';
  cout << "host->URAM->kernel path (64-bit beat): "
       << (host_path_64_ok ? "OK" : "FAIL") << '\n';

  all_ok &= host_path_32_ok;
  all_ok &= host_path_64_ok;

  cout << "\n[Float32 modules]\n";
  for (const auto& c : checks32) {
    const bool ok = (c.observed == c.expected) && test_bit(passMask, c.bit);
    cout << left << setw(16) << c.name
         << " observed=" << hex32(c.observed)
         << " expected=" << hex32(c.expected)
         << " bit=" << c.bit
         << " " << (ok ? "OK" : "FAIL")
         << '\n';
    all_ok &= ok;
  }

  cout << "\n[Float64 modules]\n";
  for (const auto& c : checks64) {
    const bool ok = (c.observed == c.expected) && test_bit(passMask, c.bit);
    cout << left << setw(16) << c.name
         << " observed=" << hex64(c.observed)
         << " expected=" << hex64(c.expected)
         << " bit=" << c.bit
         << " " << (ok ? "OK" : "FAIL")
         << '\n';
    all_ok &= ok;
  }

  all_ok &= (status == 3u);
  all_ok &= (passMask == 0xFFFFu);

  cout << '\n' << (all_ok ? "TEST PASSED" : "TEST FAILED") << '\n';
  return all_ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
