from pathlib import Path

root = Path('hw/kernel_morbius_plus')
host = Path('sw/host_morbius_plus')

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('Expected exactly one occurrence: ' + old[:100])
    return text.replace(old, new, 1)

p = root / 'MorbiusTypes.bsv'
s = p.read_text()
s = replace_once(s, 'typedef 16 NumPE_Profiler;', 'typedef 32 NumPE_Profiler;')
s = replace_once(s, 'typedef UInt#(23) SegmentMass;', 'typedef UInt#(24) SegmentMass;')
s = replace_once(s, 'typedef TDiv#(SequenceRowNum, 2) SequenceBankDepth;', '''typedef TDiv#(SequenceRowNum, 2) SequenceBankDepth;
// Profiler rows supply a complete candidate group; motif rows remain 16 symbols.
typedef NumPE_Profiler ProfilerRowSymbolNum;
typedef TDiv#(1024, ProfilerRowSymbolNum) ProfilerRowNum;
typedef TDiv#(ProfilerRowNum, 2) ProfilerBankDepth;
typedef TLog#(ProfilerRowNum) ProfilerRowAddressWidth;
typedef TLog#(ProfilerBankDepth) ProfilerBankAddressWidth;''')
s = replace_once(s, 'typedef Vector#(SequenceRowSymbolNum, Symbol) SequenceRow;', '''typedef Vector#(SequenceRowSymbolNum, Symbol) SequenceRow;
typedef Vector#(ProfilerRowSymbolNum, Symbol) ProfilerSequenceRow;''')
start = s.index('function SequenceWindow selectSequenceWindow(')
end = s.index('function SymbolSelect decodeSequenceSymbol(', start)
s = s[:start] + '''// One 64-byte input beat contains two complete 32-symbol Profiler rows.
function ProfilerSequenceRow packProfilerSequenceRow(Bit#(512) word, Integer rowIdx);
	ProfilerSequenceRow result = newVector;
	for ( Integer i = 0; i < valueOf(ProfilerRowSymbolNum); i = i + 1 ) begin
		Integer low = (rowIdx * valueOf(ProfilerRowSymbolNum) + i) * 8;
		result[i] = word[low + 4:low];
	end
	return result;
endfunction

function SequenceWindow selectSequenceWindow(ProfilerSequenceRow row0,
					    ProfilerSequenceRow row1,
					    Bit#(ProfilerOffsetWidth) startIndex);
	Vector#(TMul#(2, ProfilerRowSymbolNum), Symbol) shifted = append(row0, row1);
	for ( Integer stage = 0; stage < valueOf(ProfilerOffsetWidth); stage = stage + 1 ) begin
		Integer distance = 2 ** stage;
		Vector#(TMul#(2, ProfilerRowSymbolNum), Symbol) nextValue = newVector;
		for ( Integer i = 0; i < 2 * valueOf(ProfilerRowSymbolNum); i = i + 1 ) begin
			Symbol moved = 0;
			if ( i + distance < 2 * valueOf(ProfilerRowSymbolNum) ) moved = shifted[i + distance];
			nextValue[i] = startIndex[stage] == 1 ? moved : shifted[i];
		end
		shifted = nextValue;
	end
	SequenceWindow result = newVector;
	for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
		result[i] = shifted[i];
	end
	return result;
endfunction

// Keep pipeline-specific motif access independent of the wider Profiler rows.
function MotifSymbolGroup selectMotifWindow(SequenceRow row0,
					  SequenceRow row1,
					  Bit#(4) startIndex);
	Vector#(32, Symbol) shifted = append(row0, row1);
	for ( Integer stage = 0; stage < 4; stage = stage + 1 ) begin
		Integer distance = 2 ** stage;
		Vector#(32, Symbol) nextValue = newVector;
		for ( Integer i = 0; i < 32; i = i + 1 ) begin
			Symbol moved = 0;
			if ( i + distance < 32 ) moved = shifted[i + distance];
			nextValue[i] = startIndex[stage] == 1 ? moved : shifted[i];
		end
		shifted = nextValue;
	end
	MotifSymbolGroup result = newVector;
	for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
		result[i] = shifted[i];
	end
	return result;
endfunction

''' + s[end:]
p.write_text(s)

