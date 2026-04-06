#include <array>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <algorithm>


#include "xrt/xrt_bo.h"
#include <experimental/xrt_xclbin.h>
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"


using namespace std;
namespace {
	constexpr unsigned int kDeviceId = 0;
	constexpr size_t kBufferBytes = 4096;
	constexpr uint32_t kMagic = 0x53524C5A; // 'SRLZ'
	constexpr uint32_t kHostInputWord = 0x11223344u;

	string hex32(uint32_t x) {
		ostringstream oss;
		oss << "0x" << hex << setw(8) << setfill('0') << x;
		return oss.str();
	}

	string hex64(uint64_t x) {
		ostringstream oss;
		oss << "0x" << hex << setw(16) << setfill('0') << x;
		return oss.str();
	}

	bool test_bit(uint32_t mask, int bit) {
		return ((mask >> bit) & 1u) != 0;
	}
} // namespace


int main(int argc, char** argv) {
	if (argc != 2) {
		cerr << "Usage: " << argv[0] << " <XCLBIN file>\n";
		return EXIT_FAILURE;
	}

	const string xclbin_file = argv[1];

	cout << "[Serializer self-test demo with host input over PLRAM/URAM]" << endl;
	xrt::device device{kDeviceId};
	xrt::uuid uuid = device.load_xclbin(xclbin_file);
	auto krnl = xrt::kernel(device, uuid, "kernel:{kernel_1}");

	// kernel.xml defines two pointer arguments: mem (port 0) and file (port 1).
	// This demo now actively uses boIn through port 0.
	auto boIn  = xrt::bo(device, kBufferBytes, krnl.group_id(1));
	auto boOut = xrt::bo(device, kBufferBytes, krnl.group_id(2));

	auto in  = boIn.map<uint32_t*>();
	auto out = boOut.map<uint32_t*>();
	fill(in,  in  + kBufferBytes / sizeof(uint32_t), 0u);
	fill(out, out + kBufferBytes / sizeof(uint32_t), 0u);

	// Lane 0 of the first 512-bit input word. KernelMain reads this back from
	// port 0 and uses it as the Serializer/DeSerializer test vector.
	in[0] = kHostInputWord;

	boIn.sync(XCL_BO_SYNC_BO_TO_DEVICE);
	boOut.sync(XCL_BO_SYNC_BO_TO_DEVICE);

	auto run = krnl(0u, boIn, boOut);
	run.wait();
	boOut.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

	const uint32_t magic     = out[0];
	const uint32_t status    = out[1];
	const uint32_t passMask  = out[2];
	const uint32_t cycles    = out[3];
	const uint32_t serObs    = out[4];
	const uint32_t deserObs  = out[5];
	const uint32_t repObs    = out[6];
	const uint32_t lastObs   = out[7];
	const uint32_t skipObs   = out[8];
	const uint64_t shiftObs  = (static_cast<uint64_t>(out[10]) << 32) | out[9];
	const uint32_t freeObs   = out[11];
	const uint32_t inputObs  = out[12];
	const uint32_t inputPass = out[13];

	cout << "magic      : " << hex32(magic) << '\n';
	cout << "status     : " << hex32(status) << "  (3 means PASS)\n";
	cout << "pass mask  : " << hex32(passMask) << '\n';
	cout << "host input : wrote=" << hex32(kHostInputWord) << " observed=" << hex32(inputObs) << " flag=" << inputPass << '\n';
	cout << dec << "cycles     : " << cycles << "\n\n";

	struct Check32 {
		const char* name;
		uint32_t observed;
		uint32_t expected;
		int bit;
	};

	const array<Check32, 6> checks32{{
		{"mkSerializer",          serObs,   kHostInputWord, 0},
		{"mkStreamReplicate",     repObs,   0x00A6A6A6u,    1},
		{"mkStreamSerializeLast", lastObs,  0x00000001u,    2},
		{"mkDeSerializer",        deserObs, kHostInputWord, 3},
		{"mkStreamSkip",          skipObs,  0x0000A2B2u,    4},
		{"mkSerializerFreeform",  freeObs,  0x2B79536Cu,    6},
	}};

	bool all_ok = true;

	if (magic != kMagic) {
		cout << "WARNING: unexpected magic value. The kernel may not be the serializer self-test build.\n";
		all_ok = false;
	}

	if (inputObs != kHostInputWord || inputPass != 1u) {
		cout << "PLRAM/URAM input path check failed.\n";
		all_ok = false;
	}

	for (const auto& c : checks32) {
		const bool ok = (c.observed == c.expected) && test_bit(passMask, c.bit);
		cout << left << setw(24) << c.name
		     << " observed=" << hex32(c.observed)
		     << " expected=" << hex32(c.expected)
		     << "  bit=" << c.bit
		     << "  " << (ok ? "OK" : "FAIL")
		     << '\n';
		all_ok &= ok;
	}

	const bool shift_ok = (shiftObs == 0x000FEDCBA9876543ULL) && test_bit(passMask, 5);
	cout << left << setw(24) << "mkPipelineShiftRight"
	     << " observed=" << hex64(shiftObs)
	     << " expected=" << hex64(0x000FEDCBA9876543ULL)
	     << "  bit=5"
	     << "  " << (shift_ok ? "OK" : "FAIL")
	     << '\n';
	all_ok &= shift_ok;

	all_ok &= (status == 3u);
	if (all_ok) {
		cout << "\nTEST PASSED\n";
		return EXIT_SUCCESS;
	}
	cout << "\nTEST FAILED\n";

	return EXIT_FAILURE;
}
