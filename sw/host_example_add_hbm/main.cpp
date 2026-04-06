#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <string>


#include "xrt/xrt_bo.h"
#include <experimental/xrt_xclbin.h>
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"


#define DEVICE_ID 0
#define BUF_BYTES 64


using namespace std;


static uint32_t crc32_reflected_32(uint32_t crc, uint32_t word) {
	for (int i = 0; i < 32; ++i) {
		uint32_t fb = (crc ^ (word >> i)) & 1u;
		crc >>= 1;
		if (fb) crc ^= 0xEDB88320u;
	}

	return crc;
}
static uint32_t crc32c_reflected_32(uint32_t crc, uint32_t word) {
	for (int i = 0; i < 32; ++i) {
		uint32_t fb = (crc ^ (word >> i)) & 1u;
		crc >>= 1;
		if (fb) crc ^= 0x82F63B78u;
	}

	return crc;
}
static uint32_t load_le32(const uint8_t* p) {
	return (static_cast<uint32_t>(p[0]))       | (static_cast<uint32_t>(p[1]) << 8) | 
	       (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}


int main(int argc, char** argv) {
	if (argc != 2) {
		cout << "Usage: " << argv[0] << " <XCLBIN File Path>" << endl;
		return EXIT_FAILURE;
	}

	// Fixed 8-byte test vector consumed by the kernel from bits [63:0]
	const array<uint8_t, 8> test_bytes = {
		static_cast<uint8_t>('1'), static_cast<uint8_t>('2'),
		static_cast<uint8_t>('3'), static_cast<uint8_t>('4'),
		static_cast<uint8_t>('5'), static_cast<uint8_t>('6'),
		static_cast<uint8_t>('7'), static_cast<uint8_t>('8')
	};

	const uint32_t lo32 = load_le32(test_bytes.data() + 0);
	const uint32_t hi32 = load_le32(test_bytes.data() + 4);
	const uint32_t sw_crc32_mid  = crc32_reflected_32 (0xFFFFFFFFu, lo32);
	const uint32_t sw_crc32      = crc32_reflected_32 (sw_crc32_mid,  hi32);
	const uint32_t sw_crc32c_mid = crc32c_reflected_32(0xFFFFFFFFu, lo32);
	const uint32_t sw_crc32c     = crc32c_reflected_32(sw_crc32c_mid, hi32);

	cout << "[Xilinx Alveo U50 CRC Example]" << endl;
	cout << "Input bytes : \"12345678\"" << endl;
	cout << hex << setfill('0');
	cout << "SW CRC32 mid: 0x" << setw(8) << sw_crc32_mid << endl;
	cout << "SW CRC32    : 0x" << setw(8) << sw_crc32 << endl;
	cout << "SW CRC32Cmid: 0x" << setw(8) << sw_crc32c_mid << endl;
	cout << "SW CRC32C   : 0x" << setw(8) << sw_crc32c << endl;

	// Load XCLBIN
	string xclbin_file = argv[1];
	xrt::device device = xrt::device(DEVICE_ID);
	xrt::uuid xclbin_uuid = device.load_xclbin(xclbin_file);

	// Create kernel object
	auto krnl = xrt::kernel(device, xclbin_uuid, "kernel:{kernel_1}");

	// Allocate input/output buffers
	auto boIn  = xrt::bo(device, static_cast<size_t>(BUF_BYTES), krnl.group_id(1));
	auto boOut = xrt::bo(device, static_cast<size_t>(BUF_BYTES), krnl.group_id(2));

	auto in_map  = boIn.map<uint8_t*>();
	auto out_map = boOut.map<uint8_t*>();

	std::fill(in_map,  in_map  + BUF_BYTES, 0);
	std::fill(out_map, out_map + BUF_BYTES, 0);
	std::memcpy(in_map, test_bytes.data(), test_bytes.size());

	// Sync input to device
	boIn.sync(XCL_BO_SYNC_BO_TO_DEVICE);

	// Run kernel. Scalar arg is unused in this example.
	auto run = krnl(0u, boIn, boOut);
	run.wait();

	// Fetch result from device
	boOut.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

	uint32_t hw_crc32  = 0;
	uint32_t hw_crc32c = 0;
	std::memcpy(&hw_crc32,  out_map + 0, 4);
	std::memcpy(&hw_crc32c, out_map + 4, 4);

	cout << "HW CRC32    : 0x" << setw(8) << hw_crc32 << endl;
	cout << "HW CRC32C   : 0x" << setw(8) << hw_crc32c << endl;

	bool pass = (hw_crc32 == sw_crc32) && (hw_crc32c == sw_crc32c);
	cout << (pass ? "TEST PASSED" : "TEST FAILED") << endl;

	return pass ? EXIT_SUCCESS : EXIT_FAILURE;
}
