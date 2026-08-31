package MorbiusTypes;

import Vector::*;


typedef 16 NumPipeline;
typedef 16 NumPE_Profiler;
typedef 4 NumPE_LPM;
typedef TLog#(NumPipeline) PipelineIndexWidth;
typedef TLog#(NumPE_Profiler) ProfilerOffsetWidth;
typedef TAdd#(ProfilerOffsetWidth, 1) ProfilerValidWidth;
typedef 4 PipelinePerResultBeat;
typedef TDiv#(NumPipeline, PipelinePerResultBeat) ResultBeatNum;
typedef TLog#(ResultBeatNum) ResultBeatIndexWidth;
typedef 16 SequenceBeatNum;
typedef 128 MotifLengthMax;
typedef 20 AlphabetMax;
typedef 32 MotifBankDepth;
typedef 128 SegmentMax;

typedef Bit#(360) MatrixColumn;
typedef UInt#(18) BpmCount;
typedef UInt#(19) PwlValue;
typedef UInt#(32) LogProb;
typedef UInt#(TAdd#(19, ProfilerOffsetWidth)) SegmentMass;
typedef UInt#(48) GlobalMass;

typedef enum {
	PWL_LOG2,
	PWL_EXP2
} PwlMode deriving (Bits, Eq, FShow);

typedef struct {
	PwlMode mode;
	UInt#(32) value;
	Bit#(16) tag;
} PwlRequest deriving (Bits, Eq, FShow);

typedef struct {
	PwlMode mode;
	PwlValue value;
	Bit#(16) tag;
} PwlResponse deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(11) sequenceLength;
	Bit#(8) motifLength;
	Bit#(5) alphabetSize;
	UInt#(32) scoreThreshold;
	UInt#(32) maxUpdates;
} PipelineConfig deriving (Bits, Eq, FShow);

typedef struct {
	Vector#(NumPE_Profiler, LogProb) logProb;
	Bit#(11) startOffset;
	Bit#(ProfilerValidWidth) validNum;
} LogProbSegment deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(11) startOffset;
	UInt#(16) exponent;
	SegmentMass mass;
	Bit#(ProfilerOffsetWidth) localOffset;
	Bit#(ProfilerValidWidth) validNum;
} SegmentSummary deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(11) newOffset;
	UInt#(32) bestScore;
	UInt#(32) updateNum;
	Bool bestUpdate;
	Bool terminated;
	Bool active;
} PipelineResult deriving (Bits, Eq, FShow);

function UInt#(18) getMatrixEntry(MatrixColumn columnWord, Bit#(5) symbol);
	UInt#(9) shiftAmount = zeroExtend(unpack(symbol)) * 18;
	return unpack(truncate(columnWord >> shiftAmount));
endfunction

function MatrixColumn setMatrixEntry(MatrixColumn columnWord,
				     Bit#(5) symbol,
				     UInt#(18) value);
	UInt#(9) shiftAmount = zeroExtend(unpack(symbol)) * 18;
	Bit#(360) entryMask = zeroExtend(18'h3ffff) << shiftAmount;
	Bit#(360) entryValue = zeroExtend(pack(value)) << shiftAmount;
	return (columnWord & ~entryMask) | entryValue;
endfunction

function UInt#(32) maxBpmEntry(MatrixColumn columnWord, Bit#(5) alphabetSize);
	UInt#(32) maximum = 0;
	for ( Integer i = 0; i < valueOf(AlphabetMax); i = i + 1 ) begin
		if ( fromInteger(i) < alphabetSize ) begin
			UInt#(18) value = getMatrixEntry(columnWord, fromInteger(i));
			if ( zeroExtend(value) > maximum ) maximum = zeroExtend(value);
		end
	end
	return maximum;
endfunction

function Bit#(5) getSequenceSymbol(Vector#(SequenceBeatNum, Bit#(512)) sequenceWords,
				   Bit#(11) position);
	Bit#(4) wordIdx = truncate(position >> 6);
	Bit#(6) byteIdx = truncate(position);
	UInt#(9) shiftAmount = zeroExtend(unpack(byteIdx)) * 8;
	Bit#(512) word = sequenceWords[wordIdx];
	return truncate(word >> shiftAmount);
endfunction

endpackage
