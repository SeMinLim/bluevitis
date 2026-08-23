#include "MorbiusPlus.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <vector>
using namespace std;


typedef struct ModelSegmentSummary {
	uint32_t startOffset;
	uint32_t exponent;
	uint32_t mass;
	uint32_t localOffset;
	uint32_t validNum;
}ModelSegmentSummary;

typedef struct ModelPipelineState {
	bool configured;
	bool executionStarted;
	bool active;
	bool terminated;
	uint32_t sequenceLength;
	uint32_t motifLength;
	uint32_t alphabetSize;
	uint32_t scoreThreshold;
	uint32_t maxUpdates;
	uint32_t bestScore;
	uint32_t updateNum;
	RandomGenerator randomGenerator;
	vector<uint8_t> sequence;
	vector<uint32_t> bpm;
	vector<uint32_t> lpmQ12;
	vector<uint8_t> previousTentativeMotif;
}ModelPipelineState;

typedef struct ModelKernelState {
	bool configured;
	ModelPipelineState pipeline[ACCELMAXPIPELINE];
}ModelKernelState;

static ModelKernelState modelKernelState;


static uint16_t readUInt16Model( const uint8_t *buffer ) {
	return (uint16_t)buffer[0] | ((uint16_t)buffer[1] << 8);
}

static uint32_t readUInt32Model( const uint8_t *buffer ) {
	uint32_t value = 0;
	for ( int i = 0; i < 4; i ++ ) value = value | ((uint32_t)buffer[i] << (8 * i));
	return value;
}

static void writeUInt16Model( uint8_t *buffer, uint16_t value ) {
	buffer[0] = (uint8_t)(value & 0xffU);
	buffer[1] = (uint8_t)((value >> 8) & 0xffU);
}

static void writeUInt32Model( uint8_t *buffer, uint32_t value ) {
	for ( int i = 0; i < 4; i ++ ) buffer[i] = (uint8_t)((value >> (8 * i)) & 0xffU);
}

static uint32_t getBitsModel( const uint8_t *buffer, size_t bitOffset, size_t bitWidth ) {
	uint32_t value = 0;
	for ( size_t bitIdx = 0; bitIdx < bitWidth; bitIdx ++ ) {
		size_t inputBit = bitOffset + bitIdx;
		uint32_t bitValue = (uint32_t)((buffer[inputBit >> 3] >> (inputBit & 0x7U)) & 0x1U);
		value = value | (bitValue << bitIdx);
	}
	return value;
}

static void setBitsModel( uint8_t *buffer, size_t bitOffset, uint32_t value, size_t bitWidth ) {
	for ( size_t bitIdx = 0; bitIdx < bitWidth; bitIdx ++ ) {
		size_t outputBit = bitOffset + bitIdx;
		if ( ((value >> bitIdx) & 0x1U) != 0 ) {
			buffer[outputBit >> 3] |= (uint8_t)(1U << (outputBit & 0x7U));
		}
	}
}

static uint8_t sequenceSymbol( const ModelPipelineState *state, uint32_t position ) {
	if ( position >= state->sequenceLength ) {
		printf( "Accelerator model sequence access is out of range: %u >= %u\n",
			position,
			state->sequenceLength
		);
		exit(1);
	}
	return state->sequence[position];
}

static uint32_t matrixIndex( const ModelPipelineState *state,
			     uint32_t symbol,
			     uint32_t column ) {
	return symbol * state->motifLength + column;
}

static uint32_t calculateModelScore( const ModelPipelineState *state ) {
	uint32_t score = 0;
	for ( uint32_t column = 0; column < state->motifLength; column ++ ) {
		uint32_t maximum = 0;
		for ( uint32_t symbol = 0; symbol < state->alphabetSize; symbol ++ ) {
			maximum = max(maximum, state->bpm[matrixIndex(state, symbol, column)]);
		}
		score = score + maximum;
	}
	return score;
}

