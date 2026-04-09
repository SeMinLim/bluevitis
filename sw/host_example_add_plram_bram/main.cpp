#include <iostream>
#include <string>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstdint>


#include "xrt/xrt_bo.h"
#include <experimental/xrt_xclbin.h>
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"


#define DEVICE_ID 0
#define TEST_CNT 16
#define WORD_LANE_CNT 8
#define WORD_BYTES 64
#define TEST_MODULE_CNT 8
#define DATA_SIZE (TEST_CNT * WORD_BYTES)


using namespace std;


static uint64_t refShiftLeft64(uint64_t data, uint32_t shift) {
	return data << shift;
}
static uint64_t refShiftRight64(uint64_t data, uint32_t shift) {
	return data >> shift;
}


int main(int argc, char** argv) {
	if ( argc != 2 ) {
		cout << "Usage: " << argv[0] << " <XCLBIN File Path>" << endl;
		return EXIT_FAILURE;
	}

	const uint64_t inputDataList[TEST_CNT] = {
		0x0000000000000001ULL,
		0x8000000000000000ULL,
		0x0123456789abcdefULL,
		0xfedcba9876543210ULL,
		0x0000ffff0000ffffULL,
		0xffff0000ffff0000ULL,
		0xaaaaaaaa55555555ULL,
		0x13579bdf2468ace0ULL,
		0x7fffffffffffffffULL,
		0xdeadbeefcafef00dULL,
		0x0102030405060708ULL,
		0x89abcdef01234567ULL,
		0x0000000100000001ULL,
		0x1111111111111111ULL,
		0x8000000000000001ULL,
		0xffffffffffffffffULL
	};
	const uint64_t shiftDataList[TEST_CNT] = {
		0, 1, 2, 3,
		4, 5, 6, 7,
		15, 31, 32, 33,
		47, 48, 62, 63
	};
	const char* moduleNameList[TEST_MODULE_CNT] = {
		"L(6,1)",
		"R(6,1)",
		"L(6,2)",
		"R(6,2)",
		"L(6,6)",
		"R(6,6)",
		"L(5,2)",
		"R(5,2)"
	};

	// Load XCLBIN
	cout << "[Xilinx Alveo U50 BLShifter Example]" << endl;
	fflush( stdout );
	string xclbin_file = argv[1];
	xrt::device device = xrt::device(DEVICE_ID);
	xrt::uuid xclbin_uuid = device.load_xclbin(xclbin_file);

	// Create kernel object
	cout << "[STEP 1] Create Kernel" << endl;
	fflush( stdout );
	auto krnl = xrt::kernel(device, xclbin_uuid, "kernel:{kernel_1}");

	// Allocate buffer in global memory
	cout << "[STEP 2] Allocate Buffer in PLRAM (configured as BRAM)" << endl;
	fflush( stdout );
	auto boIn  = xrt::bo(device, (size_t)DATA_SIZE, krnl.group_id(1));
	auto boOut = xrt::bo(device, (size_t)DATA_SIZE, krnl.group_id(2));

	// Map the contents of the buffer object into host memory
	auto bo0_map = boIn.map<uint64_t*>();
	auto bo1_map = boOut.map<uint64_t*>();
	fill(bo0_map, bo0_map + ((size_t)DATA_SIZE / sizeof(uint64_t)), 0ULL);
	fill(bo1_map, bo1_map + ((size_t)DATA_SIZE / sizeof(uint64_t)), 0ULL);

	// Fill PLRAM-backed buffers with BLShifter test data
	//   PLRAM[0] / port 0 : input data
	//   PLRAM[1] / port 1 : shift amount input -> overwritten by final results
	for ( int i = 0; i < TEST_CNT; i++ ) {
		bo0_map[i * WORD_LANE_CNT + 0] = inputDataList[i];
		bo1_map[i * WORD_LANE_CNT + 0] = shiftDataList[i];
	}
	
	// Synchronize host and global memory buffer
	cout << "[STEP 3] Synchronize input buffer data to device global memory" << endl;
	fflush( stdout );
	boIn.sync(XCL_BO_SYNC_BO_TO_DEVICE);
	boOut.sync(XCL_BO_SYNC_BO_TO_DEVICE);

	// Execute kernel
	cout << "[STEP 4] Execution of the kernel" << endl;
	fflush( stdout );
	auto run = krnl((uint32_t)TEST_CNT, boIn, boOut);
	run.wait();
	
	// Get the output
	cout << "[STEP 5] Get the output data from the device" << endl;
	fflush( stdout );
	boOut.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

	// Verification
	bool testPassed = true;
	int passCnt = 0;

	for ( int i = 0; i < TEST_CNT; i++ ) {
		uint64_t inputData = bo0_map[i * WORD_LANE_CNT + 0];
		uint32_t shift6 = (uint32_t)(shiftDataList[i] & 0x3FULL);
		uint32_t shift5 = (uint32_t)(shiftDataList[i] & 0x1FULL);

		uint64_t expectedResult[TEST_MODULE_CNT];
		expectedResult[0] = refShiftLeft64 (inputData, shift6);
		expectedResult[1] = refShiftRight64(inputData, shift6);
		expectedResult[2] = refShiftLeft64 (inputData, shift6);
		expectedResult[3] = refShiftRight64(inputData, shift6);
		expectedResult[4] = refShiftLeft64 (inputData, shift6);
		expectedResult[5] = refShiftRight64(inputData, shift6);
		expectedResult[6] = refShiftLeft64 (inputData, shift5);
		expectedResult[7] = refShiftRight64(inputData, shift5);

		bool passThisVector = true;
		for ( int j = 0; j < TEST_MODULE_CNT; j++ ) {
			if ( bo1_map[i * WORD_LANE_CNT + j] != expectedResult[j] ) {
				passThisVector = false;
			}
		}

		printf( "Test[%02d] data=0x%016llx shift6=%u shift5=%u -> %s\n",
			i,
			(unsigned long long)inputData,
			shift6,
			shift5,
			passThisVector ? "PASS" : "FAIL" );

		if ( passThisVector ) {
			passCnt = passCnt + 1;
		} else {
			testPassed = false;
			for ( int j = 0; j < TEST_MODULE_CNT; j++ ) {
				if ( bo1_map[i * WORD_LANE_CNT + j] != expectedResult[j] ) {
					printf( "  %-8s : got=0x%016llx expected=0x%016llx\n",
						moduleNameList[j],
						(unsigned long long)bo1_map[i * WORD_LANE_CNT + j],
						(unsigned long long)expectedResult[j] );
				}
			}
		}
	}

	cout << "Passed " << passCnt << " / " << TEST_CNT << " test vectors" << endl;

	if ( testPassed ) {
		cout << "TEST PASSED" << endl;
		return EXIT_SUCCESS;
	} else {
		cout << "TEST FAILED" << endl;
		return EXIT_FAILURE;
	}
}
