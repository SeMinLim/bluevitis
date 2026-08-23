#include "MorbiusPlus.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <string>
#include <vector>
using namespace std;


// Encode a k-mer
uint32_t encodeKmer( const string &sequence,
			     size_t position,
			     size_t kmerLength,
			     const Dataset *dataset ) {
	uint32_t code = 0;
	for ( size_t i = 0; i < kmerLength; i ++ ) {
		int symbol = dataset->symbolMap[(unsigned char)sequence[position + i]];
		code = code * (uint32_t)dataset->alphabetSize + (uint32_t)symbol;
	}
	return code;
}

// Decode a k-mer
string decodeKmer( uint32_t code, size_t kmerLength, const Dataset *dataset ) {
	string kmer(kmerLength, dataset->alphabet[0]);
	for ( size_t i = 0; i < kmerLength; i ++ ) {
		size_t position = kmerLength - 1 - i;
		kmer[position] = dataset->alphabet[code % (uint32_t)dataset->alphabetSize];
		code = code / (uint32_t)dataset->alphabetSize;
	}
	return kmer;
}

// Calculate Shannon entropy of a DNA seed
double calculateSeedEntropy( uint32_t seedCode, size_t seedLength ) {
	uint32_t count[4] = {0, 0, 0, 0};
	uint32_t code = seedCode;
	for ( size_t i = 0; i < seedLength; i ++ ) {
		count[code & 0x3U] ++;
		code = code >> 2;
	}

	double entropy = 0.0;
	for ( int i = 0; i < 4; i ++ ) {
		if ( count[i] == 0 ) continue;
		double ratio = (double)count[i] / (double)seedLength;
		entropy = entropy - ratio * log2(ratio);
	}
	return entropy;
}

// Count sequence support and Markov statistics
void countSeedAndMarkovStatistics( const Dataset *dataset,
					  int alphabetMode,
					  size_t sampleNum,
					  size_t seedLength,
					  vector<uint32_t> &seedSupport,
					  vector<uint8_t> &seedValid,
					  MarkovModel *markovModel ) {
	uint64_t seedTableSize = integerPower((uint64_t)dataset->alphabetSize, seedLength);
	seedSupport.assign((size_t)seedTableSize, 0);
	seedValid.assign((size_t)seedTableSize, 1);

	if ( alphabetMode == ALPHABET_DNA ) {
		for ( uint32_t code = 0; code < seedTableSize; code ++ ) {
			if ( calculateSeedEntropy(code, seedLength) < DNAENTROPYMIN ) seedValid[code] = 0;
		}
		markovModel->order = 3;
	} else {
		markovModel->order = 1;
	}
	markovModel->alphabetSize = dataset->alphabetSize;

	uint64_t contextTableSize = integerPower((uint64_t)dataset->alphabetSize,
							 (size_t)markovModel->order);
	markovModel->contextTotal = 0;
	markovModel->contextCount.assign((size_t)contextTableSize, 0);
	markovModel->transitionCount.assign((size_t)(contextTableSize * dataset->alphabetSize), 0);

	vector<uint32_t> lastSeen((size_t)seedTableSize, 0);
	for ( size_t seqIdx = 0; seqIdx < sampleNum; seqIdx ++ ) {
		const string &sequence = dataset->sequences[seqIdx];

		// Seed support
		for ( size_t position = 0; position + seedLength <= sequence.size(); position ++ ) {
			uint32_t seedCode = encodeKmer(sequence, position, seedLength, dataset);
			if ( seedValid[seedCode] == 0 ) continue;
			if ( lastSeen[seedCode] != seqIdx + 1 ) {
				lastSeen[seedCode] = (uint32_t)seqIdx + 1;
				seedSupport[seedCode] ++;
			}
		}

		// Markov context count
		for ( size_t position = 0;
		      position + (size_t)markovModel->order <= sequence.size();
		      position ++ ) {
			uint32_t contextCode = encodeKmer(sequence,
							  position,
							  (size_t)markovModel->order,
							  dataset);
			markovModel->contextCount[contextCode] ++;
			markovModel->contextTotal ++;
		}

		// Markov transition count
		for ( size_t position = 0;
		      position + (size_t)markovModel->order + 1 <= sequence.size();
		      position ++ ) {
			uint32_t transitionCode = encodeKmer(sequence,
							     position,
							     (size_t)markovModel->order + 1,
							     dataset);
			markovModel->transitionCount[transitionCode] ++;
		}
	}
}

