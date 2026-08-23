package GibbsPipeline;

import FIFO::*;
import FIFOF::*;
import RegFile::*;
import Vector::*;

import MorbiusTypes::*;
import PwlLane::*;
import RandomGenerator::*;


typedef enum {
	UPDATE_IDLE,
	UPDATE_BPM,
	UPDATE_PREV_REQUEST,
	UPDATE_PREV_RESPONSE,
	UPDATE_CURRENT_REQUEST,
	UPDATE_CURRENT_RESPONSE
} UpdateState deriving (Bits, Eq, FShow);

typedef enum {
	PHASE2_IDLE,
	PHASE2_WAIT_WEIGHT,
	PHASE2_COMMIT
} Phase2State deriving (Bits, Eq, FShow);

interface GibbsPipelineIfc;
	method Action configure(PipelineConfig pipelineConfig,
				Bit#(128) randomSeed,
				UInt#(32) initialBestScore,
				Bool active);
	method Action loadSequenceBeat(Bit#(4) beatIdx, Bit#(512) word);
	method Action loadBpmColumn(Bit#(8) column, MatrixColumn word);
	method Action loadLpmColumn(Bit#(8) column, MatrixColumn word);
	method Action startBootstrap;
	method Action startUpdate(Bit#(11) tentativeOffset);
	method ActionValue#(PipelineResult) result;
	method UInt#(32) bestScore;
	method Bool terminated;
	method Bool busy;
endinterface

function Bit#(2) getMatrixBank(Bit#(8) column);
	return truncate(column);
endfunction

function Bit#(5) getMatrixAddress(Bit#(8) column);
	return truncate(column >> 2);
endfunction

function Bit#(4) calculateValidNum(Bit#(11) candidateNum, Bit#(11) startOffset);
	Bit#(11) remaining = candidateNum - startOffset;
	if ( remaining >= fromInteger(valueOf(NumPE_Profiler)) ) return fromInteger(valueOf(NumPE_Profiler));
	else return truncate(remaining);
endfunction

function Bit#(3) selectLocalCandidate(Vector#(NumPE_Profiler, PwlValue) weight,
					      SegmentMass totalMass,
					      Bit#(24) randomFraction,
					      Bit#(4) validNum);
	UInt#(46) product = zeroExtend(totalMass) * zeroExtend(unpack(randomFraction));
	SegmentMass threshold = truncate(product >> 24);
	UInt#(22) left4 = zeroExtend(weight[0]) + zeroExtend(weight[1]) +
			zeroExtend(weight[2]) + zeroExtend(weight[3]);
	Bit#(3) base4 = 0;
	SegmentMass threshold4 = threshold;
	if ( threshold >= left4 ) begin
		base4 = 4;
		threshold4 = threshold - left4;
	end

	UInt#(22) left2 = 0;
	if ( base4 == 0 ) left2 = zeroExtend(weight[0]) + zeroExtend(weight[1]);
	else left2 = zeroExtend(weight[4]) + zeroExtend(weight[5]);
	Bit#(3) base2 = base4;
	SegmentMass threshold2 = threshold4;
	if ( threshold4 >= left2 ) begin
		base2 = base4 + 2;
		threshold2 = threshold4 - left2;
	end

	PwlValue left1 = weight[base2];
	Bit#(3) selected = base2;
	if ( threshold2 >= zeroExtend(left1) ) selected = base2 + 1;
	if ( zeroExtend(selected) >= validNum ) selected = truncate(validNum - 1);
	return selected;
endfunction

module mkGibbsPipeline(GibbsPipelineIfc);
	//------------------------------------------------------------------------------------
	// Persistent configuration and pipeline state
	//------------------------------------------------------------------------------------
	Reg#(PipelineConfig) configR <- mkRegU;
	Reg#(Bool) configuredR <- mkReg(False);
	Reg#(Bool) executionStartedR <- mkReg(False);
	Reg#(Bool) activeR <- mkReg(False);
	Reg#(Bool) terminatedR <- mkReg(False);
	Reg#(Bool) busyR <- mkReg(False);
	Reg#(UInt#(32)) bestScoreR <- mkReg(0);
	Reg#(UInt#(32)) updateNumR <- mkReg(0);

	Vector#(SequenceBeatNum, Reg#(Bit#(512))) sequenceWords <- replicateM(mkReg(0));
	Vector#(MotifLengthMax, Reg#(Bit#(5))) previousTentativeMotif <- replicateM(mkReg(0));

	Vector#(NumPE_LPM, RegFile#(Bit#(5), MatrixColumn)) bpmBanks <- replicateM(mkRegFileFull);
	Vector#(NumPE_LPM, RegFile#(Bit#(5), MatrixColumn)) lpmBanks <- replicateM(mkRegFileFull);

	Vector#(NumPE_Profiler, PwlLaneIfc) pwlLanes <- replicateM(mkPwlLane);
	RandomGeneratorIfc randomGenerator <- mkRandomGenerator;
	FIFOF#(PipelineResult) resultQ <- mkFIFOF;

	//------------------------------------------------------------------------------------
	// Selective BPM and LPM update
	//------------------------------------------------------------------------------------
	Reg#(UpdateState) updateStateR <- mkReg(UPDATE_IDLE);
	Reg#(Bit#(8)) updateBatchStartR <- mkReg(0);
	Reg#(Bit#(11)) tentativeOffsetR <- mkReg(0);
	Vector#(NumPE_LPM, Reg#(Bool)) changedValidR <- replicateM(mkReg(False));
	Vector#(NumPE_LPM, Reg#(Bit#(5))) changedPreviousSymbolR <- replicateM(mkReg(0));
	Vector#(NumPE_LPM, Reg#(Bit#(5))) changedCurrentSymbolR <- replicateM(mkReg(0));
	Vector#(NumPE_LPM, Reg#(BpmCount)) changedPreviousCountR <- replicateM(mkReg(1));
	Vector#(NumPE_LPM, Reg#(BpmCount)) changedCurrentCountR <- replicateM(mkReg(1));

	//------------------------------------------------------------------------------------
	// Profiler Phase 1
	//------------------------------------------------------------------------------------
	Reg#(Bool) phase1On <- mkReg(False);
	Reg#(Bool) phase1Done <- mkReg(False);
	Reg#(Bit#(11)) candidateNumR <- mkReg(0);
	Reg#(Bit#(8)) expectedSegmentNumR <- mkReg(0);
	Reg#(Bit#(11)) phase1SegmentStartR <- mkReg(0);
	Reg#(Bit#(8)) phase1ColumnR <- mkReg(0);
	Vector#(NumPE_Profiler, Reg#(LogProb)) phase1AccumR <- replicateM(mkReg(0));
	FIFOF#(LogProbSegment) logProbSegmentQ <- mkSizedFIFOF(8);

	//------------------------------------------------------------------------------------
	// Profiler Phase 2
	//------------------------------------------------------------------------------------
	Reg#(Phase2State) phase2StateR <- mkReg(PHASE2_IDLE);
	Reg#(LogProbSegment) phase2SegmentR <- mkRegU;
	Reg#(UInt#(16)) phase2ExponentR <- mkReg(0);
	Reg#(SegmentSummary) phase2SummaryR <- mkRegU;
	RegFile#(Bit#(7), SegmentSummary) segmentSummaryMem <- mkRegFileFull;
	Reg#(Bit#(8)) segmentSummaryNumR <- mkReg(0);
	Reg#(Bool) globalMassValidR <- mkReg(False);
	Reg#(UInt#(16)) globalExponentR <- mkReg(0);
	Reg#(GlobalMass) globalMassR <- mkReg(0);

	//------------------------------------------------------------------------------------
	// Segment selection, motif insertion, and score calculation
	//------------------------------------------------------------------------------------
	Reg#(Bool) selectorOn <- mkReg(False);
	Reg#(Bit#(8)) selectorIdxR <- mkReg(0);
	Reg#(GlobalMass) selectorThresholdR <- mkReg(0);
	Reg#(GlobalMass) selectorCumulativeR <- mkReg(0);
	Reg#(Bit#(11)) selectedOffsetR <- mkReg(0);

	Reg#(Bool) insertOn <- mkReg(False);
	Reg#(Bit#(8)) insertColumnR <- mkReg(0);
	Reg#(Bool) scoreOn <- mkReg(False);
	Reg#(Bit#(8)) scoreColumnR <- mkReg(0);
	Reg#(UInt#(32)) scoreAccumR <- mkReg(0);

	function MatrixColumn readBpmColumn(Bit#(8) column);
		Bit#(5) address = getMatrixAddress(column);
		case ( getMatrixBank(column) )
			0: return bpmBanks[0].sub(address);
			1: return bpmBanks[1].sub(address);
			2: return bpmBanks[2].sub(address);
			default: return bpmBanks[3].sub(address);
		endcase
	endfunction

	function MatrixColumn readLpmColumn(Bit#(8) column);
		Bit#(5) address = getMatrixAddress(column);
		case ( getMatrixBank(column) )
			0: return lpmBanks[0].sub(address);
			1: return lpmBanks[1].sub(address);
			2: return lpmBanks[2].sub(address);
			default: return lpmBanks[3].sub(address);
		endcase
	endfunction

	function Action writeBpmColumn(Bit#(8) column, MatrixColumn word);
		action
			Bit#(5) address = getMatrixAddress(column);
			case ( getMatrixBank(column) )
				0: bpmBanks[0].upd(address, word);
				1: bpmBanks[1].upd(address, word);
				2: bpmBanks[2].upd(address, word);
				default: bpmBanks[3].upd(address, word);
			endcase
		endaction
	endfunction

	function Action writeLpmColumn(Bit#(8) column, MatrixColumn word);
		action
			Bit#(5) address = getMatrixAddress(column);
			case ( getMatrixBank(column) )
				0: lpmBanks[0].upd(address, word);
				1: lpmBanks[1].upd(address, word);
				2: lpmBanks[2].upd(address, word);
				default: lpmBanks[3].upd(address, word);
			endcase
		endaction
	endfunction

	function Action beginProfiler;
		action
			Bit#(11) candidateNum = configR.sequenceLength - zeroExtend(configR.motifLength) + 1;
			Bit#(12) segmentNumerator = zeroExtend(candidateNum) + fromInteger(valueOf(NumPE_Profiler) - 1);
			Bit#(8) segmentNum = truncate(segmentNumerator >> 3);
			candidateNumR <= candidateNum;
			expectedSegmentNumR <= segmentNum;
			phase1SegmentStartR <= 0;
			phase1ColumnR <= 0;
			phase1Done <= False;
			phase1On <= True;
			for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
				phase1AccumR[i] <= 0;
			end
			phase2StateR <= PHASE2_IDLE;
			segmentSummaryNumR <= 0;
			globalMassValidR <= False;
			globalExponentR <= 0;
			globalMassR <= 0;
			selectorOn <= False;
			insertOn <= False;
			scoreOn <= False;
		endaction
	endfunction

	//------------------------------------------------------------------------------------
	// Remove the current tentative motif and generate column masking bits
	//------------------------------------------------------------------------------------
	rule updateBpm1 ( executionStartedR && busyR && updateStateR == UPDATE_BPM );
		Vector#(SequenceBeatNum, Bit#(512)) sequenceValue = readVReg(sequenceWords);
		Bit#(5) bankAddress = getMatrixAddress(updateBatchStartR);

		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			Bit#(8) column = updateBatchStartR + fromInteger(i);
			Bool changed = False;
			Bit#(5) previousSymbol = 0;
			Bit#(5) currentSymbol = 0;
			BpmCount previousCount = 1;
			BpmCount currentCount = 1;
			if ( column < configR.motifLength ) begin
				MatrixColumn bpmWord = bpmBanks[i].sub(bankAddress);
				Bit#(11) sequencePosition = tentativeOffsetR + zeroExtend(column);
				currentSymbol = getSequenceSymbol(sequenceValue, sequencePosition);
				previousSymbol = previousTentativeMotif[column];
				BpmCount currentCountBefore = getMatrixEntry(bpmWord, currentSymbol);
				currentCount = currentCountBefore - 1;
				MatrixColumn updatedWord = setMatrixEntry(bpmWord,
								      currentSymbol,
								      currentCount);
				bpmBanks[i].upd(bankAddress, updatedWord);
				changed = previousSymbol != currentSymbol;
				previousCount = getMatrixEntry(updatedWord, previousSymbol);
			end
			changedValidR[i] <= changed;
			changedPreviousSymbolR[i] <= previousSymbol;
			changedCurrentSymbolR[i] <= currentSymbol;
			changedPreviousCountR[i] <= previousCount;
			changedCurrentCountR[i] <= currentCount;
		end
		updateStateR <= UPDATE_PREV_REQUEST;
	endrule

	rule updateLpmPreviousRequest1 ( executionStartedR && busyR && updateStateR == UPDATE_PREV_REQUEST );
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			UInt#(32) count = 1;
			if ( changedValidR[i] ) count = zeroExtend(changedPreviousCountR[i]);
			pwlLanes[i].put(PwlRequest{
				mode: PWL_LOG2,
				value: count,
				tag: fromInteger(i)
				});
		end
		updateStateR <= UPDATE_PREV_RESPONSE;
	endrule

	rule updateLpmPreviousResponse1 ( executionStartedR && busyR && updateStateR == UPDATE_PREV_RESPONSE );
		Vector#(NumPE_LPM, PwlResponse) response = newVector;
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			let value <- pwlLanes[i].get;
			response[i] = value;
		end
		Bit#(5) bankAddress = getMatrixAddress(updateBatchStartR);
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			if ( changedValidR[i] ) begin
				MatrixColumn lpmWord = lpmBanks[i].sub(bankAddress);
				MatrixColumn updatedWord = setMatrixEntry(lpmWord,
								      changedPreviousSymbolR[i],
								      truncate(response[i].value));
				lpmBanks[i].upd(bankAddress, updatedWord);
			end
		end
		updateStateR <= UPDATE_CURRENT_REQUEST;
	endrule

	rule updateLpmCurrentRequest1 ( executionStartedR && busyR && updateStateR == UPDATE_CURRENT_REQUEST );
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			UInt#(32) count = 1;
			if ( changedValidR[i] ) count = zeroExtend(changedCurrentCountR[i]);
			pwlLanes[i].put(PwlRequest{
				mode: PWL_LOG2,
				value: count,
				tag: fromInteger(i)
				});
		end
		updateStateR <= UPDATE_CURRENT_RESPONSE;
	endrule

	rule updateLpmCurrentResponse1 ( executionStartedR && busyR && updateStateR == UPDATE_CURRENT_RESPONSE );
		Vector#(NumPE_LPM, PwlResponse) response = newVector;
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			let value <- pwlLanes[i].get;
			response[i] = value;
		end
		Bit#(5) bankAddress = getMatrixAddress(updateBatchStartR);
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			if ( changedValidR[i] ) begin
				MatrixColumn lpmWord = lpmBanks[i].sub(bankAddress);
				MatrixColumn updatedWord = setMatrixEntry(lpmWord,
								      changedCurrentSymbolR[i],
								      truncate(response[i].value));
				lpmBanks[i].upd(bankAddress, updatedWord);
			end
		end

		Bit#(9) nextBatch = zeroExtend(updateBatchStartR) + fromInteger(valueOf(NumPE_LPM));
		if ( nextBatch >= zeroExtend(configR.motifLength) ) begin
			updateStateR <= UPDATE_IDLE;
			beginProfiler;
		end else begin
			updateBatchStartR <= truncate(nextBatch);
			updateStateR <= UPDATE_BPM;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Profiler Phase 1: generate NumPE_Profiler LogProb values per segment
	//------------------------------------------------------------------------------------
	rule profilerPhase1 ( executionStartedR && busyR && updateStateR == UPDATE_IDLE && phase1On );
		Vector#(SequenceBeatNum, Bit#(512)) sequenceValue = readVReg(sequenceWords);
		MatrixColumn lpmWord = readLpmColumn(phase1ColumnR);
		Vector#(NumPE_Profiler, LogProb) completedLogProb = newVector;
		Bit#(4) validNum = calculateValidNum(candidateNumR, phase1SegmentStartR);
		Bool finalColumn = (phase1ColumnR + 1) >= configR.motifLength;

		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			LogProb nextValue = phase1AccumR[i];
			if ( fromInteger(i) < validNum ) begin
				Bit#(11) sequencePosition = phase1SegmentStartR +
							  fromInteger(i) +
							  zeroExtend(phase1ColumnR);
				Bit#(5) symbol = getSequenceSymbol(sequenceValue, sequencePosition);
				UInt#(18) lpmEntry = getMatrixEntry(lpmWord, symbol);
				nextValue = phase1AccumR[i] + zeroExtend(lpmEntry);
			end
			completedLogProb[i] = nextValue;
			if ( finalColumn ) phase1AccumR[i] <= 0;
			else phase1AccumR[i] <= nextValue;
		end

		if ( finalColumn ) begin
			logProbSegmentQ.enq(LogProbSegment{
				logProb: completedLogProb,
				startOffset: phase1SegmentStartR,
				validNum: validNum
				});
			Bit#(12) nextStart = zeroExtend(phase1SegmentStartR) + fromInteger(valueOf(NumPE_Profiler));
			if ( nextStart >= zeroExtend(candidateNumR) ) begin
				phase1On <= False;
				phase1Done <= True;
			end else begin
				phase1SegmentStartR <= truncate(nextStart);
				phase1ColumnR <= 0;
			end
		end else begin
			phase1ColumnR <= phase1ColumnR + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Profiler Phase 2: WeightProducer and SegmentSampler
	//------------------------------------------------------------------------------------
	rule profilerPhase2Issue1 ( executionStartedR && busyR && updateStateR == UPDATE_IDLE && phase2StateR == PHASE2_IDLE );
		LogProbSegment segment = logProbSegmentQ.first;
		logProbSegmentQ.deq;
		LogProb maximum = 0;
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			if ( fromInteger(i) < segment.validNum && segment.logProb[i] > maximum ) begin
				maximum = segment.logProb[i];
			end
		end
		UInt#(16) exponent = truncate((maximum + 4095) >> 12);
		UInt#(32) exponentQ12 = zeroExtend(exponent) << 12;
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			UInt#(32) difference = 32'h7fffffff;
			if ( fromInteger(i) < segment.validNum ) difference = exponentQ12 - segment.logProb[i];
			pwlLanes[i].put(PwlRequest{
				mode: PWL_EXP2,
				value: difference,
				tag: fromInteger(i)
				});
		end
		phase2SegmentR <= segment;
		phase2ExponentR <= exponent;
		phase2StateR <= PHASE2_WAIT_WEIGHT;
	endrule

	rule profilerPhase2Weight1 ( executionStartedR && busyR && updateStateR == UPDATE_IDLE && phase2StateR == PHASE2_WAIT_WEIGHT );
		Vector#(NumPE_Profiler, PwlValue) weight = newVector;
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			let response <- pwlLanes[i].get;
			weight[i] = response.value;
		end
		let randomWord <- randomGenerator.get;
		SegmentMass segmentMass = 0;
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			segmentMass = segmentMass + zeroExtend(weight[i]);
		end
		Bit#(3) localOffset = selectLocalCandidate(weight,
							    segmentMass,
							    randomWord[31:8],
							    phase2SegmentR.validNum);
		phase2SummaryR <= SegmentSummary{
			startOffset: phase2SegmentR.startOffset,
			exponent: phase2ExponentR,
			mass: segmentMass,
			localOffset: localOffset,
			validNum: phase2SegmentR.validNum
			};
		phase2StateR <= PHASE2_COMMIT;
	endrule

	rule profilerPhase2Commit1 ( executionStartedR && busyR && updateStateR == UPDATE_IDLE && phase2StateR == PHASE2_COMMIT );
		Bit#(7) summaryAddress = truncate(segmentSummaryNumR);
		segmentSummaryMem.upd(summaryAddress, phase2SummaryR);
		GlobalMass segmentMassQ24 = zeroExtend(phase2SummaryR.mass) << 6;
		if ( !globalMassValidR ) begin
			globalMassValidR <= True;
			globalExponentR <= phase2SummaryR.exponent;
			globalMassR <= segmentMassQ24;
		end else if ( phase2SummaryR.exponent <= globalExponentR ) begin
			UInt#(16) difference = globalExponentR - phase2SummaryR.exponent;
			globalMassR <= globalMassR + (segmentMassQ24 >> difference);
		end else begin
			UInt#(16) difference = phase2SummaryR.exponent - globalExponentR;
			globalMassR <= (globalMassR >> difference) + segmentMassQ24;
			globalExponentR <= phase2SummaryR.exponent;
		end
		segmentSummaryNumR <= segmentSummaryNumR + 1;
		phase2StateR <= PHASE2_IDLE;
	endrule

	//------------------------------------------------------------------------------------
	// SegmentSelector: scan one summary per cycle with early exit
	//------------------------------------------------------------------------------------
	rule startSegmentSelector ( executionStartedR && busyR && updateStateR == UPDATE_IDLE && phase1Done &&
					      phase2StateR == PHASE2_IDLE &&
					      segmentSummaryNumR == expectedSegmentNumR &&
					      !phase1On && !selectorOn && !insertOn && !scoreOn );
		let randomWord <- randomGenerator.get;
		UInt#(24) randomFraction = unpack(randomWord[31:8]);
		UInt#(72) product = zeroExtend(globalMassR) * zeroExtend(randomFraction);
		selectorThresholdR <= truncate(product >> 24);
		selectorCumulativeR <= 0;
		selectorIdxR <= 0;
		selectorOn <= True;
		phase1Done <= False;
	endrule

	rule selectSegment1 ( executionStartedR && busyR && updateStateR == UPDATE_IDLE && selectorOn && !insertOn && !scoreOn );
		SegmentSummary summary = segmentSummaryMem.sub(truncate(selectorIdxR));
		GlobalMass alignedMass = zeroExtend(summary.mass) << 6;
		UInt#(16) exponentDifference = globalExponentR - summary.exponent;
		alignedMass = alignedMass >> exponentDifference;
		GlobalMass nextCumulative = selectorCumulativeR + alignedMass;
		Bool finalSummary = (selectorIdxR + 1) >= expectedSegmentNumR;
		if ( nextCumulative > selectorThresholdR || finalSummary ) begin
			selectedOffsetR <= summary.startOffset + zeroExtend(summary.localOffset);
			selectorOn <= False;
			insertColumnR <= 0;
			insertOn <= True;
		end else begin
			selectorCumulativeR <= nextCumulative;
			selectorIdxR <= selectorIdxR + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// TentativeMotifExtractor and BPM insertion
	//------------------------------------------------------------------------------------
	rule insertNewMotif1 ( executionStartedR && busyR && updateStateR == UPDATE_IDLE && insertOn && !selectorOn && !scoreOn );
		Vector#(SequenceBeatNum, Bit#(512)) sequenceValue = readVReg(sequenceWords);
		Bit#(5) symbol = getSequenceSymbol(sequenceValue,
						selectedOffsetR + zeroExtend(insertColumnR));
		MatrixColumn bpmWord = readBpmColumn(insertColumnR);
		BpmCount count = getMatrixEntry(bpmWord, symbol);
		MatrixColumn updatedWord = setMatrixEntry(bpmWord, symbol, count + 1);
		writeBpmColumn(insertColumnR, updatedWord);
		previousTentativeMotif[insertColumnR] <= symbol;
		if ( (insertColumnR + 1) >= configR.motifLength ) begin
			insertOn <= False;
			scoreColumnR <= 0;
			scoreAccumR <= 0;
			scoreOn <= True;
		end else begin
			insertColumnR <= insertColumnR + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// ScoreComparator: calculate and compare the complete-state score
	//------------------------------------------------------------------------------------
	rule calculateScore1 ( executionStartedR && busyR && updateStateR == UPDATE_IDLE && scoreOn && !selectorOn && !insertOn );
		MatrixColumn bpmWord = readBpmColumn(scoreColumnR);
		UInt#(32) columnMaximum = maxBpmEntry(bpmWord, configR.alphabetSize);
		UInt#(32) nextScore = scoreAccumR + columnMaximum;
		if ( (scoreColumnR + 1) >= configR.motifLength ) begin
			UInt#(32) nextUpdateNum = updateNumR + 1;
			Bool bestUpdate = nextScore > bestScoreR;
			UInt#(32) nextBestScore = bestUpdate ? nextScore : bestScoreR;
			Bool nextTerminated = nextBestScore >= configR.scoreThreshold ||
						 nextUpdateNum >= configR.maxUpdates;
			bestScoreR <= nextBestScore;
			updateNumR <= nextUpdateNum;
			terminatedR <= nextTerminated;
			busyR <= False;
			scoreOn <= False;
			resultQ.enq(PipelineResult{
				newOffset: selectedOffsetR,
				bestScore: nextBestScore,
				updateNum: nextUpdateNum,
				bestUpdate: bestUpdate,
				terminated: nextTerminated,
				active: activeR
				});
		end else begin
			scoreAccumR <= nextScore;
			scoreColumnR <= scoreColumnR + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Interface
	//------------------------------------------------------------------------------------
	method Action configure(PipelineConfig pipelineConfig,
				Bit#(128) randomSeed,
				UInt#(32) initialBestScore,
				Bool active) if ( !configuredR && !executionStartedR && !busyR );
		configR <= pipelineConfig;
		activeR <= active;
		bestScoreR <= initialBestScore;
		updateNumR <= 0;
		terminatedR <= !active || initialBestScore >= pipelineConfig.scoreThreshold;
		configuredR <= True;
		randomGenerator.seed(randomSeed);
	endmethod

	method Action loadSequenceBeat(Bit#(4) beatIdx, Bit#(512) word) if ( !busyR );
		sequenceWords[beatIdx] <= word;
	endmethod

	method Action loadBpmColumn(Bit#(8) column, MatrixColumn word) if ( !executionStartedR && !busyR );
		writeBpmColumn(column, word);
	endmethod

	method Action loadLpmColumn(Bit#(8) column, MatrixColumn word) if ( !executionStartedR && !busyR );
		writeLpmColumn(column, word);
	endmethod

	method Action startBootstrap if ( configuredR && !executionStartedR && !busyR );
		executionStartedR <= True;
		if ( terminatedR ) begin
			resultQ.enq(PipelineResult{
				newOffset: 0,
				bestScore: bestScoreR,
				updateNum: updateNumR,
				bestUpdate: False,
				terminated: True,
				active: activeR
				});
		end else begin
			randomGenerator.start;
			busyR <= True;
			beginProfiler;
		end
	endmethod

	method Action startUpdate(Bit#(11) tentativeOffset) if ( configuredR && executionStartedR && !busyR );
		if ( terminatedR ) begin
			resultQ.enq(PipelineResult{
				newOffset: tentativeOffset,
				bestScore: bestScoreR,
				updateNum: updateNumR,
				bestUpdate: False,
				terminated: True,
				active: activeR
				});
		end else begin
			busyR <= True;
			tentativeOffsetR <= tentativeOffset;
			updateBatchStartR <= 0;
			updateStateR <= UPDATE_BPM;
		end
	endmethod

	method ActionValue#(PipelineResult) result;
		PipelineResult value = resultQ.first;
		resultQ.deq;
		return value;
	endmethod

	method UInt#(32) bestScore;
		return bestScoreR;
	endmethod

	method Bool terminated;
		return terminatedR;
	endmethod

	method Bool busy;
		return busyR;
	endmethod
endmodule

endpackage