static uint32_t selectLocalCandidateModel( const uint32_t weight[ACCELSEGMENTSIZE],
					   uint32_t totalMass,
					   uint32_t randomFraction,
					   uint32_t validNum ) {
	uint64_t product = (uint64_t)totalMass * (uint64_t)randomFraction;
	uint32_t threshold = (uint32_t)(product >> 24);
	uint32_t left4 = weight[0] + weight[1] + weight[2] + weight[3];
	uint32_t base4 = 0;
	uint32_t threshold4 = threshold;
	if ( threshold >= left4 ) {
		base4 = 4;
		threshold4 = threshold - left4;
	}

	uint32_t left2 = 0;
	if ( base4 == 0 ) left2 = weight[0] + weight[1];
	else left2 = weight[4] + weight[5];
	uint32_t base2 = base4;
	uint32_t threshold2 = threshold4;
	if ( threshold4 >= left2 ) {
		base2 = base4 + 2;
		threshold2 = threshold4 - left2;
	}

	uint32_t selected = base2;
	if ( threshold2 >= weight[base2] ) selected = base2 + 1;
	if ( selected >= validNum ) selected = validNum - 1;
	return selected;
}

static uint32_t sampleCandidateModel( ModelPipelineState *state ) {
	uint32_t candidateNum = state->sequenceLength - state->motifLength + 1;
	vector<ModelSegmentSummary> summaries;
	summaries.reserve((candidateNum + ACCELSEGMENTSIZE - 1) / ACCELSEGMENTSIZE);
	bool globalMassValid = false;
	uint32_t globalExponent = 0;
	uint64_t globalMass = 0;

	for ( uint32_t segmentStart = 0;
	      segmentStart < candidateNum;
	      segmentStart += ACCELSEGMENTSIZE ) {
		uint32_t validNum = min((uint32_t)ACCELSEGMENTSIZE, candidateNum - segmentStart);
		uint32_t logProb[ACCELSEGMENTSIZE] = {0, 0, 0, 0, 0, 0, 0, 0};
		uint32_t weight[ACCELSEGMENTSIZE] = {0, 0, 0, 0, 0, 0, 0, 0};
		uint32_t maximum = 0;

		for ( uint32_t localIdx = 0; localIdx < validNum; localIdx ++ ) {
			uint32_t value = 0;
			for ( uint32_t column = 0; column < state->motifLength; column ++ ) {
				uint32_t symbol = sequenceSymbol(state, segmentStart + localIdx + column);
				value = value + state->lpmQ12[matrixIndex(state, symbol, column)];
			}
			logProb[localIdx] = value;
			maximum = max(maximum, value);
		}

		uint32_t exponent = (maximum + 4095U) >> 12;
		uint32_t exponentQ12 = exponent << 12;
		uint32_t segmentMass = 0;
		for ( uint32_t localIdx = 0; localIdx < ACCELSEGMENTSIZE; localIdx ++ ) {
			uint32_t difference = 0x7fffffffU;
			if ( localIdx < validNum ) difference = exponentQ12 - logProb[localIdx];
			weight[localIdx] = calculateExp2PWLQ18(difference);
			segmentMass = segmentMass + weight[localIdx];
		}

		uint32_t localRandom = randomWord(&state->randomGenerator) >> 8;
		uint32_t localOffset = selectLocalCandidateModel(weight,
							    segmentMass,
							    localRandom,
							    validNum);
		ModelSegmentSummary summary;
		summary.startOffset = segmentStart;
		summary.exponent = exponent;
		summary.mass = segmentMass;
		summary.localOffset = localOffset;
		summary.validNum = validNum;
		summaries.push_back(summary);

		uint64_t segmentMassQ24 = (uint64_t)segmentMass << 6;
		if ( globalMassValid == false ) {
			globalMassValid = true;
			globalExponent = exponent;
			globalMass = segmentMassQ24;
		} else if ( exponent <= globalExponent ) {
			globalMass = globalMass + (segmentMassQ24 >> (globalExponent - exponent));
		} else {
			globalMass = (globalMass >> (exponent - globalExponent)) + segmentMassQ24;
			globalExponent = exponent;
		}
	}

	uint32_t globalRandom = randomWord(&state->randomGenerator) >> 8;
	uint64_t globalThreshold = (globalMass * (uint64_t)globalRandom) >> 24;
	uint64_t cumulative = 0;
	for ( size_t summaryIdx = 0; summaryIdx < summaries.size(); summaryIdx ++ ) {
		const ModelSegmentSummary &summary = summaries[summaryIdx];
		uint64_t alignedMass = ((uint64_t)summary.mass << 6) >>
				       (globalExponent - summary.exponent);
		uint64_t nextCumulative = cumulative + alignedMass;
		if ( nextCumulative > globalThreshold || summaryIdx + 1 == summaries.size() ) {
			return summary.startOffset + summary.localOffset;
		}
		cumulative = nextCumulative;
	}
	return 0;
}

