#include "MorbiusPlus.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <vector>
using namespace std;


// Build result counts without pseudocount
void buildResultCount( const Config *config,
		       const Dataset *dataset,
		       const vector<uint32_t> &offsets,
		       vector<uint32_t> &count ) {
	count.assign((size_t)dataset->alphabetSize * config->motifLength, 0);
	for ( size_t seqIdx = 0; seqIdx < dataset->sequences.size(); seqIdx ++ ) {
		for ( size_t column = 0; column < config->motifLength; column ++ ) {
			int symbol = dataset->symbolMap[(unsigned char)dataset->sequences[seqIdx][offsets[seqIdx] + column]];
			count[(size_t)symbol * config->motifLength + column] ++;
		}
	}
}

// Build the consensus subsequence
string buildConsensus( const Config *config,
		       const Dataset *dataset,
		       const vector<uint32_t> &count ) {
	string consensus(config->motifLength, dataset->alphabet[0]);
	for ( size_t column = 0; column < config->motifLength; column ++ ) {
		uint32_t maximum = 0;
		int maximumSymbol = 0;
		for ( int symbol = 0; symbol < dataset->alphabetSize; symbol ++ ) {
			uint32_t value = count[(size_t)symbol * config->motifLength + column];
			if ( value > maximum ) {
				maximum = value;
				maximumSymbol = symbol;
			}
		}
		consensus[column] = dataset->alphabet[maximumSymbol];
	}
	return consensus;
}

// Create an output directory
void createOutputDirectory( const string &outputPrefix ) {
	filesystem::path outputPath(outputPrefix);
	filesystem::path parentPath = outputPath.parent_path();
	if ( parentPath.empty() == false ) {
		error_code errorCode;
		filesystem::create_directories(parentPath, errorCode);
		if ( errorCode ) {
			printf( "Unable to create output directory: %s\n", parentPath.string().c_str() );
			exit(1);
		}
	}
}

// Write discovered motif sites in FASTA format
void writeMotifFASTA( const Config *config,
		      const Dataset *dataset,
		      const vector<uint32_t> &offsets ) {
	string filename = config->outputPrefix + ".fasta";
	ofstream outputFile(filename);
	if ( outputFile.is_open() == false ) {
		printf( "Unable to create output file: %s\n", filename.c_str() );
		exit(1);
	}

	for ( size_t seqIdx = 0; seqIdx < dataset->sequences.size(); seqIdx ++ ) {
		outputFile << ">" << dataset->names[seqIdx] << " offset=" << offsets[seqIdx] << "\n";
		outputFile << dataset->sequences[seqIdx].substr(offsets[seqIdx], config->motifLength) << "\n";
	}
	outputFile.close();
}

// Write sequence offsets
void writeOffsets( const Config *config,
		   const Dataset *dataset,
		   const vector<uint32_t> &offsets ) {
	string filename = config->outputPrefix + ".offsets.tsv";
	ofstream outputFile(filename);
	if ( outputFile.is_open() == false ) {
		printf( "Unable to create output file: %s\n", filename.c_str() );
		exit(1);
	}

	outputFile << "SequenceIdx\tSequenceName\tOffset\tMotif\n";
	for ( size_t seqIdx = 0; seqIdx < dataset->sequences.size(); seqIdx ++ ) {
		outputFile << seqIdx << "\t"
			   << dataset->names[seqIdx] << "\t"
			   << offsets[seqIdx] << "\t"
			   << dataset->sequences[seqIdx].substr(offsets[seqIdx], config->motifLength)
			   << "\n";
	}
	outputFile.close();
}

// Write a PWM table
void writePWM( const Config *config,
	       const Dataset *dataset,
	       const vector<uint32_t> &count ) {
	string filename = config->outputPrefix + ".pwm.tsv";
	ofstream outputFile(filename);
	if ( outputFile.is_open() == false ) {
		printf( "Unable to create output file: %s\n", filename.c_str() );
		exit(1);
	}

	outputFile << "Position";
	for ( int symbol = 0; symbol < dataset->alphabetSize; symbol ++ ) {
		outputFile << "\t" << dataset->alphabet[symbol];
	}
	outputFile << "\n";

	double denominator = (double)dataset->sequences.size() +
			     (double)dataset->alphabetSize * PSEUDOCOUNT;
	for ( size_t column = 0; column < config->motifLength; column ++ ) {
		outputFile << column;
		for ( int symbol = 0; symbol < dataset->alphabetSize; symbol ++ ) {
			double probability =
				((double)count[(size_t)symbol * config->motifLength + column] + PSEUDOCOUNT) /
				denominator;
			outputFile << "\t" << probability;
		}
		outputFile << "\n";
	}
	outputFile.close();
}