p = root / 'MorbiusMemory.bsv'
s = p.read_text()
s = replace_once(s, 'interface SequenceMemoryIfc;', '''typedef struct {
	Bool firstRowEven;
	Bit#(ProfilerOffsetWidth) startIndex;
} ProfilerWindowMeta deriving (Bits, Eq, FShow);

interface SequenceMemoryIfc;''')
start = s.index('module mkSequenceMemory(SequenceMemoryIfc);')
end = s.index('// Pipeline-specific four-symbol access only.', start)
s = s[:start] + '''module mkSequenceMemory(SequenceMemoryIfc);
	SdpMemoryIfc#(Bit#(ProfilerBankAddressWidth), ProfilerSequenceRow) evenRowMemory <-
		mkSdpMemory(valueOf(ProfilerBankDepth));
	SdpMemoryIfc#(Bit#(ProfilerBankAddressWidth), ProfilerSequenceRow) oddRowMemory <-
		mkSdpMemory(valueOf(ProfilerBankDepth));

	FIFOF#(SequenceLoadRequest) loadQ <- mkSizedFIFOF(2);
	FIFOF#(ProfilerWindowMeta) windowMetaQ <- mkSizedFIFOF(2);

	// Two 32-symbol rows are written in parallel from each 64-byte beat.
	rule loadRows1;
		SequenceLoadRequest request = loadQ.first;
		loadQ.deq;
		Bit#(ProfilerBankAddressWidth) pairAddress = request.beatIdx;
		evenRowMemory.write(pairAddress, packProfilerSequenceRow(request.word, 0));
		oddRowMemory.write(pairAddress, packProfilerSequenceRow(request.word, 1));
	endrule

	method Action loadBeat(Bit#(4) beatIdx, Bit#(512) word);
		loadQ.enq(SequenceLoadRequest{
			beatIdx: beatIdx,
			word: word
			});
	endmethod

	method Bool loadIdle;
		return !loadQ.notEmpty;
	endmethod

	method Action readWindow(Bit#(11) startPosition) if ( !loadQ.notEmpty );
		Bit#(ProfilerRowAddressWidth) rowAddress =
			truncate(startPosition >> valueOf(ProfilerOffsetWidth));
		Bit#(ProfilerBankAddressWidth) pairAddress = truncate(rowAddress >> 1);
		Bit#(ProfilerOffsetWidth) startIndex = truncate(startPosition);
		Bool firstRowEven = rowAddress[0] == 0;

		if ( firstRowEven ) begin
			evenRowMemory.readRequest(pairAddress);
			oddRowMemory.readRequest(pairAddress);
		end else begin
			oddRowMemory.readRequest(pairAddress);
			if ( rowAddress == fromInteger(valueOf(ProfilerRowNum) - 1) ) begin
				// Wrapped symbols belong only to masked, out-of-range candidates.
				evenRowMemory.readRequest(0);
			end else begin
				evenRowMemory.readRequest(pairAddress + 1);
			end
		end
		windowMetaQ.enq(ProfilerWindowMeta{
			firstRowEven: firstRowEven,
			startIndex: startIndex
			});
	endmethod

	method ActionValue#(SequenceWindow) getWindow;
		ProfilerWindowMeta meta = windowMetaQ.first;
		windowMetaQ.deq;
		ProfilerSequenceRow evenRow = evenRowMemory.readResponse;
		ProfilerSequenceRow oddRow = oddRowMemory.readResponse;
		ProfilerSequenceRow firstRow = meta.firstRowEven ? evenRow : oddRow;
		ProfilerSequenceRow secondRow = meta.firstRowEven ? oddRow : evenRow;
		return selectSequenceWindow(firstRow, secondRow, meta.startIndex);
	endmethod
endmodule

''' + s[end:]
p.write_text(s)

p = root / 'GibbsPipeline.bsv'
s = p.read_text()
s = replace_once(s, '''	Vector#(8, SegmentMass) sum2;
	Vector#(4, SegmentMass) sum4;
	Vector#(2, SegmentMass) sum8;''', '''	Vector#(16, SegmentMass) sum2;
	Vector#(8, SegmentMass) sum4;
	Vector#(4, SegmentMass) sum8;
	Vector#(2, SegmentMass) sum16;''')
