#include "MorbiusPlus.h"

#include <algorithm>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <vector>
using namespace std;


#define PWLFRACTIONBITS 12
#define PWLCOEFFICIENTFRACTIONBITS 18
#define PWLRESIDUALBITS 8
#define PWLINTERVALNUM 16


static const uint32_t LOG2PWLBASE[PWLINTERVALNUM] = {
	0, 22928, 44545, 64993,
	84392, 102844, 120437, 137249,
	153344, 168783, 183616, 197889,
	211643, 224915, 237736, 250137
};

static const uint32_t LOG2PWLDELTA[PWLINTERVALNUM] = {
	22928, 21617, 20448, 19399,
	18452, 17594, 16811, 16096,
	15439, 14833, 14273, 13754,
	13271, 12821, 12401, 12007
};

static const uint32_t EXP2PWLBASE[PWLINTERVALNUM] = {
	262144, 251030, 240387, 230195,
	220436, 211090, 202141, 193571,
	185364, 177505, 169979, 162773,
	155872, 149263, 142935, 136875
};

static const uint32_t EXP2PWLDELTA[PWLINTERVALNUM] = {
	11114, 10643, 10192, 9760,
	9346, 8950, 8570, 8207,
	7859, 7526, 7207, 6901,
	6608, 6328, 6060, 5803
};


// Calculate one PWL value using the arithmetic shared by LPMManager and WeightProducer
static uint32_t calculatePWLValue( const uint32_t *baseTable,
				   const uint32_t *deltaTable,
				   uint32_t fractionCode,
				   bool subtractCorrection ) {
	uint32_t intervalIdx = fractionCode >> PWLRESIDUALBITS;
	uint32_t residualMask = (1U << PWLRESIDUALBITS) - 1U;
	uint32_t residual = fractionCode & residualMask;
	uint64_t product = (uint64_t)deltaTable[intervalIdx] * (uint64_t)residual;
	uint32_t correction = (uint32_t)((product + (1U << (PWLRESIDUALBITS - 1))) >>
					 PWLRESIDUALBITS);

	if ( subtractCorrection ) return baseTable[intervalIdx] - correction;
	return baseTable[intervalIdx] + correction;
}

// Approximate log2(count) with the 16-interval Log2 mode
uint32_t calculateLog2PWLQ12( uint32_t count ) {
	if ( count == 0 || count >= (1U << 18) ) {
		printf( "Invalid BPM count for LPM conversion: %u\n", count );
		fflush( stdout );
		exit(1);
	}

	uint32_t integerPart = 0;
	uint32_t normalizedCount = count;
	while ( normalizedCount > 1 ) {
		normalizedCount = normalizedCount >> 1;
		integerPart ++;
	}

	uint32_t leadingValue = 1U << integerPart;
	uint64_t numerator = (uint64_t)(count - leadingValue) << PWLFRACTIONBITS;
	uint32_t fractionCode = (uint32_t)(numerator >> integerPart);
	fractionCode = fractionCode & ((1U << PWLFRACTIONBITS) - 1U);

	uint32_t fractionQ18 = calculatePWLValue(LOG2PWLBASE,
						   LOG2PWLDELTA,
						   fractionCode,
						   false);
	uint32_t fractionQ12 = (fractionQ18 + 32U) >> 6;
	if ( fractionQ12 >= (1U << PWLFRACTIONBITS) ) {
		integerPart ++;
		fractionQ12 = fractionQ12 - (1U << PWLFRACTIONBITS);
	}
	return (integerPart << PWLFRACTIONBITS) | fractionQ12;
}

// Approximate 2^(-difference) with the 16-interval WeightProducer mode
uint32_t calculateExp2PWLQ18( uint32_t differenceQ12 ) {
	uint32_t integerPart = differenceQ12 >> PWLFRACTIONBITS;
	uint32_t fractionCode = differenceQ12 & ((1U << PWLFRACTIONBITS) - 1U);
	uint32_t fractionQ18 = calculatePWLValue(EXP2PWLBASE,
						   EXP2PWLDELTA,
						   fractionCode,
						   true);
	if ( integerPart > PWLCOEFFICIENTFRACTIONBITS ) return 0;
	return fractionQ18 >> integerPart;
}