// Calculate a seed probability under the Markov model
double calculateMarkovSeedProbability( uint32_t seedCode,
					       size_t seedLength,
					       const Dataset *dataset,
					       const MarkovModel *markovModel ) {
	vector<int> symbols(seedLength, 0);
	uint32_t code = seedCode;
	for ( size_t i = 0; i < seedLength; i ++ ) {
		size_t position = seedLength - 1 - i;
		symbols[position] = (int)(code % (uint32_t)dataset->alphabetSize);
		code = code / (uint32_t)dataset->alphabetSize;
	}

	uint32_t contextCode = 0;
	for ( int i = 0; i < markovModel->order; i ++ ) {
		contextCode = contextCode * (uint32_t)dataset->alphabetSize + (uint32_t)symbols[i];
	}

	double contextTableSize = (double)markovModel->contextCount.size();
	double probability = ((double)markovModel->contextCount[contextCode] + PSEUDOCOUNT) /
				     ((double)markovModel->contextTotal + contextTableSize * PSEUDOCOUNT);

	uint32_t contextModulo = (uint32_t)integerPower((uint64_t)dataset->alphabetSize,
							      (size_t)markovModel->order - 1);
	for ( size_t position = (size_t)markovModel->order; position < seedLength; position ++ ) {
		uint32_t symbol = (uint32_t)symbols[position];
		uint32_t transitionCode = contextCode * (uint32_t)dataset->alphabetSize + symbol;
		double transitionProbability =
			((double)markovModel->transitionCount[transitionCode] + PSEUDOCOUNT) /
			((double)markovModel->contextCount[contextCode] +
			 (double)dataset->alphabetSize * PSEUDOCOUNT);
		probability = probability * transitionProbability;

		if ( markovModel->order == 1 ) contextCode = symbol;
		else contextCode = (contextCode % contextModulo) * (uint32_t)dataset->alphabetSize + symbol;
	}

	return probability;
}

// Select the highest-ranked seed
void selectSeed( const Dataset *dataset,
		 size_t sampleNum,
		 size_t seedLength,
		 const vector<uint32_t> &seedSupport,
		 const vector<uint8_t> &seedValid,
		 const MarkovModel *markovModel,
		 SeedModel *seedModel ) {
	seedModel->valid = false;
	seedModel->seedRank = -numeric_limits<double>::infinity();
	seedModel->seedLength = seedLength;
	seedModel->sampleNum = sampleNum;

	size_t positionNum = dataset->sequenceLength - seedLength + 1;
	for ( uint32_t code = 0; code < seedSupport.size(); code ++ ) {
		if ( seedValid[code] == 0 || seedSupport[code] == 0 ) continue;

		double positionProbability = calculateMarkovSeedProbability(code,
									    seedLength,
									    dataset,
									    markovModel);
		double sequenceProbability = 1.0;
		if ( positionProbability < 1.0 ) {
			sequenceProbability = -expm1((double)positionNum * log1p(-positionProbability));
		}
		if ( sequenceProbability < 0.0 ) sequenceProbability = 0.0;
		if ( sequenceProbability > 1.0 ) sequenceProbability = 1.0;

		double expectedSupport = (double)sampleNum * sequenceProbability;
		double variance = (double)sampleNum * sequenceProbability * (1.0 - sequenceProbability);
		double rank = ((double)seedSupport[code] - expectedSupport) / sqrt(variance + 1.0e-12);

		bool better = false;
		if ( seedModel->valid == false || rank > seedModel->seedRank ) better = true;
		else if ( rank == seedModel->seedRank && seedSupport[code] > seedModel->seedSupport ) better = true;
		else if ( rank == seedModel->seedRank && seedSupport[code] == seedModel->seedSupport &&
			  code < seedModel->seedCode ) better = true;

		if ( better ) {
			seedModel->valid = true;
			seedModel->seedCode = code;
			seedModel->seedString = decodeKmer(code, seedLength, dataset);
			seedModel->seedSupport = seedSupport[code];
			seedModel->seedExpectedSupport = expectedSupport;
			seedModel->seedRank = rank;
		}
	}
}

// Generate evenly distributed anchor offsets
vector<size_t> getAnchorOffsets( size_t motifLength, size_t seedLength ) {
	size_t anchorNum = min((size_t)ANCHORMAX, motifLength - seedLength + 1);
	vector<size_t> anchorOffsets;
	if ( anchorNum == 1 ) {
		anchorOffsets.push_back(0);
		return anchorOffsets;
	}

	for ( size_t anchorIdx = 0; anchorIdx < anchorNum; anchorIdx ++ ) {
		double position = (double)anchorIdx * (double)(motifLength - seedLength) /
				  (double)(anchorNum - 1);
		size_t anchorOffset = (size_t)llround(position);
		if ( anchorOffsets.empty() || anchorOffsets.back() != anchorOffset ) {
			anchorOffsets.push_back(anchorOffset);
		}
	}
	return anchorOffsets;
}

// Find the first legal seed occurrence for one anchor
int64_t findFirstLegalGuidedOffset( const string &sequence,
					    const string &seed,
					    size_t anchorOffset,
					    size_t motifLength ) {
	size_t occurrence = sequence.find(seed, 0);
	while ( occurrence != string::npos ) {
		if ( occurrence >= anchorOffset ) {
			size_t guidedOffset = occurrence - anchorOffset;
			if ( guidedOffset + motifLength <= sequence.size() ) return (int64_t)guidedOffset;
		}
		occurrence = sequence.find(seed, occurrence + 1);
	}
	return -1;
}

