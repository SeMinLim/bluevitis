package MorbiusTypes;

import Vector::*;


//------------------------------------------------------------------------------------
// Fixed U50 prototype configuration
//------------------------------------------------------------------------------------
typedef 16 NumPipeline;
typedef 16 NumPE_Profiler;
typedef 4 NumPE_LPM;
typedef 4 PipelinePerResultBeat;
typedef 16 SequenceRowSymbolNum;
typedef 64 SequenceRowNum;
typedef TDiv#(SequenceRowNum, 2) SequenceBankDepth;
typedef 128 MotifLengthMax;
typedef 20 AlphabetMax;
typedef 32 MotifGroupDepth;

typedef TLog#(NumPipeline) PipelineIndexWidth;
typedef TLog#(NumPE_Profiler) ProfilerOffsetWidth;
typedef TAdd#(ProfilerOffsetWidth, 1) ProfilerValidWidth;
typedef TDiv#(NumPipeline, PipelinePerResultBeat) ResultBeatNum;
typedef TLog#(ResultBeatNum) ResultBeatIndexWidth;


//------------------------------------------------------------------------------------
// Compact datapath types
//------------------------------------------------------------------------------------
typedef Bit#(5) Symbol;
typedef UInt#(18) BpmCount;
typedef UInt#(17) LogValue;
typedef UInt#(24) LogProb;
typedef UInt#(19) WeightValue;
typedef UInt#(23) SegmentMass;
typedef UInt#(36) GlobalMass;
typedef UInt#(25) ScoreValue;
typedef UInt#(24) PwlInput;

typedef Vector#(AlphabetMax, BpmCount) BpmEntries;
typedef Vector#(AlphabetMax, LogValue) LpmEntries;
typedef Vector#(NumPE_LPM, BpmEntries) BpmGroup;
typedef Vector#(NumPE_LPM, LpmEntries) LpmGroup;
typedef Bit#(360) MatrixColumn;
typedef Vector#(SequenceRowSymbolNum, Symbol) SequenceRow;
typedef Vector#(NumPE_Profiler, Symbol) SequenceWindow;
typedef Vector#(NumPE_LPM, Symbol) MotifSymbolGroup;


//------------------------------------------------------------------------------------
// PWL array messages
//------------------------------------------------------------------------------------
typedef enum {
	PWL_LOG2,
	PWL_EXP2
} PwlMode deriving (Bits, Eq, FShow);

typedef struct {
	PwlMode mode;
	Vector#(NumPE_Profiler, PwlInput) value;
	Bit#(NumPE_Profiler) validMask;
} PwlArrayRequest deriving (Bits, Eq, FShow);

typedef struct {
	Vector#(NumPE_Profiler, WeightValue) value;
} PwlArrayResponse deriving (Bits, Eq, FShow);


//------------------------------------------------------------------------------------
// Gibbs-array messages
//------------------------------------------------------------------------------------
typedef struct {
	Bit#(11) sequenceLength;
	Bit#(8) motifLength;
	Bit#(5) alphabetSize;
	ScoreValue scoreThreshold;
	UInt#(32) maxUpdates;
} PipelineConfig deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(11) newOffset;
	ScoreValue bestScore;
	UInt#(32) updateNum;
	Bool bestUpdate;
	Bool terminated;
} PipelineResult deriving (Bits, Eq, FShow);


//------------------------------------------------------------------------------------
// Protocol conversion
//------------------------------------------------------------------------------------
function BpmEntries unpackBpmColumn(MatrixColumn columnWord);
	BpmEntries result = newVector;
	for ( Integer i = 0; i < valueOf(AlphabetMax); i = i + 1 ) begin
		Integer low = i * 18;
		result[i] = unpack(columnWord[low + 17:low]);
	end
	return result;
endfunction

function LpmEntries unpackLpmColumn(MatrixColumn columnWord);
	LpmEntries result = newVector;
	for ( Integer i = 0; i < valueOf(AlphabetMax); i = i + 1 ) begin
		Integer low = i * 18;
		UInt#(18) encodedValue = unpack(columnWord[low + 17:low]);
		result[i] = truncate(encodedValue);
	end
	return result;
endfunction

function MatrixColumn packBpmColumn(BpmEntries entry);
	MatrixColumn result = 0;
	for ( Integer i = 0; i < valueOf(AlphabetMax); i = i + 1 ) begin
		Integer low = i * 18;
		result[low + 17:low] = pack(entry[i]);
	end
	return result;
endfunction

function MatrixColumn packLpmColumn(LpmEntries entry);
	MatrixColumn result = 0;
	for ( Integer i = 0; i < valueOf(AlphabetMax); i = i + 1 ) begin
		Integer low = i * 18;
		Bit#(18) encodedValue = zeroExtend(pack(entry[i]));
		result[low + 17:low] = encodedValue;
	end
	return result;
endfunction


//------------------------------------------------------------------------------------
// Fixed-slice matrix access
//------------------------------------------------------------------------------------
function BpmCount getBpmEntry(BpmEntries entry, Symbol symbol);
	case ( symbol )
		0: return entry[0];
		1: return entry[1];
		2: return entry[2];
		3: return entry[3];
		4: return entry[4];
		5: return entry[5];
		6: return entry[6];
		7: return entry[7];
		8: return entry[8];
		9: return entry[9];
		10: return entry[10];
		11: return entry[11];
		12: return entry[12];
		13: return entry[13];
		14: return entry[14];
		15: return entry[15];
		16: return entry[16];
		17: return entry[17];
		18: return entry[18];
		default: return entry[19];
	endcase
