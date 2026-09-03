package GibbsPipeline;

import FIFOF::*;
import Vector::*;

import MorbiusMemory::*;
import MorbiusTypes::*;
import PwlLane::*;
import RandomGenerator::*;


typedef enum {
	ARRAY_IDLE,
	ARRAY_UPDATE_READ,
	ARRAY_UPDATE_APPLY,
	ARRAY_UPDATE_LOG_WAIT,
	ARRAY_PROFILE,
	ARRAY_INSERT
} ArrayState deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(11) segmentStart;
	Bit#(2) columnOffset;
	Bit#(ProfilerValidWidth) validNum;
	Bool finalColumn;
	Bool finalSegment;
} ProfilerMeta deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(11) segmentStart;
	Bit#(ProfilerValidWidth) validNum;
	Bool finalSegment;
	Vector#(NumPipeline, UInt#(12)) exponent;
} Phase2Meta deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(11) segmentStart;
	Bool finalSegment;
	Vector#(NumPipeline, UInt#(12)) exponent;
	Vector#(NumPipeline, SegmentMass) mass;
	Vector#(NumPipeline, Bit#(ProfilerOffsetWidth)) localOffset;
	Vector#(NumPipeline, Bit#(24)) reservoirRandom;
} ReservoirCandidate deriving (Bits, Eq, FShow);

typedef struct {
	Bool finalSegment;
	Vector#(NumPipeline, Bool) valid;
	Vector#(NumPipeline, Bool) replaceFirst;
	Vector#(NumPipeline, GlobalMass) nextMass;
	Vector#(NumPipeline, GlobalMass) alignedSegmentMass;
	Vector#(NumPipeline, Bit#(24)) randomFraction;
	Vector#(NumPipeline, Bit#(11)) replacementOffset;
} ReservoirMultiplyRequest deriving (Bits, Eq, FShow);

typedef struct {
	Bool finalSegment;
	Vector#(NumPipeline, Bool) valid;
	Vector#(NumPipeline, Bool) replaceFirst;
	Vector#(NumPipeline, UInt#(60)) randomProduct;
	Vector#(NumPipeline, UInt#(60)) segmentRange;
	Vector#(NumPipeline, Bit#(11)) replacementOffset;
} ReservoirMultiplyResponse deriving (Bits, Eq, FShow);

typedef struct {
	Vector#(8, SegmentMass) sum2;
	Vector#(4, SegmentMass) sum4;
	Vector#(2, SegmentMass) sum8;
	SegmentMass total;
} WeightTree deriving (Bits, Eq, FShow);