// Select the best anchor offset
void selectAnchor( const Config *config, const Dataset *dataset, SeedModel *seedModel ) {
	if ( seedModel->valid == false ) return;

	vector<size_t> anchorOffsets = getAnchorOffsets(config->motifLength, seedModel->seedLength);
	double bestRank = -numeric_limits<double>::infinity();
	size_t bestAnchorOffset = 0;

	for ( size_t anchorIdx = 0; anchorIdx < anchorOffsets.size(); anchorIdx ++ ) {
		size_t anchorOffset = anchorOffsets[anchorIdx];
		vector<uint32_t> count((size_t)dataset->alphabetSize * config->motifLength, 0);
		size_t foundNum = 0;

		for ( size_t seqIdx = 0; seqIdx < seedModel->sampleNum; seqIdx ++ ) {
			int64_t guidedOffset = findFirstLegalGuidedOffset(dataset->sequences[seqIdx],
										 seedModel->seedString,
										 anchorOffset,
										 config->motifLength);
			if ( guidedOffset < 0 ) continue;

			foundNum ++;
			for ( size_t column = 0; column < config->motifLength; column ++ ) {
				int symbol = dataset->symbolMap[(unsigned char)dataset->sequences[seqIdx][guidedOffset + column]];
				count[(size_t)symbol * config->motifLength + column] ++;
			}
		}

		if ( foundNum == 0 ) continue;
		uint64_t columnMaximumSum = 0;
		for ( size_t column = 0; column < config->motifLength; column ++ ) {
			uint32_t columnMaximum = 0;
			for ( int symbol = 0; symbol < dataset->alphabetSize; symbol ++ ) {
				columnMaximum = max(columnMaximum,
						    count[(size_t)symbol * config->motifLength + column]);
			}
			columnMaximumSum = columnMaximumSum + columnMaximum;
		}

		double columnMaximumFrequency = (double)columnMaximumSum /
				     ((double)foundNum * (double)config->motifLength);
		double supportRatio = (double)foundNum / (double)seedModel->sampleNum;
		double randomAlphabetBaseline = 1.0 / (double)dataset->alphabetSize;
		double rank = supportRatio * (columnMaximumFrequency - randomAlphabetBaseline);

		if ( rank > bestRank ) {
			bestRank = rank;
			bestAnchorOffset = anchorOffset;
		}
	}

	if ( isfinite(bestRank) == false ) {
		seedModel->valid = false;
		return;
	}
	seedModel->anchorOffset = bestAnchorOffset;
	seedModel->anchorRank = bestRank;
}

// Find all legal guided offsets in the complete dataset
void buildGuidedOffsets( const Config *config, const Dataset *dataset, SeedModel *seedModel ) {
	seedModel->guidedOffsets.assign(dataset->sequences.size(), vector<uint32_t>());
	if ( seedModel->valid == false ) return;

	for ( size_t seqIdx = 0; seqIdx < dataset->sequences.size(); seqIdx ++ ) {
		const string &sequence = dataset->sequences[seqIdx];
		size_t occurrence = sequence.find(seedModel->seedString, 0);
		while ( occurrence != string::npos ) {
			if ( occurrence >= seedModel->anchorOffset ) {
				size_t guidedOffset = occurrence - seedModel->anchorOffset;
				if ( guidedOffset + config->motifLength <= sequence.size() ) {
					seedModel->guidedOffsets[seqIdx].push_back((uint32_t)guidedOffset);
				}
			}
			occurrence = sequence.find(seedModel->seedString, occurrence + 1);
		}
	}
}

// Construct the complete seed model
void buildSeedModel( const Config *config, const Dataset *dataset, SeedModel *seedModel ) {
	seedModel->valid = false;
	seedModel->sampleNum = min((size_t)SAMPLEMAX, dataset->sequences.size());
	if ( config->alphabetMode == ALPHABET_DNA ) {
		seedModel->seedLength = min((size_t)DNASEEDMAX, config->motifLength);
	} else {
		seedModel->seedLength = min((size_t)PROTEINSEEDMAX, config->motifLength);
	}

	vector<uint32_t> seedSupport;
	vector<uint8_t> seedValid;
	MarkovModel markovModel;
	countSeedAndMarkovStatistics(dataset,
				     config->alphabetMode,
				     seedModel->sampleNum,
				     seedModel->seedLength,
				     seedSupport,
				     seedValid,
				     &markovModel);
	selectSeed(dataset,
		   seedModel->sampleNum,
		   seedModel->seedLength,
		   seedSupport,
		   seedValid,
		   &markovModel,
		   seedModel);
	selectAnchor(config, dataset, seedModel);
	buildGuidedOffsets(config, dataset, seedModel);
}