endfunction

function LogValue getLpmEntry(LpmEntries entry, Symbol symbol);
	case ( symbol )
		0: return entry[0];
		1: return entry[1];
		2: return entry[2];
		3: return entry[3];
		4: return entry[4];
		5: return entry[5];
		6: return entry[6];
		7: return entry[7];
		8: return entry[8];
		9: return entry[9];
		10: return entry[10];
		11: return entry[11];
		12: return entry[12];
		13: return entry[13];
		14: return entry[14];
		15: return entry[15];
		16: return entry[16];
		17: return entry[17];
		18: return entry[18];
		default: return entry[19];
	endcase
endfunction

function BpmEntries setBpmEntry(BpmEntries entry,
				Symbol symbol,
				BpmCount value);
	BpmEntries result = entry;
	case ( symbol )
		0: result[0] = value;
		1: result[1] = value;
		2: result[2] = value;
		3: result[3] = value;
		4: result[4] = value;
		5: result[5] = value;
		6: result[6] = value;
		7: result[7] = value;
		8: result[8] = value;
		9: result[9] = value;
		10: result[10] = value;
		11: result[11] = value;
		12: result[12] = value;
		13: result[13] = value;
		14: result[14] = value;
		15: result[15] = value;
		16: result[16] = value;
		17: result[17] = value;
		18: result[18] = value;
		default: result[19] = value;
	endcase
	return result;
endfunction

function LpmEntries setLpmEntry(LpmEntries entry,
				Symbol symbol,
				LogValue value);
	LpmEntries result = entry;
	case ( symbol )
		0: result[0] = value;
		1: result[1] = value;
		2: result[2] = value;
		3: result[3] = value;
		4: result[4] = value;
		5: result[5] = value;
		6: result[6] = value;
		7: result[7] = value;
		8: result[8] = value;
		9: result[9] = value;
		10: result[10] = value;
		11: result[11] = value;
		12: result[12] = value;
		13: result[13] = value;
		14: result[14] = value;
		15: result[15] = value;
		16: result[16] = value;
		17: result[17] = value;
		18: result[18] = value;
		default: result[19] = value;
	endcase
	return result;
endfunction

function ScoreValue maxBpmEntry(BpmEntries entry, Bit#(5) alphabetSize);
	Vector#(20, ScoreValue) masked = replicate(0);
	Vector#(10, ScoreValue) max2 = newVector;
	Vector#(5, ScoreValue) max4 = newVector;
	ScoreValue maximum01 = 0;
	ScoreValue maximum23 = 0;
	ScoreValue maximum03 = 0;

	for ( Integer i = 0; i < valueOf(AlphabetMax); i = i + 1 ) begin
		if ( fromInteger(i) < alphabetSize ) masked[i] = zeroExtend(entry[i]);
	end
	for ( Integer i = 0; i < 10; i = i + 1 ) begin
		max2[i] = masked[2 * i] > masked[2 * i + 1] ?
			  masked[2 * i] : masked[2 * i + 1];
	end
	for ( Integer i = 0; i < 5; i = i + 1 ) begin
		max4[i] = max2[2 * i] > max2[2 * i + 1] ?
			  max2[2 * i] : max2[2 * i + 1];
	end
	maximum01 = max4[0] > max4[1] ? max4[0] : max4[1];
	maximum23 = max4[2] > max4[3] ? max4[2] : max4[3];
	maximum03 = maximum01 > maximum23 ? maximum01 : maximum23;
	return maximum03 > max4[4] ? maximum03 : max4[4];
endfunction


//------------------------------------------------------------------------------------
// Sequence conversion and bounded selection
//------------------------------------------------------------------------------------
function SequenceRow packSequenceRow(Bit#(512) word, Integer rowIdx);
	SequenceRow result = newVector;
	for ( Integer i = 0; i < valueOf(SequenceRowSymbolNum); i = i + 1 ) begin
		Integer low = (rowIdx * valueOf(SequenceRowSymbolNum) + i) * 8;
		result[i] = word[low + 4:low];
	end
	return result;
endfunction

function SequenceWindow selectSequenceWindow(SequenceRow row0,
				      SequenceRow row1,
				      Bit#(4) startIndex);
	Vector#(32, Symbol) combined = append(row0, row1);
	SequenceWindow result = newVector;
	case ( startIndex )
		0: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i];
		end
		1: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 1];
		end
		2: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 2];
		end
		3: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 3];
		end
		4: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 4];
		end
		5: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 5];
		end
		6: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 6];
		end
		7: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 7];
		end
		8: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 8];
		end
		9: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 9];
		end
		10: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 10];
		end
		11: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 11];
		end
		12: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 12];
		end
		13: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 13];
		end
		14: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 14];
		end
		default: begin
			for ( Integer i = 0; i < 16; i = i + 1 ) result[i] = combined[i + 15];
		end
	endcase
	return result;
endfunction

endpackage
