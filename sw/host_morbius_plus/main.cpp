#include "MorbiusPlus.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
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
	xrt::kernel *kernel;
	xrt::bo *inputBO;
	xrt::bo *outputBO;
	uint8_t *inputPtr;
	uint8_t *outputPtr;
	size_t inputBufferSize;
	size_t outputBufferSize;
}XrtExecutorContext;

static size_t roundBufferSize( size_t size ) {
	const size_t pageSize = 4096;
	if ( size > SIZE_MAX - (pageSize - 1) ) {
		printf( "The requested XRT buffer size is too large.\n" );
		fflush( stdout );
		exit(1);
	}
	return ((size + pageSize - 1) / pageSize) * pageSize;
}

static size_t calculateInputBufferSize( const Config *config ) {
	const size_t maximumSequenceBeatNum =
		(ACCELMAXSEQUENCELENGTH + ACCELBEATBYTES - 1) / ACCELBEATBYTES;
	const size_t maximumSequenceBytes = maximumSequenceBeatNum * ACCELBEATBYTES;
	const size_t bootstrapPipelineBytes =
		ACCELBEATBYTES +
		2 * ACCELMAXMOTIFLENGTH * ACCELBEATBYTES;
	const size_t bootstrapBytes =
		ACCELBEATBYTES +
		maximumSequenceBytes +
		ACCELMAXPIPELINE * bootstrapPipelineBytes;
	const size_t batchItemBytes = maximumSequenceBytes + ACCELBEATBYTES;

	if ( config->batchSize > (SIZE_MAX - ACCELBEATBYTES) / batchItemBytes ) {
		printf( "The requested accelerator batch size is too large.\n" );
		fflush( stdout );
		exit(1);
	}
	size_t batchBytes = ACCELBEATBYTES + config->batchSize * batchItemBytes;
	size_t inputBufferSize = bootstrapBytes;
	if ( batchBytes > inputBufferSize ) inputBufferSize = batchBytes;
	return roundBufferSize(inputBufferSize);
}

static size_t calculateOutputBufferSize( const Config *config ) {
	if ( config->batchSize > SIZE_MAX / ACCELBEATBYTES - 1 ) {
		printf( "The requested accelerator batch size is too large.\n" );
		fflush( stdout );
		exit(1);
	}
	size_t batchBytes = (config->batchSize + 1) * ACCELBEATBYTES;
	size_t bootstrapBytes = 2 * ACCELBEATBYTES;
	size_t outputBufferSize = bootstrapBytes;
	if ( batchBytes > outputBufferSize ) outputBufferSize = batchBytes;
	return roundBufferSize(outputBufferSize);
}

static int executeXrtKernel( const vector<uint8_t> &input,
			     size_t outputSize,
			     vector<uint8_t> &output,
			     void *contextValue ) {
	XrtExecutorContext *context = (XrtExecutorContext*)contextValue;
	if ( input.empty() || input.size() > context->inputBufferSize ) {
		printf( "Invalid Morbius+ accelerator input size: %lu bytes.\n",
			(unsigned long)input.size()
		);
		fflush( stdout );
		return 1;
	}
	if ( input.size() > 0xffffffffULL ) {
		printf( "The Morbius+ accelerator input exceeds the 32-bit kernel argument.\n" );
		fflush( stdout );
		return 1;
	}
	if ( outputSize == 0 || outputSize > context->outputBufferSize ) {
		printf( "Invalid Morbius+ accelerator output size: %lu bytes.\n",
			(unsigned long)outputSize
		);
		fflush( stdout );
		return 1;
	}

	try {
		memset(context->inputPtr, 0, input.size());
		memset(context->outputPtr, 0, outputSize);
		memcpy(context->inputPtr, input.data(), input.size());
		context->inputBO->sync(XCL_BO_SYNC_BO_TO_DEVICE, input.size(), 0);
		context->outputBO->sync(XCL_BO_SYNC_BO_TO_DEVICE, outputSize, 0);
		auto run = (*context->kernel)((uint32_t)input.size(),
					     *context->inputBO,
					     *context->outputBO);
		run.wait();
		context->outputBO->sync(XCL_BO_SYNC_BO_FROM_DEVICE, outputSize, 0);
		output.assign(context->outputPtr, context->outputPtr + outputSize);
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

		// Retain the direct-host BO mappings across every kernel invocation.
		size_t inputBufferSize = calculateInputBufferSize(&config);
		size_t outputBufferSize = calculateOutputBufferSize(&config);
		xrt::bo::flags flags = xrt::bo::flags::host_only;
		xrt::bo inputBO(device,
				inputBufferSize,
				flags,
				kernel.group_id(1));
		xrt::bo outputBO(device,
				 outputBufferSize,
				 flags,
				 kernel.group_id(2));
		uint8_t *inputPtr = inputBO.map<uint8_t*>();
		uint8_t *outputPtr = outputBO.map<uint8_t*>();
		if ( inputPtr == NULL || outputPtr == NULL ) {
			printf( "Unable to map the persistent Morbius+ XRT buffers.\n" );
			fflush( stdout );
			return 1;
		}
		memset(inputPtr, 0, inputBufferSize);
		memset(outputPtr, 0, outputBufferSize);

		XrtExecutorContext context;
		context.kernel = &kernel;
		context.inputBO = &inputBO;
		context.outputBO = &outputBO;
		context.inputPtr = inputPtr;
		context.outputPtr = outputPtr;
		context.inputBufferSize = inputBufferSize;
		context.outputBufferSize = outputBufferSize;
		return runMorbiusPlusApplication(&config, executeXrtKernel, &context);
	} catch ( const exception &error ) {
		printf( "Unable to initialize the U50 accelerator: %s\n", error.what() );
		fflush( stdout );
		return 1;
	}
}