// Initialize offsets with fixed-rate Markov-adjusted seed initialization
void initializeOffsets( const Config *config,
			const Dataset *dataset,
			const SeedModel *seedModel,
			int pipelineIdx,
			vector<uint32_t> &offsets ) {
	RandomGenerator initializationRandom;
	initializeRandomGenerator(&initializationRandom,
				  config->randomSeed +
				  (uint64_t)(pipelineIdx + 1) * 0x9e3779b97f4a7c15ULL);

	offsets.resize(dataset->sequences.size());
	uint32_t candidateNum = (uint32_t)(dataset->sequenceLength - config->motifLength + 1);
	for ( size_t seqIdx = 0; seqIdx < dataset->sequences.size(); seqIdx ++ ) {
		uint32_t randomOffset = randomBounded(&initializationRandom, candidateNum);
		uint32_t guidedOffset = randomOffset;
		bool guidedValid = false;

		if ( seedModel->valid && seedModel->guidedOffsets[seqIdx].empty() == false ) {
			uint32_t guidedIdx = randomBounded(&initializationRandom,
							   (uint32_t)seedModel->guidedOffsets[seqIdx].size());
			guidedOffset = seedModel->guidedOffsets[seqIdx][guidedIdx];
			guidedValid = true;
		}

		uint32_t guidanceBit = randomWord(&initializationRandom) & 0x1U;
		if ( guidanceBit == 1 && guidedValid ) offsets[seqIdx] = guidedOffset;
		else offsets[seqIdx] = randomOffset;
	}
}

// Build a complete BPM
void buildBPM( const Config *config,
	       const Dataset *dataset,
	       const vector<uint32_t> &offsets,
	       vector<uint32_t> &bpm ) {
	bpm.assign((size_t)dataset->alphabetSize * config->motifLength, PSEUDOCOUNT);
	for ( size_t seqIdx = 0; seqIdx < dataset->sequences.size(); seqIdx ++ ) {
		for ( size_t column = 0; column < config->motifLength; column ++ ) {
			int symbol = dataset->symbolMap[(unsigned char)dataset->sequences[seqIdx][offsets[seqIdx] + column]];
			bpm[(size_t)symbol * config->motifLength + column] ++;
		}
	}
}

// Build a fixed-point LPM
void buildLPMQ12( const vector<uint32_t> &bpm, vector<uint32_t> &lpmQ12 ) {
	lpmQ12.resize(bpm.size());
	for ( size_t i = 0; i < bpm.size(); i ++ ) {
		lpmQ12[i] = calculateLog2PWLQ12(bpm[i]);
	}
}

// Calculate the Overall Consensus Score
uint64_t calculateConsensusScore( const Config *config,
				  const Dataset *dataset,
				  const vector<uint32_t> &bpm ) {
	uint64_t score = 0;
	for ( size_t column = 0; column < config->motifLength; column ++ ) {
		uint32_t columnMaximum = 0;
		for ( int symbol = 0; symbol < dataset->alphabetSize; symbol ++ ) {
			columnMaximum = max(columnMaximum,
					    bpm[(size_t)symbol * config->motifLength + column]);
		}
		score = score + columnMaximum;
	}
	return score;
}

// Calculate a normalized score
 double calculateNormalizedScore( const Config *config,
					 const Dataset *dataset,
					 uint64_t score ) {
	double minimumPseudocountScore = (double)config->motifLength;
	double denominator = (double)dataset->sequences.size() * (double)config->motifLength;
	return ((double)score - minimumPseudocountScore) / denominator;
}

// Calculate the raw score threshold
uint64_t calculateRawScoreThreshold( const Config *config, const Dataset *dataset ) {
	double score = (double)config->motifLength +
		       config->scoreThreshold *
		       (double)dataset->sequences.size() *
		       (double)config->motifLength;
	return (uint64_t)ceil(score);
}
