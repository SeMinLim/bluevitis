#include "MorbiusPlus.h"

#include <stdio.h>

#include <string>
#include <vector>
using namespace std;


int runMorbiusPlusApplication( Config *config,
			       KernelExecutor executor,
			       void *executorContext ) {
	Dataset dataset;
	configureAlphabet(config->alphabetMode, &dataset);

	//--------------------------------------------------------------------------------------------
	// [STEP 1]
	// Read and validate the input sequence dataset
	//--------------------------------------------------------------------------------------------
	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 1] Reading sequence FASTA file is started!\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );
	readFASTA(config->inputFilename, &dataset);
	validateWorkload(config, &dataset);
	if ( config->maxUpdateNum == 0 ) {
		config->maxUpdateNum = (uint64_t)DEFAULTMAXSWEEPNUM * (uint64_t)dataset.sequences.size();
	}
	printf( "[STEP 1] Reading sequence FASTA file is done!\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	//--------------------------------------------------------------------------------------------
	// [STEP 2]
	// Build the Markov-adjusted Seed Initializer
	//--------------------------------------------------------------------------------------------
	printf( "[STEP 2] Building the Markov-adjusted Seed Initializer is started!\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );
	double seedStartTime = timeChecker();
	SeedModel seedModel;
	buildSeedModel(config, &dataset, &seedModel);
	double seedElapsedTime = timeChecker() - seedStartTime;
	printf( "[STEP 2] Building the Markov-adjusted Seed Initializer is done!\n" );
	printf( "Seed Initialization Time: %.8f\n", seedElapsedTime );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	//--------------------------------------------------------------------------------------------
	// [STEP 3]
	// Run independent FPGA Gibbs pipelines
	//--------------------------------------------------------------------------------------------
	printf( "[STEP 3] Running Morbius+ FPGA Gibbs pipelines is started!\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );
	double processStartTime = timeChecker();
	vector<PipelineResult> pipelineResults;
	runAccelerator(config,
		       &dataset,
		       &seedModel,
		       executor,
		       executorContext,
		       pipelineResults);
	double processElapsedTime = timeChecker() - processStartTime;
	printf( "[STEP 3] Running Morbius+ FPGA Gibbs pipelines is done!\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	//--------------------------------------------------------------------------------------------
	// [STEP 4]
	// Select and store the best pipeline result
	//--------------------------------------------------------------------------------------------
	printf( "[STEP 4] Selecting and storing the best result is started!\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );
	int bestPipelineIdx = selectBestPipeline(pipelineResults);
	const vector<uint32_t> &bestOffsets = pipelineResults[(size_t)bestPipelineIdx].bestOffsets;
	vector<uint32_t> resultCount;
	buildResultCount(config, &dataset, bestOffsets, resultCount);
	string consensus = buildConsensus(config, &dataset, resultCount);
	createOutputDirectory(config->outputPrefix);
	writeMotifFASTA(config, &dataset, bestOffsets);
	writeOffsets(config, &dataset, bestOffsets);
	writePWM(config, &dataset, resultCount);
	writeMEME(config, &dataset, resultCount);
	writeSummary(config,
		     &dataset,
		     &seedModel,
		     pipelineResults,
		     bestPipelineIdx,
		     consensus,
		     seedElapsedTime + processElapsedTime);
	printf( "[STEP 4] Selecting and storing the best result is done!\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	printResult(config,
		    &dataset,
		    &seedModel,
		    pipelineResults,
		    bestPipelineIdx,
		    consensus,
		    seedElapsedTime + processElapsedTime);
	return 0;
}
