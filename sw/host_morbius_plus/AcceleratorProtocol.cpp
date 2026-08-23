#include "MorbiusPlus.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <vector>
using namespace std;


static void writeUInt16( uint8_t *buffer, uint16_t value ) {
	buffer[0] = (uint8_t)(value & 0xffU);
	buffer[1] = (uint8_t)((value >> 8) & 0xffU);
}

static void writeUInt32( uint8_t *buffer, uint32_t value ) {
	for ( int i = 0; i < 4; i ++ ) buffer[i] = (uint8_t)((value >> (8 * i)) & 0xffU);
}

static uint16_t readUInt16( const uint8_t *buffer ) {
	return (uint16_t)buffer[0] | ((uint16_t)buffer[1] << 8);
}

static uint32_t readUInt32( const uint8_t *buffer ) {
	uint32_t value = 0;
	for ( int i = 0; i < 4; i ++ ) value = value | ((uint32_t)buffer[i] << (8 * i));
	return value;
}

static void setBits( uint8_t *buffer, size_t bitOffset, uint32_t value, size_t bitWidth ) {
	for ( size_t bitIdx = 0; bitIdx < bitWidth; bitIdx ++ ) {
		size_t outputBit = bitOffset + bitIdx;
		uint8_t bitValue = (uint8_t)((value >> bitIdx) & 0x1U);
		if ( bitValue ) buffer[outputBit >> 3] |= (uint8_t)(1U << (outputBit & 0x7U));
		else buffer[outputBit >> 3] &= (uint8_t)~(1U << (outputBit & 0x7U));
	}
}

static uint32_t getBits( const uint8_t *buffer, size_t bitOffset, size_t bitWidth ) {
	uint32_t value = 0;
	for ( size_t bitIdx = 0; bitIdx < bitWidth; bitIdx ++ ) {
		size_t inputBit = bitOffset + bitIdx;
		uint32_t bitValue = (uint32_t)((buffer[inputBit >> 3] >> (inputBit & 0x7U)) & 0x1U);
		value = value | (bitValue << bitIdx);
	}
	return value;
}

static void appendEmptyBeat( vector<uint8_t> &buffer ) {
	buffer.insert(buffer.end(), ACCELBEATBYTES, 0);
}

static void writeCommandHeader( const Config *config,
				const Dataset *dataset,
				uint8_t command,
				uint32_t batchSize,
				vector<uint8_t> &input ) {
	appendEmptyBeat(input);
	uint8_t *header = input.data();
	writeUInt32(header + 0, ACCELCOMMANDMAGIC);
	writeUInt16(header + 4, ACCELPROTOCOLVERSION);
	header[6] = command;
	header[7] = (uint8_t)dataset->alphabetSize;
	writeUInt16(header + 8, (uint16_t)dataset->sequenceLength);
	header[10] = (uint8_t)config->motifLength;
	header[11] = (uint8_t)config->numPipeline;
	writeUInt32(header + 16, (uint32_t)calculateRawScoreThreshold(config, dataset));
	writeUInt32(header + 20, (uint32_t)config->maxUpdateNum);
	writeUInt32(header + 24, batchSize);
	writeUInt32(header + 28,
			(uint32_t)((dataset->sequenceLength + ACCELBEATBYTES - 1) / ACCELBEATBYTES));
}

static void appendSequence( const Dataset *dataset,
			    size_t sequenceIdx,
			    vector<uint8_t> &input ) {
	size_t beatNum = (dataset->sequenceLength + ACCELBEATBYTES - 1) / ACCELBEATBYTES;
	size_t begin = input.size();
	input.insert(input.end(), beatNum * ACCELBEATBYTES, 0);
	for ( size_t position = 0; position < dataset->sequenceLength; position ++ ) {
		int symbol = dataset->symbolMap[(unsigned char)dataset->sequences[sequenceIdx][position]];
		input[begin + position] = (uint8_t)symbol;
	}
}

static void appendMatrixColumns( const Config *config,
				 const Dataset *dataset,
				 const vector<uint32_t> &matrix,
				 vector<uint8_t> &input ) {
	for ( size_t column = 0; column < config->motifLength; column ++ ) {
		appendEmptyBeat(input);
		uint8_t *word = input.data() + input.size() - ACCELBEATBYTES;
		for ( int symbol = 0; symbol < ACCELALPHABETMAX; symbol ++ ) {
			uint32_t value = 0;
			if ( symbol < dataset->alphabetSize ) {
				value = matrix[(size_t)symbol * config->motifLength + column];
			}
			setBits(word, (size_t)symbol * 18, value, 18);
		}
	}
}