// Write a MEME-format motif
void writeMEME( const Config *config,
		const Dataset *dataset,
		const vector<uint32_t> &count ) {
	string filename = config->outputPrefix + ".meme";
	ofstream outputFile(filename);
	if ( outputFile.is_open() == false ) {
		printf( "Unable to create output file: %s\n", filename.c_str() );
		exit(1);
	}

	outputFile << "MEME version 4\n\n";
	outputFile << "ALPHABET= " << dataset->alphabet << "\n\n";
	if ( config->alphabetMode == ALPHABET_DNA ) outputFile << "strands: +\n\n";
	outputFile << "Background letter frequencies\n";
	for ( int symbol = 0; symbol < dataset->alphabetSize; symbol ++ ) {
		outputFile << dataset->alphabet[symbol] << " " << 1.0 / (double)dataset->alphabetSize;
		if ( symbol + 1 < dataset->alphabetSize ) outputFile << " ";
	}
	outputFile << "\n\n";
	outputFile << "MOTIF MorbiusPlus\n";
	outputFile << "letter-probability matrix: alength= " << dataset->alphabetSize
		   << " w= " << config->motifLength
		   << " nsites= " << dataset->sequences.size()
		   << " E= 0\n";

	double denominator = (double)dataset->sequences.size() +
			     (double)dataset->alphabetSize * PSEUDOCOUNT;
	for ( size_t column = 0; column < config->motifLength; column ++ ) {
		for ( int symbol = 0; symbol < dataset->alphabetSize; symbol ++ ) {
			double probability =
				((double)count[(size_t)symbol * config->motifLength + column] + PSEUDOCOUNT) /
				denominator;
			outputFile << probability;
			if ( symbol + 1 < dataset->alphabetSize ) outputFile << " ";
		}
		outputFile << "\n";
	}
	outputFile.close();
}

// Write a result summary
void writeSummary( const Config *config,
		   const Dataset *dataset,
		   const SeedModel *seedModel,
		   const vector<PipelineResult> &pipelineResults,
		   int bestPipelineIdx,
		   const string &consensus,
		   double elapsedTime ) {
	string filename = config->outputPrefix + ".summary.txt";
	ofstream outputFile(filename);
	if ( outputFile.is_open() == false ) {
		printf( "Unable to create output file: %s\n", filename.c_str() );
		exit(1);
	}

	const PipelineResult &bestResult = pipelineResults[bestPipelineIdx];
	outputFile << "Input File              : " << config->inputFilename << "\n";
	outputFile << "Alphabet                : " << (config->alphabetMode == ALPHABET_DNA ? "DNA" : "Protein") << "\n";
	outputFile << "Sequence Number          : " << dataset->sequences.size() << "\n";
	outputFile << "Sequence Length          : " << dataset->sequenceLength << "\n";
	outputFile << "Motif Length             : " << config->motifLength << "\n";
	outputFile << "SampleNum                : " << seedModel->sampleNum << "\n";
	outputFile << "Seed Valid               : " << (seedModel->valid ? "Yes" : "No") << "\n";
	if ( seedModel->valid ) {
		outputFile << "Selected Seed            : " << seedModel->seedString << "\n";
		outputFile << "Seed Support             : " << seedModel->seedSupport << "\n";
		outputFile << "Expected Seed Support    : " << seedModel->seedExpectedSupport << "\n";
		outputFile << "Seed Rank                : " << seedModel->seedRank << "\n";
		outputFile << "Anchor Offset            : " << seedModel->anchorOffset << "\n";
		outputFile << "Anchor Rank              : " << seedModel->anchorRank << "\n";
	}
	outputFile << "Pipeline Number          : " << ACCELMAXPIPELINE << "\n";
	outputFile << "Selected Pipeline        : " << bestPipelineIdx << "\n";
	outputFile << "Best Score               : " << bestResult.bestScore << "\n";
	outputFile << "Normalized Best Score    : "
		   << calculateNormalizedScore(config, dataset, bestResult.bestScore) << "\n";
	outputFile << "Score Threshold          : " << config->scoreThreshold << "\n";
	outputFile << "Pipeline Update Number   : " << bestResult.updateNum << "\n";
	outputFile << "Threshold Reached        : " << (bestResult.thresholdReached ? "Yes" : "No") << "\n";
	outputFile << "Consensus Subsequence    : " << consensus << "\n";
	outputFile << "Elapsed Time             : " << elapsedTime << " seconds\n";
	outputFile.close();
}

// Print the final result
void printResult( const Config *config,
		  const Dataset *dataset,
		  const SeedModel *seedModel,
		  const vector<PipelineResult> &pipelineResults,
		  int bestPipelineIdx,
		  const string &consensus,
		  double elapsedTime ) {
	const PipelineResult &bestResult = pipelineResults[bestPipelineIdx];
	printf( "---------------------------------------------------------------------\n" );
	printf( "MORBIUS+ RESULT\n" );
	printf( "---------------------------------------------------------------------\n" );
	printf( "The Number of Sequence : %lu\n", (unsigned long)dataset->sequences.size() );
	printf( "The Length of Sequence : %lu\n", (unsigned long)dataset->sequenceLength );
	printf( "The Length of Motif    : %lu\n", (unsigned long)config->motifLength );
	printf( "SampleNum              : %lu\n", (unsigned long)seedModel->sampleNum );
	if ( seedModel->valid ) {
		printf( "Selected Seed          : %s\n", seedModel->seedString.c_str() );
		printf( "Anchor Offset          : %lu\n", (unsigned long)seedModel->anchorOffset );
	} else {
		printf( "Selected Seed          : None\n" );
	}
	printf( "Selected Pipeline      : %d\n", bestPipelineIdx );
	printf( "Best Score             : %lu\n", (unsigned long)bestResult.bestScore );
	printf( "Normalized Best Score  : %.8f\n",
		calculateNormalizedScore(config, dataset, bestResult.bestScore) );
	printf( "Pipeline Updates       : %lu\n", (unsigned long)bestResult.updateNum );
	printf( "Consensus Subsequence  : %s\n", consensus.c_str() );
	printf( "Elapsed Time           : %.8f\n", elapsedTime );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );
}
