#include "MorbiusPlus.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <exception>
#include <string>
#include <vector>

#include "xrt/xrt_bo.h"
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"
#include <experimental/xrt_xclbin.h>
using namespace std;


typedef struct XrtExecutorContext {
	xrt::device *device;
	xrt::kernel *kernel;
}XrtExecutorContext;

static size_t roundBufferSize( size_t size ) {
	const size_t pageSize = 4096;
	return ((size + pageSize - 1) / pageSize) * pageSize;
}

static int executeXrtKernel( const vector<uint8_t> &input,
			     size_t outputSize,
			     vector<uint8_t> &output,
			     void *contextValue ) {
	XrtExecutorContext *context = (XrtExecutorContext*)contextValue;
	try {
		size_t inputBufferSize = roundBufferSize(input.size());
		size_t outputBufferSize = roundBufferSize(outputSize);
		xrt::bo::flags flags = xrt::bo::flags::host_only;
		xrt::bo inputBO(*context->device,
				inputBufferSize,
				flags,
				context->kernel->group_id(1));
		xrt::bo outputBO(*context->device,
				 outputBufferSize,
				 flags,
				 context->kernel->group_id(2));
		uint8_t *inputPtr = inputBO.map<uint8_t*>();
		uint8_t *outputPtr = outputBO.map<uint8_t*>();
		memset(inputPtr, 0, inputBufferSize);
		memset(outputPtr, 0, outputBufferSize);
		memcpy(inputPtr, input.data(), input.size());
		inputBO.sync(XCL_BO_SYNC_BO_TO_DEVICE);
		outputBO.sync(XCL_BO_SYNC_BO_TO_DEVICE);
		auto run = (*context->kernel)((uint32_t)input.size(), inputBO, outputBO);
		run.wait();
		outputBO.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
		output.assign(outputPtr, outputPtr + outputSize);
	} catch ( const exception &error ) {
		printf( "XRT execution failed: %s\n", error.what() );
		fflush( stdout );
		return 1;
	}
	return 0;
}

int main( int argc, char **argv ) {
	Config config;
	parseArguments(argc, argv, &config);
	if ( config.useModel ) {
		printf( "Use obj/model for --model execution.\n" );
		return 1;
	}

	try {
		xrt::device device((unsigned int)config.deviceId);
		xrt::uuid uuid = device.load_xclbin(config.xclbinFilename);
		xrt::kernel kernel(device, uuid, "kernel:{kernel_1}");
		XrtExecutorContext context;
		context.device = &device;
		context.kernel = &kernel;
		return runMorbiusPlusApplication(&config, executeXrtKernel, &context);
	} catch ( const exception &error ) {
		printf( "Unable to initialize the U50 accelerator: %s\n", error.what() );
		fflush( stdout );
		return 1;
	}
}
