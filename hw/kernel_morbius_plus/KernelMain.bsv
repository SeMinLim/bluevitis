package KernelMain;

import FIFOF::*;
import Vector::*;

import GibbsPipeline::*;
import MorbiusTypes::*;


typedef struct {
	Bit#(64) addr;
	Bit#(32) bytes;
} MemPortReq deriving (Eq, Bits, FShow);

typedef enum {
	KERNEL_IDLE,
	KERNEL_RECV_HEADER,
	KERNEL_RECV_SEQUENCE,
	KERNEL_RECV_BOOTSTRAP_STATE,
	KERNEL_RECV_BOOTSTRAP_BPM,
	KERNEL_RECV_BOOTSTRAP_LPM,
	KERNEL_RECV_OFFSETS,
	KERNEL_START_PIPELINES,
	KERNEL_WAIT_PIPELINES,
	KERNEL_WRITE_RESULT,
	KERNEL_WRITE_SUMMARY
} KernelState deriving (Bits, Eq, FShow);

interface KernelMainIfc;
	method Action start(Bit#(32) inputBytes);
	method ActionValue#(Bool) done;
	method ActionValue#(MemPortReq) inputReadReq;
	method Action inputReadWord(Bit#(512) word);
	method ActionValue#(MemPortReq) outputWriteReq;
	method ActionValue#(Bit#(512)) outputWriteWord;
endinterface

function Bit#(96) packPipelineResult(PipelineResult result);
	Bit#(96) value = 0;
	value[10:0] = result.newOffset;
	value[11] = pack(result.bestUpdate);
	value[12] = pack(result.terminated);
	value[13] = 1;
	value[40:16] = pack(result.bestScore);
	value[79:48] = pack(result.updateNum);
	return value;
endfunction

function Bit#(512) packResultWord(Bit#(8) beatIdx,
				  PipelineResult result0,
				  PipelineResult result1,
				  PipelineResult result2,
				  PipelineResult result3);
	Bit#(512) word = 0;
	word[31:0] = 32'h4d50524c;
	word[47:32] = 16'd2;
	word[55:48] = beatIdx;
	word[159:64] = packPipelineResult(result0);
	word[255:160] = packPipelineResult(result1);
	word[351:256] = packPipelineResult(result2);
	word[447:352] = packPipelineResult(result3);
	return word;
endfunction


module mkKernelMain(KernelMainIfc);
	Bit#(32) commandMagic = 32'h4d504c53;
	Bit#(32) resultMagic = 32'h4d50524c;
	Bit#(16) protocolVersion = 2;

	GibbsPipelineArrayIfc pipelineArray <- mkGibbsPipelineArray;

	FIFOF#(Bit#(32)) startQ <- mkFIFOF;
	FIFOF#(Bool) doneQ <- mkFIFOF;
	FIFOF#(MemPortReq) inputReadReqQ <- mkFIFOF;
	FIFOF#(Bit#(512)) inputReadWordQ <- mkSizedFIFOF(16);
	FIFOF#(MemPortReq) outputWriteReqQ <- mkFIFOF;
	FIFOF#(Bit#(512)) outputWriteWordQ <- mkSizedFIFOF(16);

	Reg#(Bool) startedR <- mkReg(False);
	Reg#(KernelState) stateR <- mkReg(KERNEL_IDLE);
	Reg#(UInt#(32)) cycleCounterR <- mkReg(0);
	Reg#(UInt#(32)) cycleStartR <- mkReg(0);

	Reg#(Bit#(8)) commandR <- mkReg(0);
	Reg#(Bit#(8)) motifLengthR <- mkReg(0);
	Reg#(UInt#(32)) batchSizeR <- mkReg(0);
	Reg#(Bit#(5)) sequenceBeatNumR <- mkReg(0);

	Reg#(Bit#(5)) sequenceBeatIdxR <- mkReg(0);
	Reg#(UInt#(32)) itemIdxR <- mkReg(0);
	Reg#(Bit#(PipelineIndexWidth)) bootstrapPipelineR <- mkReg(0);
	Reg#(Bit#(8)) bootstrapColumnR <- mkReg(0);
	Vector#(NumPE_LPM, Reg#(BpmEntries)) bootstrapBpmGroupR <- replicateM(mkRegU);
	Vector#(NumPE_LPM, Reg#(LpmEntries)) bootstrapLpmGroupR <- replicateM(mkRegU);
	Vector#(NumPipeline, Reg#(Bit#(11))) tentativeOffsetsR <- replicateM(mkReg(0));

	Vector#(ResultBeatNum, Reg#(Bit#(512))) resultWordsR <- replicateM(mkReg(0));
	Reg#(Bit#(ResultBeatIndexWidth)) resultBeatIdxR <- mkReg(0);
	Reg#(Bit#(512)) summaryWordR <- mkReg(0);
	Reg#(UInt#(32)) processedNumR <- mkReg(0);
	Reg#(Bool) allDoneR <- mkReg(False);

	rule incrementCycle;
		cycleCounterR <= cycleCounterR + 1;
	endrule

	//------------------------------------------------------------------------------------
	// Request the complete input command as one AXI burst
	//------------------------------------------------------------------------------------
	rule systemStart ( !startedR );
		Bit#(32) inputBytes = startQ.first;
		startQ.deq;
		inputReadReqQ.enq(MemPortReq{
			addr: 0,
			bytes: inputBytes
			});
		startedR <= True;
		stateR <= KERNEL_RECV_HEADER;
		cycleStartR <= cycleCounterR;
		itemIdxR <= 0;
		processedNumR <= 0;
		allDoneR <= False;
	endrule

	rule receiveHeader ( startedR && stateR == KERNEL_RECV_HEADER );
		Bit#(512) word = inputReadWordQ.first;
		inputReadWordQ.deq;
		if ( word[31:0] != commandMagic || word[47:32] != protocolVersion ) begin
			startedR <= False;
			stateR <= KERNEL_IDLE;
			doneQ.enq(True);
		end else begin
			Bit#(8) command = word[55:48];
			UInt#(32) batchSize = unpack(word[223:192]);
			UInt#(32) outputItemNum = command == 0 ? 1 : batchSize;
			UInt#(40) outputItemCount = zeroExtend(outputItemNum);
			UInt#(40) outputBytes = (outputItemCount << 8) + 64;
			Bit#(32) outputByteCount = truncate(pack(outputBytes));
			Bit#(25) scoreThresholdBits = word[152:128];
			ScoreValue scoreThreshold = unpack(scoreThresholdBits);

			commandR <= command;
			motifLengthR <= word[87:80];
			batchSizeR <= batchSize;
			sequenceBeatNumR <= truncate(word[255:224]);
			sequenceBeatIdxR <= 0;
			outputWriteReqQ.enq(MemPortReq{
				addr: 0,
				bytes: outputByteCount
				});
			if ( command == 0 ) begin
				pipelineArray.configure(PipelineConfig{
					sequenceLength: truncate(word[79:64]),
					motifLength: word[87:80],
					alphabetSize: truncate(word[63:56]),
					scoreThreshold: scoreThreshold,
					maxUpdates: unpack(word[191:160])
					});
			end
			stateR <= KERNEL_RECV_SEQUENCE;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Stream one sequence into the packed BRAM sequence memories
	//------------------------------------------------------------------------------------
	rule receiveSequenceBeat ( startedR && stateR == KERNEL_RECV_SEQUENCE );
		Bit#(512) word = inputReadWordQ.first;
		inputReadWordQ.deq;
		pipelineArray.loadSequenceBeat(truncate(sequenceBeatIdxR), word);
		if ( (sequenceBeatIdxR + 1) >= sequenceBeatNumR ) begin
			sequenceBeatIdxR <= 0;
			if ( commandR == 0 ) begin
				bootstrapPipelineR <= 0;
				stateR <= KERNEL_RECV_BOOTSTRAP_STATE;
			end else begin
				stateR <= KERNEL_RECV_OFFSETS;
			end
		end else begin
			sequenceBeatIdxR <= sequenceBeatIdxR + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Bootstrap one pipeline at a time and pack four matrix columns per BRAM word
	//------------------------------------------------------------------------------------
	rule receiveBootstrapState ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE );
		Bit#(512) word = inputReadWordQ.first;
		inputReadWordQ.deq;
		Bit#(25) initialBestScoreBits = word[152:128];
		ScoreValue initialBestScore = unpack(initialBestScoreBits);
		pipelineArray.configurePipeline(bootstrapPipelineR,
						word[127:0],
						initialBestScore);
		bootstrapColumnR <= 0;
		stateR <= KERNEL_RECV_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapBpm ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM );
		Bit#(512) word = inputReadWordQ.first;
		inputReadWordQ.deq;
		Bit#(2) columnOffset = truncate(bootstrapColumnR);
		Bit#(5) groupAddress = truncate(bootstrapColumnR >> 2);
		BpmGroup groupValue = replicate(replicate(0));
		if ( columnOffset != 0 ) groupValue = readVReg(bootstrapBpmGroupR);
		groupValue[columnOffset] = unpackBpmColumn(truncate(word));
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			bootstrapBpmGroupR[i] <= groupValue[i];
		end

		Bool finalColumn = (bootstrapColumnR + 1) >= motifLengthR;
		if ( columnOffset == 3 || finalColumn ) begin
			pipelineArray.loadBpmGroup(bootstrapPipelineR, groupAddress, groupValue);
		end
		if ( finalColumn ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_RECV_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
		end
	endrule

	rule receiveBootstrapLpm ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM );
		Bit#(512) word = inputReadWordQ.first;
		inputReadWordQ.deq;
		Bit#(2) columnOffset = truncate(bootstrapColumnR);
		Bit#(5) groupAddress = truncate(bootstrapColumnR >> 2);
		LpmGroup groupValue = replicate(replicate(0));
		if ( columnOffset != 0 ) groupValue = readVReg(bootstrapLpmGroupR);
		groupValue[columnOffset] = unpackLpmColumn(truncate(word));
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			bootstrapLpmGroupR[i] <= groupValue[i];
		end

		Bool finalColumn = (bootstrapColumnR + 1) >= motifLengthR;
		if ( columnOffset == 3 || finalColumn ) begin
			pipelineArray.loadLpmGroup(bootstrapPipelineR, groupAddress, groupValue);
		end
		if ( finalColumn ) begin
			bootstrapColumnR <= 0;
			if ( bootstrapPipelineR == fromInteger(valueOf(NumPipeline) - 1) ) begin
				stateR <= KERNEL_START_PIPELINES;
			end else begin
				bootstrapPipelineR <= bootstrapPipelineR + 1;
				stateR <= KERNEL_RECV_BOOTSTRAP_STATE;
			end
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Receive one offset vector for every subsequent sequence
	//------------------------------------------------------------------------------------
	rule receiveOffsets ( startedR && stateR == KERNEL_RECV_OFFSETS );
		Bit#(512) word = inputReadWordQ.first;
		inputReadWordQ.deq;
		for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
			Integer low = i * 32;
			tentativeOffsetsR[i] <= word[low + 10:low];
		end
		stateR <= KERNEL_START_PIPELINES;
	endrule

	rule startPipelines ( startedR && stateR == KERNEL_START_PIPELINES );
		if ( commandR == 0 ) begin
			pipelineArray.startBootstrap;
		end else begin
			pipelineArray.startUpdate(readVReg(tentativeOffsetsR));
		end
		stateR <= KERNEL_WAIT_PIPELINES;
	endrule

	//------------------------------------------------------------------------------------
	// Collect all sixteen results and prepare four fixed-slice output beats
	//------------------------------------------------------------------------------------
	rule waitPipelines ( startedR && stateR == KERNEL_WAIT_PIPELINES );
		let result <- pipelineArray.result;
		Bool allDone = True;
		for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
			allDone = allDone && result[i].terminated;
		end

		resultWordsR[0] <= packResultWord(0,
						 result[0], result[1], result[2], result[3]);
		resultWordsR[1] <= packResultWord(1,
						 result[4], result[5], result[6], result[7]);
		resultWordsR[2] <= packResultWord(2,
						 result[8], result[9], result[10], result[11]);
		resultWordsR[3] <= packResultWord(3,
						 result[12], result[13], result[14], result[15]);
		allDoneR <= allDone;
		processedNumR <= processedNumR + 1;
		resultBeatIdxR <= 0;
		stateR <= KERNEL_WRITE_RESULT;
	endrule

	rule writeResult ( startedR && stateR == KERNEL_WRITE_RESULT );
		case ( resultBeatIdxR )
			0: outputWriteWordQ.enq(resultWordsR[0]);
			1: outputWriteWordQ.enq(resultWordsR[1]);
			2: outputWriteWordQ.enq(resultWordsR[2]);
			default: outputWriteWordQ.enq(resultWordsR[3]);
		endcase

		if ( resultBeatIdxR != fromInteger(valueOf(ResultBeatNum) - 1) ) begin
			resultBeatIdxR <= resultBeatIdxR + 1;
		end else begin
			Bool finalItem = commandR == 0 || (itemIdxR + 1) >= batchSizeR;
			if ( finalItem ) begin
				Bit#(512) summary = 0;
				summary[31:0] = resultMagic;
				summary[47:32] = protocolVersion;
				summary[55:48] = 8'hff;
				summary[95:64] = pack(processedNumR);
				summary[96] = pack(allDoneR);
				summary[111:104] = 0;
				summary[159:128] = pack(cycleCounterR - cycleStartR);
				summaryWordR <= summary;
				stateR <= KERNEL_WRITE_SUMMARY;
			end else begin
				itemIdxR <= itemIdxR + 1;
				sequenceBeatIdxR <= 0;
				stateR <= KERNEL_RECV_SEQUENCE;
			end
		end
	endrule

	rule writeSummary ( startedR && stateR == KERNEL_WRITE_SUMMARY );
		outputWriteWordQ.enq(summaryWordR);
		startedR <= False;
		stateR <= KERNEL_IDLE;
		doneQ.enq(True);
	endrule

	method Action start(Bit#(32) inputBytes) if ( !startedR );
		startQ.enq(inputBytes);
	endmethod

	method ActionValue#(Bool) done;
		Bool value = doneQ.first;
		doneQ.deq;
		return value;
	endmethod

	method ActionValue#(MemPortReq) inputReadReq;
		MemPortReq value = inputReadReqQ.first;
		inputReadReqQ.deq;
		return value;
	endmethod

	method Action inputReadWord(Bit#(512) word);
		inputReadWordQ.enq(word);
	endmethod

	method ActionValue#(MemPortReq) outputWriteReq;
		MemPortReq value = outputWriteReqQ.first;
		outputWriteReqQ.deq;
		return value;
	endmethod

	method ActionValue#(Bit#(512)) outputWriteWord;
		Bit#(512) value = outputWriteWordQ.first;
		outputWriteWordQ.deq;
		return value;
	endmethod
endmodule

endpackage