static AccelWireResult runPipelineModel( ModelPipelineState *state,
					 uint32_t tentativeOffset,
					 bool bootstrap ) {
	AccelWireResult result;
	result.newOffset = tentativeOffset;
	result.bestScore = state->bestScore;
	result.updateNum = state->updateNum;
	result.bestUpdate = false;
	result.terminated = state->terminated;
	result.active = state->active;

	if ( state->terminated ) return result;
	if ( bootstrap == false ) {
		for ( uint32_t column = 0; column < state->motifLength; column ++ ) {
			uint32_t currentSymbol = sequenceSymbol(state, tentativeOffset + column);
			uint32_t previousSymbol = state->previousTentativeMotif[column];
			uint32_t currentIdx = matrixIndex(state, currentSymbol, column);
			if ( state->bpm[currentIdx] <= PSEUDOCOUNT ) {
				printf( "BPM underflow in accelerator model at column %u.\n", column );
				exit(1);
			}
			state->bpm[currentIdx] --;
			if ( previousSymbol != currentSymbol ) {
				uint32_t previousIdx = matrixIndex(state, previousSymbol, column);
				state->lpmQ12[previousIdx] = calculateLog2PWLQ12(state->bpm[previousIdx]);
				state->lpmQ12[currentIdx] = calculateLog2PWLQ12(state->bpm[currentIdx]);
			}
		}
	}

	uint32_t newOffset = sampleCandidateModel(state);
	for ( uint32_t column = 0; column < state->motifLength; column ++ ) {
		uint32_t symbol = sequenceSymbol(state, newOffset + column);
		state->bpm[matrixIndex(state, symbol, column)] ++;
		state->previousTentativeMotif[column] = (uint8_t)symbol;
	}

	uint32_t score = calculateModelScore(state);
	uint32_t nextUpdateNum = state->updateNum + 1;
	bool bestUpdate = score > state->bestScore;
	if ( bestUpdate ) state->bestScore = score;
	state->updateNum = nextUpdateNum;
	state->terminated = state->bestScore >= state->scoreThreshold ||
			    state->updateNum >= state->maxUpdates;
	state->executionStarted = true;

	result.newOffset = newOffset;
	result.bestScore = state->bestScore;
	result.updateNum = state->updateNum;
	result.bestUpdate = bestUpdate;
	result.terminated = state->terminated;
	return result;
}

static void loadSequenceModel( ModelPipelineState *state,
			       const uint8_t *input,
			       uint32_t sequenceLength,
			       uint32_t sequenceBeatNum ) {
	state->sequence.assign(input, input + (size_t)sequenceBeatNum * ACCELBEATBYTES);
	state->sequence.resize(sequenceLength);
}

static void unpackMatrixModel( ModelPipelineState *state,
			       const uint8_t *input,
			       vector<uint32_t> &matrix ) {
	matrix.assign((size_t)state->alphabetSize * state->motifLength, 0);
	for ( uint32_t column = 0; column < state->motifLength; column ++ ) {
		const uint8_t *word = input + (size_t)column * ACCELBEATBYTES;
		for ( uint32_t symbol = 0; symbol < state->alphabetSize; symbol ++ ) {
			matrix[matrixIndex(state, symbol, column)] =
				getBitsModel(word, (size_t)symbol * 18, 18);
		}
	}
}

