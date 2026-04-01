#include <iostream>
#include <string>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
using namespace std;


// XRT includes
#include "xrt/xrt_bo.h"
#include <experimental/xrt_xclbin.h>
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"


#define DEVICE_ID 0
#define DATA_SIZE 65536
#define RESULTADDRESS 0


int main(int argc, char** argv) {
	if ( argc != 2 ) {
		cout << "Usage: " << argv[0] << " <XCLBIN File Path>" << endl;
		return EXIT_FAILURE;
	}

	// Load XCLBIN
	cout << "[Xilinx Alveo U50]" << endl;
	fflush( stdout );
	string xclbin_file = argv[1];
	xrt::device device = xrt::device(DEVICE_ID);
	xrt::uuid xclbin_uuid = device.load_xclbin(xclbin_file);

	// Create kernel object
	cout << "[STEP 1] Create Kernel" << endl;
	fflush( stdout );
	auto krnl = xrt::kernel(device, xclbin_uuid, "kernel:{kernel_1}");

	// Allocate buffer in global memory
	cout << "[STEP 2] Allocate Buffer in PLRAM (configured as URAM)" << endl;
	fflush( stdout );
	auto boIn  = xrt::bo(device, (size_t)DATA_SIZE, krnl.group_id(1));
	auto boOut = xrt::bo(device, (size_t)DATA_SIZE, krnl.group_id(2));

	// Map the contents of the buffer object into host memory
	auto bo0_map = boIn.map<int*>();
	auto bo1_map = boOut.map<int*>();
	fill(bo0_map, bo0_map + ((size_t)DATA_SIZE / 4), 0);
	fill(bo1_map, bo1_map + ((size_t)DATA_SIZE / 4), 0);

        // Fill PLRAM-backed buffers with 2 512-bit data
	bo0_map[0] = 1;
	bo1_map[0] = 2;
	
	// Synchronize host and global memory buffer
	cout << "[STEP 3] Synchronize input buffer data to device global memory" << endl;
	fflush( stdout );
	boIn.sync(XCL_BO_SYNC_BO_TO_DEVICE);
	boOut.sync(XCL_BO_SYNC_BO_TO_DEVICE);

	// Execute kernel
	cout << "[STEP 4] Execution of the kernel" << endl;
        fflush( stdout );
        auto run = krnl((size_t)DATA_SIZE, boIn, boOut);
        run.wait();
        
        // Get the output
        cout << "[STEP 5] Get the output data from the device" << endl;
        fflush( stdout );
        boOut.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

	printf( "%d\n", bo1_map[RESULTADDRESS] );
	// Verification
	if ( bo1_map[RESULTADDRESS] == 3 ) {
		cout << "TEST PASSED" << endl;
	} else {
		cout << "TEST FAILED" << endl;
	}

	return 0;
}

