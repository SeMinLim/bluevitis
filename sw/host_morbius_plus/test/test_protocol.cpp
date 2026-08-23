#include "../MorbiusPlus.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include <string>
#include <vector>
using namespace std;


static void initializeTestDataset( Config *config, Dataset *dataset ) {
	config->alphabetMode = ALPHABET_DNA;
	config->motifLength = 4;
	config->numPipeline = 1;
	config->maxUpdateNum = 2;
	config->scoreThreshold = 249.0;
	config->randomSeed = 1;
	config->batchSize = 1;
	configureAlphabet(ALPHABET_DNA, dataset);
	dataset->names.push_back("test");
	dataset->sequences.push_back("ACGTACGTACGTACGT");
	dataset->sequenceLength = 16;
}

static void initializeTestStates( const Config *config,
				  vector<AccelPipelineHostState> &states ) {
	states.resize(ACCELMAXPIPELINE);
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		AccelPipelineHostState &state = states[(size_t)pipelineIdx];
		state.offsets.assign(1, 0);
		state.bestOffsets = state.offsets;
		state.initialBPM.assign(4 * config->motifLength, 1);
		state.initialLPMQ12.assign(4 * config->motifLength, 0);
		for ( size_t column = 0; column < config->motifLength; column ++ ) {
			state.initialBPM[column * config->motifLength + column] = 8;
			state.initialLPMQ12[column * config->motifLength + column] = 3U << 12;
		}
		state.randomGenerator.state[0] = 0x44556677U;
		state.randomGenerator.state[1] = 0x00112233U;
		state.randomGenerator.state[2] = 0x89abcdefU;
		state.randomGenerator.state[3] = 0x01234567U;
		state.bestScore = 32;
		state.updateNum = 0;
		state.terminated = pipelineIdx != 0;
	}
}

static void validatePWL( void ) {
	double maxLogError = 0.0;
	for ( uint32_t count = 1; count <= 200000; count ++ ) {
		double observed = (double)calculateLog2PWLQ12(count) / 4096.0;
		double expected = log2((double)count);
		maxLogError = fmax(maxLogError, fabs(observed - expected));
	}
	if ( maxLogError > 0.0012 ) {
		printf( "Log2 PWL validation failed: %.10f\n", maxLogError );
		exit(1);
	}

	double maxExpError = 0.0;
	for ( uint32_t integerPart = 0; integerPart <= 18; integerPart ++ ) {
		for ( uint32_t fraction = 0; fraction < 4096; fraction ++ ) {
			uint32_t differenceQ12 = (integerPart << 12) | fraction;
			double observed = (double)calculateExp2PWLQ18(differenceQ12) / 262144.0;
			double expected = exp2(-(double)differenceQ12 / 4096.0);
			maxExpError = fmax(maxExpError, fabs(observed - expected));
		}
	}
	if ( maxExpError > 0.00024 ) {
		printf( "Exp2 PWL validation failed: %.10f\n", maxExpError );
		exit(1);
	}
	printf( "PWL validation passed. Log2 max error: %.10f, Exp2 max error: %.10f\n",
		maxLogError,
		maxExpError
	);
}

int main( void ) {
	validatePWL();
	Config config;
	Dataset dataset;
	initializeTestDataset(&config, &dataset);
	vector<AccelPipelineHostState> states;
	initializeTestStates(&config, states);
	vector<uint8_t> input;
	vector<uint8_t> output;
	vector<AccelWireResult> results;

	resetModelKernel();
	buildBootstrapCommand(&config, &dataset, states, input);
	if ( executeModelKernel(input, 2 * ACCELBEATBYTES, output, NULL) != 0 ) {
		printf( "Bootstrap protocol test failed to execute.\n" );
		return 1;
	}
	parseResultBeat(output.data(), results);
	if ( results[0].newOffset != 12 || results[0].bestScore != 36 ||
	     results[0].updateNum != 1 || results[0].bestUpdate == false ||
	     results[0].terminated ) {
		printf( "Bootstrap protocol mismatch: offset=%u score=%u update=%u bestUpdate=%d terminated=%d\n",
			results[0].newOffset,
			results[0].bestScore,
			results[0].updateNum,
			results[0].bestUpdate,
			results[0].terminated
		);
		return 1;
	}

	buildBatchCommand(&config, &dataset, states, 0, 1, input);
	if ( executeModelKernel(input, 2 * ACCELBEATBYTES, output, NULL) != 0 ) {
		printf( "Update protocol test failed to execute.\n" );
		return 1;
	}
	parseResultBeat(output.data(), results);
	if ( results[0].newOffset != 4 || results[0].bestScore != 36 ||
	     results[0].updateNum != 2 || results[0].bestUpdate ||
	     results[0].terminated == false ) {
		printf( "Update protocol mismatch: offset=%u score=%u update=%u bestUpdate=%d terminated=%d\n",
			results[0].newOffset,
			results[0].bestScore,
			results[0].updateNum,
			results[0].bestUpdate,
			results[0].terminated
		);
		return 1;
	}
	printf( "All accelerator protocol tests passed.\n" );
	return 0;
}