static void packResultModel( uint8_t *word,
			     uint16_t itemIdx,
			     const AccelWireResult result[ACCELMAXPIPELINE],
			     bool allDone,
			     int bestPipelineIdx ) {
	writeUInt32Model(word + 0, ACCELRESULTMAGIC);
	writeUInt16Model(word + 4, ACCELPROTOCOLVERSION);
	writeUInt16Model(word + 6, itemIdx);
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		size_t base = 64 + (size_t)pipelineIdx * 96;
		setBitsModel(word, base + 0, result[pipelineIdx].newOffset, 11);
		setBitsModel(word, base + 11, result[pipelineIdx].bestUpdate ? 1 : 0, 1);
		setBitsModel(word, base + 12, result[pipelineIdx].terminated ? 1 : 0, 1);
		setBitsModel(word, base + 13, result[pipelineIdx].active ? 1 : 0, 1);
		setBitsModel(word, base + 16, result[pipelineIdx].bestScore, 32);
		setBitsModel(word, base + 48, result[pipelineIdx].updateNum, 32);
	}
	word[56] = allDone ? 1 : 0;
	word[57] = (uint8_t)bestPipelineIdx;
	writeUInt32Model(word + 58, result[bestPipelineIdx].bestScore);
}

static void packSummaryModel( uint8_t *word,
			      uint32_t processedNum,
			      bool allDone,
			      int bestPipelineIdx ) {
	writeUInt32Model(word + 0, ACCELRESULTMAGIC);
	writeUInt16Model(word + 4, ACCELPROTOCOLVERSION);
	writeUInt32Model(word + 8, processedNum);
	word[12] = allDone ? 1 : 0;
	word[13] = (uint8_t)bestPipelineIdx;
	writeUInt32Model(word + 16, 0);
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		writeUInt32Model(word + 24 + pipelineIdx * 8,
				 modelKernelState.pipeline[pipelineIdx].bestScore);
		word[28 + pipelineIdx * 8] =
			modelKernelState.pipeline[pipelineIdx].terminated ? 1 : 0;
	}
}

void resetModelKernel( void ) {
	modelKernelState = ModelKernelState();
}