interface GibbsPipelineArrayIfc;
	method Action configure(PipelineConfig pipelineConfig);
	method Action configurePipeline(Bit#(PipelineIndexWidth) pipelineIdx,
					Bit#(128) randomSeed,
					ScoreValue initialBestScore);
	method Action loadSequenceBeat(Bit#(4) beatIdx, Bit#(512) word);
	method Action loadBpmGroup(Bit#(PipelineIndexWidth) pipelineIdx,
				  Bit#(5) address,
				  BpmGroup value);
	method Action loadLpmGroup(Bit#(PipelineIndexWidth) pipelineIdx,
				  Bit#(5) address,
				  LpmGroup value);
	method Action startBootstrap;
	method Action startUpdate(Vector#(NumPipeline, Bit#(11)) tentativeOffset);
	method ActionValue#(Vector#(NumPipeline, PipelineResult)) result;
	method Bool busy;
endinterface


function Bit#(ProfilerValidWidth) calculateValidNum(Bit#(11) candidateNum,
						     Bit#(11) startOffset);
	Bit#(11) remaining = candidateNum - startOffset;
	if ( remaining >= fromInteger(valueOf(NumPE_Profiler)) ) begin
		return fromInteger(valueOf(NumPE_Profiler));
	end else begin
		return truncate(remaining);
	end
endfunction

function LogProb maxLogProbSegment(Vector#(NumPE_Profiler, LogProb) value,
					   Bit#(ProfilerValidWidth) validNum);
	Vector#(16, LogProb) masked = newVector;
	Vector#(8, LogProb) max2 = newVector;
	Vector#(4, LogProb) max4 = newVector;
	Vector#(2, LogProb) max8 = newVector;

	for ( Integer i = 0; i < 16; i = i + 1 ) begin
		masked[i] = fromInteger(i) < validNum ? value[i] : 0;
	end
	for ( Integer i = 0; i < 8; i = i + 1 ) begin
		max2[i] = masked[2 * i] > masked[2 * i + 1] ?
			  masked[2 * i] : masked[2 * i + 1];
	end
	for ( Integer i = 0; i < 4; i = i + 1 ) begin
		max4[i] = max2[2 * i] > max2[2 * i + 1] ?
			  max2[2 * i] : max2[2 * i + 1];
	end
	for ( Integer i = 0; i < 2; i = i + 1 ) begin
		max8[i] = max4[2 * i] > max4[2 * i + 1] ?
			  max4[2 * i] : max4[2 * i + 1];
	end
	return max8[0] > max8[1] ? max8[0] : max8[1];
endfunction

function WeightTree buildWeightTree(Vector#(NumPE_Profiler, WeightValue) weight);
	WeightTree tree = WeightTree{
		sum2: replicate(0),
		sum4: replicate(0),
		sum8: replicate(0),
		total: 0
		};
	for ( Integer i = 0; i < 8; i = i + 1 ) begin
		tree.sum2[i] = zeroExtend(weight[2 * i]) + zeroExtend(weight[2 * i + 1]);
	end
	for ( Integer i = 0; i < 4; i = i + 1 ) begin
		tree.sum4[i] = tree.sum2[2 * i] + tree.sum2[2 * i + 1];
	end
	for ( Integer i = 0; i < 2; i = i + 1 ) begin
		tree.sum8[i] = tree.sum4[2 * i] + tree.sum4[2 * i + 1];
	end
	tree.total = tree.sum8[0] + tree.sum8[1];
	return tree;
endfunction

function Bit#(ProfilerOffsetWidth) selectLocalCandidate(
					Vector#(NumPE_Profiler, WeightValue) weight,
					WeightTree tree,
					Bit#(24) randomFraction,
					Bit#(ProfilerValidWidth) validNum);
	UInt#(47) product = zeroExtend(tree.total) * zeroExtend(unpack(randomFraction));
	SegmentMass remaining = truncate(product >> 24);
	Bit#(ProfilerValidWidth) selected = 0;

	if ( remaining >= tree.sum8[0] ) begin
		selected = selected + 8;
		remaining = remaining - tree.sum8[0];
	end
	Bit#(2) index4 = truncate(selected >> 2);
	if ( remaining >= tree.sum4[index4] ) begin
		selected = selected + 4;
		remaining = remaining - tree.sum4[index4];
	end
	Bit#(3) index2 = truncate(selected >> 1);
	if ( remaining >= tree.sum2[index2] ) begin
		selected = selected + 2;
		remaining = remaining - tree.sum2[index2];
	end
	Bit#(ProfilerOffsetWidth) selectedIdx = truncate(selected);
	if ( remaining >= zeroExtend(weight[selectedIdx]) ) selected = selected + 1;
	if ( selected >= validNum ) selected = validNum - 1;
	return truncate(selected);
endfunction

function GlobalMass boundedGlobalShift(GlobalMass value, UInt#(12) difference);
	if ( difference >= 36 ) return 0;
	else return value >> truncate(difference);
endfunction


module mkGibbsPipelineArray(GibbsPipelineArrayIfc);
	//------------------------------------------------------------------------------------
	// Shared controller and independent Gibbs state
	//------------------------------------------------------------------------------------
	Reg#(PipelineConfig) configR <- mkRegU;
	Reg#(Bool) configuredR <- mkReg(False);
	Reg#(Bool) executionStartedR <- mkReg(False);
	Reg#(ArrayState) stateR <- mkReg(ARRAY_IDLE);

	Vector#(NumPipeline, Reg#(ScoreValue)) bestScoreR <- replicateM(mkReg(0));
	Vector#(NumPipeline, Reg#(UInt#(32))) updateNumR <- replicateM(mkReg(0));
	Vector#(NumPipeline, Reg#(Bool)) terminatedR <- replicateM(mkReg(False));
	Vector#(NumPipeline, Reg#(RandomState)) randomStateR <- replicateM(mkRegU);
	Vector#(NumPipeline, Reg#(Bit#(11))) tentativeOffsetR <- replicateM(mkReg(0));
	Vector#(NumPipeline, Reg#(Bit#(11))) selectedOffsetR <- replicateM(mkReg(0));

	Vector#(NumPipeline, BpmMemoryIfc) bpmMemory <- replicateM(mkBpmMemory);
	Vector#(NumPipeline, LpmMemoryIfc) lpmMemory <- replicateM(mkLpmMemory);
	Vector#(NumPipeline, SequenceMemoryIfc) sequenceMemory <- replicateM(mkSequenceMemory);
	Vector#(NumPipeline, MotifMemoryIfc) previousMotifMemory <-
		replicateM(mkMotifMemory);
	Vector#(NumPipeline, PwlArrayIfc) pwlArray <- replicateM(mkPwlArray);
	FIFOF#(Vector#(NumPipeline, PipelineResult)) resultQ <- mkFIFOF;

	//------------------------------------------------------------------------------------
	// Selective BPM and LPM update
	//------------------------------------------------------------------------------------
	Reg#(Bit#(5)) updateGroupAddressR <- mkReg(0);
	Vector#(NumPipeline, Vector#(NumPE_LPM, Reg#(Bool))) changedValidR <-
		replicateM(replicateM(mkReg(False)));
	Vector#(NumPipeline, Vector#(NumPE_LPM, Reg#(Symbol))) changedPreviousSymbolR <-
		replicateM(replicateM(mkReg(0)));
	Vector#(NumPipeline, Vector#(NumPE_LPM, Reg#(Symbol))) changedCurrentSymbolR <-
		replicateM(replicateM(mkReg(0)));

	//------------------------------------------------------------------------------------
	// Profiler Phase 1
	//------------------------------------------------------------------------------------
	Reg#(Bool) phase1RequestOnR <- mkReg(False);
	Reg#(Bit#(11)) candidateNumR <- mkReg(0);
	Reg#(Bit#(11)) phase1SegmentStartR <- mkReg(0);
	Reg#(Bit#(8)) phase1ColumnR <- mkReg(0);
	Vector#(NumPipeline, Vector#(NumPE_Profiler, Reg#(LogProb))) phase1AccumR <-
		replicateM(replicateM(mkReg(0)));
	FIFOF#(ProfilerMeta) phase1MetaQ <- mkSizedFIFOF(2);

	//------------------------------------------------------------------------------------
	// Profiler Phase 2 and streaming weighted reservoir
	//------------------------------------------------------------------------------------
	FIFOF#(Phase2Meta) phase2MetaQ <- mkSizedFIFOF(2);
	FIFOF#(ReservoirCandidate) reservoirCandidateQ <- mkSizedFIFOF(2);
	FIFOF#(ReservoirMultiplyRequest) reservoirMultiplyRequestQ <- mkSizedFIFOF(2);
	FIFOF#(ReservoirMultiplyResponse) reservoirMultiplyResponseQ <- mkSizedFIFOF(2);
	Vector#(NumPipeline, Reg#(Bool)) globalMassValidR <- replicateM(mkReg(False));
	Vector#(NumPipeline, Reg#(UInt#(12))) globalExponentR <- replicateM(mkReg(0));
	Vector#(NumPipeline, Reg#(GlobalMass)) globalMassR <- replicateM(mkReg(0));

	//------------------------------------------------------------------------------------
	// Fused tentative-motif insertion and score calculation
	//------------------------------------------------------------------------------------
	Reg#(Bool) insertRequestOnR <- mkReg(False);
	Reg#(Bit#(5)) insertGroupAddressR <- mkReg(0);
	FIFOF#(Bit#(5)) insertGroupAddressQ <- mkSizedFIFOF(2);
	Vector#(NumPipeline, Reg#(ScoreValue)) scoreAccumR <- replicateM(mkReg(0));

	function Bool allSequenceLoadIdle();
		Bool allIdle = True;
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			allIdle = allIdle && sequenceMemory[p].loadIdle;
		end
		return allIdle;
	endfunction

	function Bool allPipelineTerminated();
		Bool allDone = True;
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			allDone = allDone && terminatedR[p];
		end
		return allDone;
	endfunction

	function Action beginProfiler();
		action
			Bit#(11) candidateNum = configR.sequenceLength -
					       zeroExtend(configR.motifLength) + 1;
			candidateNumR <= candidateNum;
			phase1SegmentStartR <= 0;
			phase1ColumnR <= 0;
			phase1RequestOnR <= True;
			stateR <= ARRAY_PROFILE;
			for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
				for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
					phase1AccumR[p][i] <= 0;
				end
				globalMassValidR[p] <= False;
				globalExponentR[p] <= 0;
				globalMassR[p] <= 0;
				scoreAccumR[p] <= 0;
			end
		endaction
	endfunction

	function Vector#(NumPipeline, PipelineResult) makeCurrentResult(
					Vector#(NumPipeline, Bit#(11)) offset);
		Vector#(NumPipeline, PipelineResult) value = newVector;
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			value[p] = PipelineResult{
				newOffset: offset[p],
				bestScore: bestScoreR[p],
				updateNum: updateNumR[p],
				bestUpdate: False,
				terminated: terminatedR[p]
				};
		end
		return value;
	endfunction

	//------------------------------------------------------------------------------------
	// Remove the incoming tentative motif and update only changed LPM entries
	//------------------------------------------------------------------------------------
	rule updateRead1 ( stateR == ARRAY_UPDATE_READ );
		Bit#(8) groupStart = zeroExtend(updateGroupAddressR) << 2;
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			bpmMemory[p].readGroup(updateGroupAddressR);
			lpmMemory[p].readGroup(updateGroupAddressR);
			previousMotifMemory[p].readGroup(updateGroupAddressR);
			sequenceMemory[p].readWindow(tentativeOffsetR[p] + zeroExtend(groupStart));
		end
		stateR <= ARRAY_UPDATE_APPLY;
	endrule

	rule updateApply1 ( stateR == ARRAY_UPDATE_APPLY );
		Bit#(8) groupStart = zeroExtend(updateGroupAddressR) << 2;
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			BpmGroup updatedBpm = bpmMemory[p].readResponse;
			let sequenceResponse <- sequenceMemory[p].getWindow;
			MotifSymbolGroup previousValue = previousMotifMemory[p].readResponse;
			PwlArrayRequest logRequest = PwlArrayRequest{
				mode: PWL_LOG2,
				value: replicate(0),
				validMask: 0
				};

			for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
				Bit#(8) column = groupStart + fromInteger(i);
				Bool validColumn = column < configR.motifLength;
				Symbol currentSymbol = sequenceResponse[i];
				Symbol previousSymbol = previousValue[i];
				Bool changed = validColumn && !terminatedR[p] &&
					       previousSymbol != currentSymbol;
				changedValidR[p][i] <= changed;
				changedPreviousSymbolR[p][i] <= previousSymbol;
				changedCurrentSymbolR[p][i] <= currentSymbol;

				if ( validColumn && !terminatedR[p] ) begin
					BpmCount currentCountBefore = getBpmEntry(updatedBpm[i],
										 currentSymbol);
					BpmCount currentCount = currentCountBefore - 1;
					updatedBpm[i] = setBpmEntry(updatedBpm[i],
								    currentSymbol,
								    currentCount);
					if ( changed ) begin
						BpmCount previousCount = getBpmEntry(updatedBpm[i],
										 previousSymbol);
						logRequest.value[2 * i] = zeroExtend(previousCount);
						logRequest.value[2 * i + 1] = zeroExtend(currentCount);
						logRequest.validMask[2 * i] = 1;
						logRequest.validMask[2 * i + 1] = 1;
					end
				end
			end

			if ( !terminatedR[p] ) begin
				bpmMemory[p].writeGroup(updateGroupAddressR, updatedBpm);
			end
			pwlArray[p].put(logRequest);
		end
		stateR <= ARRAY_UPDATE_LOG_WAIT;
	endrule

	rule updateLogWait1 ( stateR == ARRAY_UPDATE_LOG_WAIT );
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			let logResponse <- pwlArray[p].get;
			LpmGroup updatedLpm = lpmMemory[p].readResponse;
			Bool writeRequired = False;
			for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
				if ( changedValidR[p][i] ) begin
					updatedLpm[i] = setLpmEntry(updatedLpm[i],
								 changedPreviousSymbolR[p][i],
								 truncate(logResponse.value[2 * i]));
					updatedLpm[i] = setLpmEntry(updatedLpm[i],
								 changedCurrentSymbolR[p][i],
								 truncate(logResponse.value[2 * i + 1]));
					writeRequired = True;
				end
			end
			if ( writeRequired ) begin
				lpmMemory[p].writeGroup(updateGroupAddressR, updatedLpm);
			end
		end

		Bit#(6) nextGroup = zeroExtend(updateGroupAddressR) + 1;
		Bit#(9) nextColumn = zeroExtend(nextGroup) << 2;
		if ( nextColumn >= zeroExtend(configR.motifLength) ) begin
			beginProfiler;
		end else begin
			updateGroupAddressR <= truncate(nextGroup);
			stateR <= ARRAY_UPDATE_READ;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Profiler Phase 1: one LPM group and one 16-symbol window per cycle
	//------------------------------------------------------------------------------------
	rule profilerPhase1Request1 ( stateR == ARRAY_PROFILE && phase1RequestOnR );
		Bit#(ProfilerValidWidth) validNum = calculateValidNum(candidateNumR,
									phase1SegmentStartR);
		Bool finalColumn = (phase1ColumnR + 1) >= configR.motifLength;
		Bit#(12) nextStart = zeroExtend(phase1SegmentStartR) +
					 fromInteger(valueOf(NumPE_Profiler));
		Bool finalSegment = nextStart >= zeroExtend(candidateNumR);
		Bit#(5) groupAddress = truncate(phase1ColumnR >> 2);

		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			lpmMemory[p].readGroup(groupAddress);
			sequenceMemory[p].readWindow(phase1SegmentStartR +
							 zeroExtend(phase1ColumnR));
		end
		phase1MetaQ.enq(ProfilerMeta{
			segmentStart: phase1SegmentStartR,
			columnOffset: truncate(phase1ColumnR),
			validNum: validNum,
			finalColumn: finalColumn,
			finalSegment: finalSegment
			});

		if ( finalColumn ) begin
			if ( finalSegment ) begin
				phase1RequestOnR <= False;
			end else begin
				phase1SegmentStartR <= truncate(nextStart);
				phase1ColumnR <= 0;
			end
		end else begin
			phase1ColumnR <= phase1ColumnR + 1;
		end
	endrule

	rule profilerPhase1Response1 ( stateR == ARRAY_PROFILE );
		ProfilerMeta meta = phase1MetaQ.first;
		phase1MetaQ.deq;
		Phase2Meta phase2Meta = Phase2Meta{
			segmentStart: meta.segmentStart,
			validNum: meta.validNum,
			finalSegment: meta.finalSegment,
			exponent: replicate(0)
			};

		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			LpmGroup lpmGroup = lpmMemory[p].readResponse;
			let sequenceValue <- sequenceMemory[p].getWindow;
			LpmEntries lpmValue = lpmGroup[meta.columnOffset];
			Vector#(NumPE_Profiler, LogProb) completedLogProb = newVector;
			for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
				LogProb nextValue = phase1AccumR[p][i];
				if ( fromInteger(i) < meta.validNum && !terminatedR[p] ) begin
					LogValue lpmEntry = getLpmEntry(lpmValue, sequenceValue[i]);
					nextValue = phase1AccumR[p][i] + zeroExtend(lpmEntry);
				end
				completedLogProb[i] = nextValue;
				if ( meta.finalColumn ) phase1AccumR[p][i] <= 0;
				else phase1AccumR[p][i] <= nextValue;
			end

			if ( meta.finalColumn ) begin
				LogProb maximum = maxLogProbSegment(completedLogProb, meta.validNum);
				UInt#(12) exponent = truncate((maximum + 4095) >> 12);
				LogProb exponentQ12 = zeroExtend(exponent) << 12;
				PwlArrayRequest expRequest = PwlArrayRequest{
					mode: PWL_EXP2,
					value: replicate(0),
					validMask: 0
					};
				for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
					if ( fromInteger(i) < meta.validNum && !terminatedR[p] ) begin
						expRequest.value[i] = exponentQ12 - completedLogProb[i];
						expRequest.validMask[i] = 1;
					end
				end
				pwlArray[p].put(expRequest);
				phase2Meta.exponent[p] = exponent;
			end
		end

		if ( meta.finalColumn ) phase2MetaQ.enq(phase2Meta);
	endrule

	//------------------------------------------------------------------------------------
	// Profiler Phase 2: local PPS sampling and streaming segment reservoir
	//------------------------------------------------------------------------------------
	rule profilerPhase2Weight1 ( stateR == ARRAY_PROFILE );
		Phase2Meta meta = phase2MetaQ.first;
		phase2MetaQ.deq;
		ReservoirCandidate candidate = ReservoirCandidate{
			segmentStart: meta.segmentStart,
			finalSegment: meta.finalSegment,
			exponent: meta.exponent,
			mass: replicate(0),
			localOffset: replicate(0),
			reservoirRandom: replicate(0)
			};

		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			let response <- pwlArray[p].get;
			WeightTree tree = buildWeightTree(response.value);
			if ( !terminatedR[p] ) begin
				Tuple2#(Bit#(32), RandomState) localResult =
					nextRandom(randomStateR[p]);
				Tuple2#(Bit#(32), RandomState) reservoirResult =
					nextRandom(tpl_2(localResult));
				Bit#(32) localRandomWord = tpl_1(localResult);
				Bit#(32) reservoirRandomWord = tpl_1(reservoirResult);
				candidate.localOffset[p] = selectLocalCandidate(
					response.value,
					tree,
					localRandomWord[31:8],
					meta.validNum
				);
				candidate.reservoirRandom[p] = reservoirRandomWord[31:8];
				randomStateR[p] <= tpl_2(reservoirResult);
			end
			candidate.mass[p] = tree.total;
		end
		reservoirCandidateQ.enq(candidate);
	endrule

	rule profilerPhase2Commit1 ( stateR == ARRAY_PROFILE );
		ReservoirCandidate candidate = reservoirCandidateQ.first;
		reservoirCandidateQ.deq;
		ReservoirMultiplyRequest multiplyRequest = ReservoirMultiplyRequest{
			finalSegment: candidate.finalSegment,
			valid: replicate(False),
			replaceFirst: replicate(False),
			nextMass: replicate(0),
			alignedSegmentMass: replicate(0),
			randomFraction: candidate.reservoirRandom,
			replacementOffset: replicate(0)
			};

		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			if ( !terminatedR[p] ) begin
				GlobalMass segmentMass = zeroExtend(candidate.mass[p]) << 6;
				GlobalMass oldMass = 0;
				GlobalMass alignedSegmentMass = segmentMass;
				UInt#(12) nextExponent = candidate.exponent[p];
				if ( globalMassValidR[p] ) begin
					if ( candidate.exponent[p] <= globalExponentR[p] ) begin
						UInt#(12) difference = globalExponentR[p] -
								       candidate.exponent[p];
						oldMass = globalMassR[p];
						alignedSegmentMass = boundedGlobalShift(segmentMass,
										     difference);
						nextExponent = globalExponentR[p];
					end else begin
						UInt#(12) difference = candidate.exponent[p] -
								       globalExponentR[p];
						oldMass = boundedGlobalShift(globalMassR[p], difference);
					end
				end
				GlobalMass nextMass = oldMass + alignedSegmentMass;
				multiplyRequest.valid[p] = True;
				multiplyRequest.replaceFirst[p] = !globalMassValidR[p];
				multiplyRequest.nextMass[p] = nextMass;
				multiplyRequest.alignedSegmentMass[p] = alignedSegmentMass;
				multiplyRequest.replacementOffset[p] = candidate.segmentStart +
									      zeroExtend(candidate.localOffset[p]);
				globalMassValidR[p] <= True;
				globalExponentR[p] <= nextExponent;
				globalMassR[p] <= nextMass;
			end
		end
		reservoirMultiplyRequestQ.enq(multiplyRequest);
	endrule

	rule profilerReservoirMultiply1 ( stateR == ARRAY_PROFILE );
		ReservoirMultiplyRequest request = reservoirMultiplyRequestQ.first;
		reservoirMultiplyRequestQ.deq;
		ReservoirMultiplyResponse response = ReservoirMultiplyResponse{
			finalSegment: request.finalSegment,
			valid: request.valid,
			replaceFirst: request.replaceFirst,
			randomProduct: replicate(0),
			segmentRange: replicate(0),
			replacementOffset: request.replacementOffset
			};
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			if ( request.valid[p] ) begin
				response.randomProduct[p] = zeroExtend(request.nextMass[p]) *
							    zeroExtend(unpack(request.randomFraction[p]));
				response.segmentRange[p] = zeroExtend(request.alignedSegmentMass[p]) << 24;
			end
		end
		reservoirMultiplyResponseQ.enq(response);
	endrule

	rule profilerReservoirSelect1 ( stateR == ARRAY_PROFILE );
		ReservoirMultiplyResponse response = reservoirMultiplyResponseQ.first;
		reservoirMultiplyResponseQ.deq;
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			Bool replace = response.replaceFirst[p] ||
				       (response.valid[p] &&
					response.segmentRange[p] != 0 &&
					response.randomProduct[p] < response.segmentRange[p]);
			if ( replace ) selectedOffsetR[p] <= response.replacementOffset[p];
		end

		if ( response.finalSegment ) begin
			insertGroupAddressR <= 0;
			insertRequestOnR <= True;
			stateR <= ARRAY_INSERT;
			for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
				scoreAccumR[p] <= 0;
			end
		end
	endrule

	//------------------------------------------------------------------------------------
	// Insert four columns per cycle and calculate the complete-state score in one pass
	//------------------------------------------------------------------------------------
	rule insertRequest1 ( stateR == ARRAY_INSERT && insertRequestOnR );
		Bit#(8) groupStart = zeroExtend(insertGroupAddressR) << 2;
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			bpmMemory[p].readGroup(insertGroupAddressR);
			sequenceMemory[p].readWindow(selectedOffsetR[p] + zeroExtend(groupStart));
		end
		insertGroupAddressQ.enq(insertGroupAddressR);
		Bit#(6) nextGroup = zeroExtend(insertGroupAddressR) + 1;
		Bit#(9) nextColumn = zeroExtend(nextGroup) << 2;
		if ( nextColumn >= zeroExtend(configR.motifLength) ) begin
			insertRequestOnR <= False;
		end else begin
			insertGroupAddressR <= truncate(nextGroup);
		end
	endrule

	rule insertResponse1 ( stateR == ARRAY_INSERT );
		Bit#(5) groupAddress = insertGroupAddressQ.first;
		insertGroupAddressQ.deq;
		Bit#(8) groupStart = zeroExtend(groupAddress) << 2;
		Bit#(9) groupEnd = zeroExtend(groupStart) + 4;
		Bool finalGroup = groupEnd >= zeroExtend(configR.motifLength);
		PipelineResult emptyResult = PipelineResult{
			newOffset: 0,
			bestScore: 0,
			updateNum: 0,
			bestUpdate: False,
			terminated: False
			};
		Vector#(NumPipeline, PipelineResult) resultValue = replicate(emptyResult);

		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			BpmGroup updatedBpm = bpmMemory[p].readResponse;
			let sequenceResponse <- sequenceMemory[p].getWindow;
			MotifSymbolGroup newMotif = replicate(0);
			ScoreValue nextScore = scoreAccumR[p];

			if ( !terminatedR[p] ) begin
				for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
					Bit#(8) column = groupStart + fromInteger(i);
					if ( column < configR.motifLength ) begin
						Symbol symbol = sequenceResponse[i];
						BpmCount count = getBpmEntry(updatedBpm[i], symbol);
						updatedBpm[i] = setBpmEntry(updatedBpm[i],
									    symbol,
									    count + 1);
						newMotif[i] = symbol;
						nextScore = nextScore + maxBpmEntry(updatedBpm[i],
										     configR.alphabetSize);
					end
				end
				bpmMemory[p].writeGroup(groupAddress, updatedBpm);
				previousMotifMemory[p].writeGroup(groupAddress, newMotif);
			end

			if ( finalGroup ) begin
				if ( !terminatedR[p] ) begin
					UInt#(32) nextUpdateNum = updateNumR[p] + 1;
					Bool bestUpdate = nextScore > bestScoreR[p];
					ScoreValue nextBestScore = bestUpdate ? nextScore : bestScoreR[p];
					Bool nextTerminated = nextBestScore >= configR.scoreThreshold ||
							      nextUpdateNum >= configR.maxUpdates;
					bestScoreR[p] <= nextBestScore;
					updateNumR[p] <= nextUpdateNum;
					terminatedR[p] <= nextTerminated;
					resultValue[p] = PipelineResult{
						newOffset: selectedOffsetR[p],
						bestScore: nextBestScore,
						updateNum: nextUpdateNum,
						bestUpdate: bestUpdate,
						terminated: nextTerminated
						};
				end else begin
					resultValue[p] = PipelineResult{
						newOffset: selectedOffsetR[p],
						bestScore: bestScoreR[p],
						updateNum: updateNumR[p],
						bestUpdate: False,
						terminated: True
						};
				end
			end else if ( !terminatedR[p] ) begin
				scoreAccumR[p] <= nextScore;
			end
		end

		if ( finalGroup ) begin
			stateR <= ARRAY_IDLE;
			resultQ.enq(resultValue);
		end
	endrule

	//------------------------------------------------------------------------------------
	// Interface
	//------------------------------------------------------------------------------------
	method Action configure(PipelineConfig pipelineConfig)
		if ( !configuredR && !executionStartedR && stateR == ARRAY_IDLE );
		configR <= pipelineConfig;
		configuredR <= True;
	endmethod

	method Action configurePipeline(Bit#(PipelineIndexWidth) pipelineIdx,
					Bit#(128) randomSeed,
					ScoreValue initialBestScore)
		if ( configuredR && !executionStartedR && stateR == ARRAY_IDLE );
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			if ( fromInteger(p) == pipelineIdx ) begin
				randomStateR[p] <= initializeRandomState(randomSeed);
				bestScoreR[p] <= initialBestScore;
				updateNumR[p] <= 0;
				terminatedR[p] <= initialBestScore >= configR.scoreThreshold;
				tentativeOffsetR[p] <= 0;
				selectedOffsetR[p] <= 0;
			end
		end
	endmethod

	method Action loadSequenceBeat(Bit#(4) beatIdx, Bit#(512) word)
		if ( stateR == ARRAY_IDLE );
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			sequenceMemory[p].loadBeat(beatIdx, word);
		end
	endmethod

	method Action loadBpmGroup(Bit#(PipelineIndexWidth) pipelineIdx,
				  Bit#(5) address,
				  BpmGroup value)
		if ( !executionStartedR && stateR == ARRAY_IDLE );
		case ( pipelineIdx )
			0: bpmMemory[0].loadGroup(address, value);
			1: bpmMemory[1].loadGroup(address, value);
			2: bpmMemory[2].loadGroup(address, value);
			3: bpmMemory[3].loadGroup(address, value);
			4: bpmMemory[4].loadGroup(address, value);
			5: bpmMemory[5].loadGroup(address, value);
			6: bpmMemory[6].loadGroup(address, value);
			7: bpmMemory[7].loadGroup(address, value);
			8: bpmMemory[8].loadGroup(address, value);
			9: bpmMemory[9].loadGroup(address, value);
			10: bpmMemory[10].loadGroup(address, value);
			11: bpmMemory[11].loadGroup(address, value);
			12: bpmMemory[12].loadGroup(address, value);
			13: bpmMemory[13].loadGroup(address, value);
			14: bpmMemory[14].loadGroup(address, value);
			default: bpmMemory[15].loadGroup(address, value);
		endcase
	endmethod

	method Action loadLpmGroup(Bit#(PipelineIndexWidth) pipelineIdx,
				  Bit#(5) address,
				  LpmGroup value)
		if ( !executionStartedR && stateR == ARRAY_IDLE );
		case ( pipelineIdx )
			0: lpmMemory[0].loadGroup(address, value);
			1: lpmMemory[1].loadGroup(address, value);
			2: lpmMemory[2].loadGroup(address, value);
			3: lpmMemory[3].loadGroup(address, value);
			4: lpmMemory[4].loadGroup(address, value);
			5: lpmMemory[5].loadGroup(address, value);
			6: lpmMemory[6].loadGroup(address, value);
			7: lpmMemory[7].loadGroup(address, value);
			8: lpmMemory[8].loadGroup(address, value);
			9: lpmMemory[9].loadGroup(address, value);
			10: lpmMemory[10].loadGroup(address, value);
			11: lpmMemory[11].loadGroup(address, value);
			12: lpmMemory[12].loadGroup(address, value);
			13: lpmMemory[13].loadGroup(address, value);
			14: lpmMemory[14].loadGroup(address, value);
			default: lpmMemory[15].loadGroup(address, value);
		endcase
	endmethod

	method Action startBootstrap
		if ( configuredR && !executionStartedR && stateR == ARRAY_IDLE &&
		     allSequenceLoadIdle );
		executionStartedR <= True;
		Vector#(NumPipeline, Bit#(11)) offset = replicate(0);
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			selectedOffsetR[p] <= 0;
		end
		if ( allPipelineTerminated ) begin
			resultQ.enq(makeCurrentResult(offset));
		end else begin
			beginProfiler;
		end
	endmethod

	method Action startUpdate(Vector#(NumPipeline, Bit#(11)) tentativeOffset)
		if ( configuredR && executionStartedR && stateR == ARRAY_IDLE &&
		     allSequenceLoadIdle );
		for ( Integer p = 0; p < valueOf(NumPipeline); p = p + 1 ) begin
			tentativeOffsetR[p] <= tentativeOffset[p];
			selectedOffsetR[p] <= tentativeOffset[p];
		end
		if ( allPipelineTerminated ) begin
			resultQ.enq(makeCurrentResult(tentativeOffset));
		end else begin
			updateGroupAddressR <= 0;
			stateR <= ARRAY_UPDATE_READ;
		end
	endmethod

	method ActionValue#(Vector#(NumPipeline, PipelineResult)) result;
		Vector#(NumPipeline, PipelineResult) value = resultQ.first;
		resultQ.deq;
		return value;
	endmethod

	method Bool busy;
		return stateR != ARRAY_IDLE;
	endmethod
endmodule

endpackage