// Build the zeroth-iteration command
void buildBootstrapCommand( const Config *config,
			    const Dataset *dataset,
			    const vector<AccelPipelineHostState> &pipelineStates,
			    vector<uint8_t> &input ) {
	if ( pipelineStates.size() != ACCELMAXPIPELINE ) {
		printf( "Bootstrap requires exactly %d physical pipeline states.\n", ACCELMAXPIPELINE );
		exit(1);
	}
	input.clear();
	writeCommandHeader(config, dataset, ACCELCOMMAND_BOOTSTRAP, 1, input);
	appendSequence(dataset, 0, input);

	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		const AccelPipelineHostState &state = pipelineStates[(size_t)pipelineIdx];
		appendEmptyBeat(input);
		uint8_t *stateWord = input.data() + input.size() - ACCELBEATBYTES;
		for ( int stateIdx = 0; stateIdx < 4; stateIdx ++ ) {
			writeUInt32(stateWord + stateIdx * 4, state.randomGenerator.state[stateIdx]);
		}
		writeUInt32(stateWord + 16, state.bestScore);
		stateWord[20] = pipelineIdx < config->numPipeline ? 1 : 0;
		appendMatrixColumns(config, dataset, state.initialBPM, input);
		appendMatrixColumns(config, dataset, state.initialLPMQ12, input);
	}
}

// Build one batch of subsequent Gibbs iterations
void buildBatchCommand( const Config *config,
			const Dataset *dataset,
			const vector<AccelPipelineHostState> &pipelineStates,
			size_t sequenceStart,
			size_t sequenceNum,
			vector<uint8_t> &input ) {
	if ( sequenceNum == 0 || sequenceNum > dataset->sequences.size() ) {
		printf( "Invalid accelerator batch size: %lu\n", (unsigned long)sequenceNum );
		exit(1);
	}
	input.clear();
	writeCommandHeader(config, dataset, ACCELCOMMAND_BATCH, (uint32_t)sequenceNum, input);

	for ( size_t itemIdx = 0; itemIdx < sequenceNum; itemIdx ++ ) {
		size_t sequenceIdx = (sequenceStart + itemIdx) % dataset->sequences.size();
		appendSequence(dataset, sequenceIdx, input);
		appendEmptyBeat(input);
		uint8_t *offsetWord = input.data() + input.size() - ACCELBEATBYTES;
		for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
			uint32_t offset = pipelineStates[(size_t)pipelineIdx].offsets[sequenceIdx];
			writeUInt32(offsetWord + pipelineIdx * 4, offset);
		}
	}
}

// Parse one per-sequence result beat
void parseResultBeat( const uint8_t *beat,
		      vector<AccelWireResult> &results ) {
	if ( readUInt32(beat + 0) != ACCELRESULTMAGIC ||
	     readUInt16(beat + 4) != ACCELPROTOCOLVERSION ) {
		printf( "Invalid Morbius+ accelerator result header.\n" );
		exit(1);
	}
	results.resize(ACCELMAXPIPELINE);
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		size_t base = 64 + (size_t)pipelineIdx * 96;
		results[(size_t)pipelineIdx].newOffset = getBits(beat, base + 0, 11);
		results[(size_t)pipelineIdx].bestUpdate = getBits(beat, base + 11, 1) != 0;
		results[(size_t)pipelineIdx].terminated = getBits(beat, base + 12, 1) != 0;
		results[(size_t)pipelineIdx].active = getBits(beat, base + 13, 1) != 0;
		results[(size_t)pipelineIdx].bestScore = getBits(beat, base + 16, 32);
		results[(size_t)pipelineIdx].updateNum = getBits(beat, base + 48, 32);
	}
}

// Parse one fixed-position summary beat
void parseSummaryBeat( const uint8_t *beat, AccelSummary *summary ) {
	if ( readUInt32(beat + 0) != ACCELRESULTMAGIC ||
	     readUInt16(beat + 4) != ACCELPROTOCOLVERSION ) {
		printf( "Invalid Morbius+ accelerator summary header.\n" );
		exit(1);
	}
	summary->processedNum = readUInt32(beat + 8);
	summary->allDone = (beat[12] & 0x1U) != 0;
	summary->bestPipelineIdx = beat[13];
	summary->cycleNum = readUInt32(beat + 16);
	for ( int pipelineIdx = 0; pipelineIdx < ACCELMAXPIPELINE; pipelineIdx ++ ) {
		summary->bestScore[pipelineIdx] = readUInt32(beat + 24 + pipelineIdx * 8);
		summary->terminated[pipelineIdx] = (beat[28 + pipelineIdx * 8] & 0x1U) != 0;
	}
}