// Execute one XRT-compatible command in the bit-accurate software model
int executeModelKernel( const vector<uint8_t> &input,
			size_t outputSize,
			vector<uint8_t> &output,
			void *context ) {
	(void)context;
	if ( input.size() < ACCELBEATBYTES ) {
		printf( "Accelerator model command is shorter than one beat.\n" );
		return 1;
	}
	const uint8_t *header = input.data();
	if ( readUInt32Model(header + 0) != ACCELCOMMANDMAGIC ||
	     readUInt16Model(header + 4) != ACCELPROTOCOLVERSION ) {
		printf( "Accelerator model command header is invalid.\n" );
		return 1;
	}

	uint32_t command = header[6];
	uint32_t alphabetSize = header[7];
	uint32_t sequenceLength = readUInt16Model(header + 8);
	uint32_t motifLength = header[10];
	uint32_t pipelineNum = header[11];
	uint32_t scoreThreshold = readUInt32Model(header + 16);
	uint32_t maxUpdates = readUInt32Model(header + 20);
	uint32_t batchSize = readUInt32Model(header + 24);
	uint32_t sequenceBeatNum = readUInt32Model(header + 28);
	if ( pipelineNum < 1 || pipelineNum > ACCELMAXPIPELINE ||
	     sequenceLength < motifLength || sequenceLength > ACCELMAXSEQUENCELENGTH ||
	     motifLength == 0 || motifLength > ACCELMAXMOTIFLENGTH ||
	     alphabetSize == 0 || alphabetSize > ACCELALPHABETMAX ||
	     sequenceBeatNum != (sequenceLength + ACCELBEATBYTES - 1) / ACCELBEATBYTES ) {
		printf( "Accelerator model command configuration is invalid.\n" );
		return 1;
	}

	output.assign(outputSize, 0);
	if ( outputSize < ((size_t)batchSize + 1) * ACCELBEATBYTES ) {
		printf( "Accelerator model output buffer is too small.\n" );
		return 1;
	}

	size_t cursor = ACCELBEATBYTES;
	uint32_t processedNum = 0;
	bool allDone = false;
	int bestPipelineIdx = 0;
	AccelWireResult result[ACCELMAXPIPELINE];

	if ( command == ACCELCOMMAND_BOOTSTRAP ) {
		resetModelKernel();
		if ( cursor + (size_t)sequenceBeatNum * ACCELBEATBYTES > input.size() ) return 1;
		const uint8_t *sequenceInput = input.data() + cursor;
		cursor += (size_t)sequenceBeatNum * ACCELBEATBYTES;

		for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
			if ( cursor + ACCELBEATBYTES + (size_t)motifLength * 2 * ACCELBEATBYTES > input.size() ) return 1;
			ModelPipelineState &state = modelKernelState.pipeline[pipelineIdx];
			state = ModelPipelineState();
			state.configured = true;
			state.executionStarted = false;
			state.active = pipelineIdx < (int)pipelineNum && (input[cursor + 20] & 0x1U) != 0;
			state.sequenceLength = sequenceLength;
			state.motifLength = motifLength;
			state.alphabetSize = alphabetSize;
			state.scoreThreshold = scoreThreshold;
			state.maxUpdates = maxUpdates;
			for ( int stateIdx = 0; stateIdx < 4; stateIdx ++ ) {
				state.randomGenerator.state[stateIdx] = readUInt32Model(input.data() + cursor + stateIdx * 4);
			}
			state.bestScore = readUInt32Model(input.data() + cursor + 16);
			state.updateNum = 0;
			state.terminated = state.active == false || state.bestScore >= state.scoreThreshold;
			state.previousTentativeMotif.assign(motifLength, 0);
			loadSequenceModel(&state, sequenceInput, sequenceLength, sequenceBeatNum);
			cursor += ACCELBEATBYTES;
			unpackMatrixModel(&state, input.data() + cursor, state.bpm);
			cursor += (size_t)motifLength * ACCELBEATBYTES;
			unpackMatrixModel(&state, input.data() + cursor, state.lpmQ12);
			cursor += (size_t)motifLength * ACCELBEATBYTES;
		}
		modelKernelState.configured = true;
		for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
			result[pipelineIdx] = runPipelineModel(&modelKernelState.pipeline[pipelineIdx], 0, true);
		}
		processedNum = 1;
	} else if ( command == ACCELCOMMAND_BATCH ) {
		if ( modelKernelState.configured == false ) {
			printf( "Accelerator model received a batch before bootstrap.\n" );
			return 1;
		}
		for ( uint32_t itemIdx = 0; itemIdx < batchSize; itemIdx ++ ) {
			if ( cursor + (size_t)sequenceBeatNum * ACCELBEATBYTES + ACCELBEATBYTES > input.size() ) return 1;
			const uint8_t *sequenceInput = input.data() + cursor;
			cursor += (size_t)sequenceBeatNum * ACCELBEATBYTES;
			const uint8_t *offsetWord = input.data() + cursor;
			cursor += ACCELBEATBYTES;
			for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
				ModelPipelineState &state = modelKernelState.pipeline[pipelineIdx];
				loadSequenceModel(&state, sequenceInput, sequenceLength, sequenceBeatNum);
				uint32_t tentativeOffset = readUInt32Model(offsetWord + pipelineIdx * 4);
				result[pipelineIdx] = runPipelineModel(&state, tentativeOffset, false);
			}

			allDone = true;
			bestPipelineIdx = 0;
			for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
				allDone = allDone && result[pipelineIdx].terminated;
				if ( result[pipelineIdx].active &&
				     result[pipelineIdx].bestScore > result[bestPipelineIdx].bestScore ) {
					bestPipelineIdx = pipelineIdx;
				}
			}
			packResultModel(output.data() + (size_t)itemIdx * ACCELBEATBYTES,
					(uint16_t)itemIdx,
					result,
					allDone,
					bestPipelineIdx);
			processedNum ++;
			if ( allDone ) break;
		}
	} else {
		printf( "Unsupported accelerator command: %u\n", command );
		return 1;
	}

	allDone = true;
	bestPipelineIdx = 0;
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		allDone = allDone && modelKernelState.pipeline[pipelineIdx].terminated;
		if ( modelKernelState.pipeline[pipelineIdx].active &&
		     modelKernelState.pipeline[pipelineIdx].bestScore >
		     modelKernelState.pipeline[bestPipelineIdx].bestScore ) {
			bestPipelineIdx = pipelineIdx;
		}
	}
	if ( command == ACCELCOMMAND_BOOTSTRAP ) {
		packResultModel(output.data(), 0, result, allDone, bestPipelineIdx);
	}
	packSummaryModel(output.data() + (size_t)batchSize * ACCELBEATBYTES,
			 processedNum,
			 allDone,
			 bestPipelineIdx);
	return 0;
}
