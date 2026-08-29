#include "MorbiusPlus.h"

#include <stdio.h>
#include <stdlib.h>

#include <algorithm>
#include <vector>
using namespace std;


static void preparePipelineStates( const Config *config,
				   const Dataset *dataset,
				   const SeedModel *seedModel,
				   vector<AccelPipelineHostState> &pipelineStates ) {
	pipelineStates.resize(ACCELMAXPIPELINE);
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		AccelPipelineHostState &state = pipelineStates[(size_t)pipelineIdx];
		initializeOffsets(config, dataset, seedModel, pipelineIdx, state.offsets);
		state.bestOffsets = state.offsets;
		buildBPM(config, dataset, state.offsets, state.initialBPM);
		state.bestScore = (uint32_t)calculateConsensusScore(config, dataset, state.initialBPM);
		state.updateNum = 0;
		state.terminated = false;
		initializeRandomGenerator(&state.randomGenerator,
					  config->randomSeed ^
					  ((uint64_t)(pipelineIdx + 1) * 0xd2b74407b1ce6e93ULL));

		for ( size_t column = 0; column < config->motifLength; column ++ ) {
			int symbol = dataset->symbolMap[
				(unsigned char)dataset->sequences[0][state.offsets[0] + column]
			];
			state.initialBPM[(size_t)symbol * config->motifLength + column] --;
		}
		buildLPMQ12(state.initialBPM, state.initialLPMQ12);
	}
}

static bool applyResults( const Config *config,
			  const Dataset *dataset,
			  size_t sequenceIdx,
			  const vector<AccelWireResult> &wireResults,
			  vector<AccelPipelineHostState> &pipelineStates ) {
	bool allDone = true;
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		AccelPipelineHostState &state = pipelineStates[(size_t)pipelineIdx];
		const AccelWireResult &wireResult = wireResults[(size_t)pipelineIdx];
		if ( wireResult.active && wireResult.updateNum > state.updateNum ) {
			if ( wireResult.newOffset + config->motifLength > dataset->sequenceLength ) {
				printf( "Pipeline %d returned an invalid new tentative-motif offset: %u\n",
					pipelineIdx,
					wireResult.newOffset
				);
				exit(1);
			}
			state.offsets[sequenceIdx] = wireResult.newOffset;
			if ( wireResult.bestUpdate ) state.bestOffsets = state.offsets;
		}
		state.bestScore = wireResult.bestScore;
		state.updateNum = wireResult.updateNum;
		state.terminated = wireResult.terminated;
		allDone = allDone && wireResult.terminated;
	}
	return allDone;
}

// Run all CPU-managed Gibbs pipelines through one accelerator kernel
void runAccelerator( const Config *config,
		     const Dataset *dataset,
		     const SeedModel *seedModel,
		     KernelExecutor executor,
		     void *executorContext,
		     vector<PipelineResult> &pipelineResults ) {
	vector<AccelPipelineHostState> pipelineStates;
	preparePipelineStates(config, dataset, seedModel, pipelineStates);
	double startTime = timeChecker();

	//--------------------------------------------------------------------------------------------
	// Zeroth iteration
	//--------------------------------------------------------------------------------------------
	vector<uint8_t> input;
	vector<uint8_t> output;
	buildBootstrapCommand(config, dataset, pipelineStates, input);
	if ( executor(input, ACCELRESULTBYTES + ACCELBEATBYTES, output, executorContext) != 0 ) {
		printf( "Morbius+ bootstrap execution failed.\n" );
		exit(1);
	}
	vector<AccelWireResult> wireResults;
	parseResultBeat(output.data(), wireResults);
	bool allDone = applyResults(config, dataset, 0, wireResults, pipelineStates);
	AccelSummary summary;
	parseSummaryBeat(output.data() + ACCELRESULTBYTES, &summary);
	if ( summary.processedNum != 1 ) {
		printf( "Morbius+ bootstrap returned an invalid processed count: %u\n", summary.processedNum );
		exit(1);
	}

	//--------------------------------------------------------------------------------------------
	// First and all subsequent iterations
	//--------------------------------------------------------------------------------------------
	size_t sequenceStart = dataset->sequences.size() == 1 ? 0 : 1;
	size_t batchLimit = min(config->batchSize, dataset->sequences.size());
	uint64_t completedUpdateNum = 1;
	while ( allDone == false ) {
		size_t batchNum = batchLimit;
		buildBatchCommand(config,
				 dataset,
				 pipelineStates,
				 sequenceStart,
				 batchNum,
				 input);
		size_t outputSize = batchNum * ACCELRESULTBYTES + ACCELBEATBYTES;
		if ( executor(input, outputSize, output, executorContext) != 0 ) {
			printf( "Morbius+ batch execution failed at sequence index %lu.\n",
				(unsigned long)sequenceStart
			);
			exit(1);
		}
		parseSummaryBeat(output.data() + batchNum * ACCELRESULTBYTES, &summary);
		if ( summary.processedNum == 0 || summary.processedNum > batchNum ) {
			printf( "Morbius+ accelerator returned an invalid processed count: %u\n",
				summary.processedNum
			);
			exit(1);
		}

		for ( uint32_t itemIdx = 0; itemIdx < summary.processedNum; itemIdx ++ ) {
			size_t sequenceIdx = (sequenceStart + itemIdx) % dataset->sequences.size();
			parseResultBeat(output.data() + (size_t)itemIdx * ACCELRESULTBYTES, wireResults);
			allDone = applyResults(config,
					       dataset,
					       sequenceIdx,
					       wireResults,
					       pipelineStates);
			completedUpdateNum ++;
		}
		sequenceStart = (sequenceStart + summary.processedNum) % dataset->sequences.size();

		if ( completedUpdateNum % dataset->sequences.size() == 0 || allDone ) {
			printf( "[STEP 3] Accelerator progress: %lu updates per active pipeline.\n",
				(unsigned long)completedUpdateNum
			);
			fflush( stdout );
		}
	}

	double elapsedTime = timeChecker() - startTime;
	pipelineResults.resize(ACCELMAXPIPELINE);
	uint64_t rawScoreThreshold = calculateRawScoreThreshold(config, dataset);
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		const AccelPipelineHostState &state = pipelineStates[(size_t)pipelineIdx];
		PipelineResult &result = pipelineResults[(size_t)pipelineIdx];
		result.bestOffsets = state.bestOffsets;
		result.bestScore = state.bestScore;
		result.updateNum = state.updateNum;
		result.thresholdReached = state.bestScore >= rawScoreThreshold;
		result.elapsedTime = elapsedTime;
		printf( "[STEP 3] Pipeline %d is done. Score: %lu, Updates: %lu\n",
			pipelineIdx,
			(unsigned long)result.bestScore,
			(unsigned long)result.updateNum
		);
	}
	fflush( stdout );
}

// Select the pipeline with the highest local best score
int selectBestPipeline( const vector<PipelineResult> &pipelineResults ) {
	int bestPipelineIdx = 0;
	for ( int pipelineIdx = 1; pipelineIdx < (int)pipelineResults.size(); pipelineIdx ++ ) {
		if ( pipelineResults[(size_t)pipelineIdx].bestScore >
		     pipelineResults[(size_t)bestPipelineIdx].bestScore ) {
			bestPipelineIdx = pipelineIdx;
		}
	}
	return bestPipelineIdx;
}