start = s.index('function LogProb maxLogProbSegment(')
end = s.index('function GlobalMass boundedGlobalShift(', start)
s = s[:start] + '''function LogProb maxLogProbSegment(Vector#(NumPE_Profiler, LogProb) value,
					   Bit#(ProfilerValidWidth) validNum);
	Vector#(32, LogProb) masked = newVector;
	Vector#(16, LogProb) max2 = newVector;
	Vector#(8, LogProb) max4 = newVector;
	Vector#(4, LogProb) max8 = newVector;
	Vector#(2, LogProb) max16 = newVector;

	for ( Integer i = 0; i < 32; i = i + 1 ) begin
		masked[i] = fromInteger(i) < validNum ? value[i] : 0;
	end
	for ( Integer i = 0; i < 16; i = i + 1 ) begin
		max2[i] = masked[2 * i] > masked[2 * i + 1] ? masked[2 * i] : masked[2 * i + 1];
	end
	for ( Integer i = 0; i < 8; i = i + 1 ) begin
		max4[i] = max2[2 * i] > max2[2 * i + 1] ? max2[2 * i] : max2[2 * i + 1];
	end
	for ( Integer i = 0; i < 4; i = i + 1 ) begin
		max8[i] = max4[2 * i] > max4[2 * i + 1] ? max4[2 * i] : max4[2 * i + 1];
	end
	for ( Integer i = 0; i < 2; i = i + 1 ) begin
		max16[i] = max8[2 * i] > max8[2 * i + 1] ? max8[2 * i] : max8[2 * i + 1];
	end
	return max16[0] > max16[1] ? max16[0] : max16[1];
endfunction

function WeightTree buildWeightTree(Vector#(NumPE_Profiler, WeightValue) weight);
	WeightTree tree = WeightTree{
		sum2: replicate(0),
		sum4: replicate(0),
		sum8: replicate(0),
		sum16: replicate(0),
		total: 0
		};
	for ( Integer i = 0; i < 16; i = i + 1 ) begin
		tree.sum2[i] = zeroExtend(weight[2 * i]) + zeroExtend(weight[2 * i + 1]);
	end
	for ( Integer i = 0; i < 8; i = i + 1 ) begin
		tree.sum4[i] = tree.sum2[2 * i] + tree.sum2[2 * i + 1];
	end
	for ( Integer i = 0; i < 4; i = i + 1 ) begin
		tree.sum8[i] = tree.sum4[2 * i] + tree.sum4[2 * i + 1];
	end
	for ( Integer i = 0; i < 2; i = i + 1 ) begin
		tree.sum16[i] = tree.sum8[2 * i] + tree.sum8[2 * i + 1];
	end
	tree.total = tree.sum16[0] + tree.sum16[1];
	return tree;
endfunction

function Bit#(ProfilerOffsetWidth) selectLocalCandidate(
					Vector#(NumPE_Profiler, WeightValue) weight,
					WeightTree tree,
					Bit#(24) randomFraction,
					Bit#(ProfilerValidWidth) validNum);
	// Keep the complete 24-bit mass by 24-bit random product.
	UInt#(48) totalValue = zeroExtend(tree.total);
	UInt#(48) randomValue = zeroExtend(unpack(randomFraction));
	UInt#(48) product = totalValue * randomValue;
	SegmentMass remaining = truncate(product >> 24);
	Bit#(ProfilerValidWidth) selected = 0;

	if ( remaining >= tree.sum16[0] ) begin
		selected = selected + 16;
		remaining = remaining - tree.sum16[0];
	end
	Bit#(2) index8 = truncate(selected >> 3);
	if ( remaining >= tree.sum8[index8] ) begin
		selected = selected + 8;
		remaining = remaining - tree.sum8[index8];
	end
	Bit#(3) index4 = truncate(selected >> 2);
	if ( remaining >= tree.sum4[index4] ) begin
		selected = selected + 4;
		remaining = remaining - tree.sum4[index4];
	end
	Bit#(4) index2 = truncate(selected >> 1);
	if ( remaining >= tree.sum2[index2] ) begin
		selected = selected + 2;
		remaining = remaining - tree.sum2[index2];
	end
	Bit#(ProfilerOffsetWidth) selectedIdx = truncate(selected);
	SegmentMass selectedWeight = zeroExtend(weight[selectedIdx]);
	if ( remaining >= selectedWeight ) selected = selected + 1;
	if ( selected >= validNum ) selected = validNum - 1;
	return truncate(selected);
endfunction

''' + s[end:]
s = replace_once(s, 'one LPM column and shared 16-symbol windows per cycle',
                       'one LPM column and shared 32-symbol windows per cycle')
p.write_text(s)

p = root / 'PwlLane.bsv'
s = replace_once(p.read_text(), 'eight dual-mode lanes and eight exp-only lanes',
                                'eight dual-mode lanes and twenty-four exp-only lanes')
p.write_text(s)

p = host / 'MorbiusPlus.h'
s = replace_once(p.read_text(), '#define ACCELSEGMENTSIZE 16', '#define ACCELSEGMENTSIZE 32')
p.write_text(s)

p = root / 'README.md'
s = replace_once(p.read_text(), '`NumPE_Profiler = 16`', '`NumPE_Profiler = 32`')
s = replace_once(s, 'two common 16-symbol Profiler window providers', 'two common 32-symbol Profiler window providers')
s = replace_once(s, 'eight log/exp lanes and eight exp-only lanes', 'eight log/exp lanes and twenty-four exp-only lanes')
s = replace_once(s, '- `NumPE_LPM = 4`', '- `NumPE_LPM = 4`\n- `PWL lanes = 32`\n- `ACCELSEGMENTSIZE = 32` in the matching host model')
s = replace_once(s, '## Standalone BSV test', '''The 32-candidate segment has a 24-bit mass and a 48-bit local sampling product.
Profiler window providers use two adjacent 32-symbol rows, including unaligned windows;
pipeline-specific motif memories retain their four-symbol access path.
The host model uses the same 32-candidate segment size. Rebuild both host and xclbin.
Changing the segment width changes random-number consumption and fixed-point grouping,
so an identical seed need not reproduce the former 16-lane result.

## Standalone BSV test''')
p.write_text(s)

for name in ['TestProfiler32.bsv', 'TestSequenceMemory32.bsv']:
    (root / 'test' / name).write_text((Path('.github') / name).read_text())

print('Applied fixed 16 pipelines / 32 Profiler PEs / 32 PWL lanes / 4 LPM PEs.')
