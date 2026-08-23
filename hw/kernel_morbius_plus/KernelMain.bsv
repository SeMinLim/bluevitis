package KernelMain;

import FIFO::*;
import FIFOF::*;
import Vector::*;

import MorbiusTypes::*;
import GibbsPipeline::*;


typedef 2 MemPortCnt;

typedef struct {
	Bit#(64) addr;
	Bit#(32) bytes;
} MemPortReq deriving (Eq, Bits, FShow);

typedef enum {
	KERNEL_IDLE,
	KERNEL_REQ_HEADER,
	KERNEL_RECV_HEADER,
	KERNEL_REQ_SEQUENCE,
	KERNEL_RECV_SEQUENCE,
	KERNEL_REQ_BOOTSTRAP_STATE,
	KERNEL_RECV_BOOTSTRAP_STATE,
	KERNEL_REQ_BOOTSTRAP_BPM,
	KERNEL_RECV_BOOTSTRAP_BPM,
	KERNEL_REQ_BOOTSTRAP_LPM,
	KERNEL_RECV_BOOTSTRAP_LPM,
	KERNEL_REQ_OFFSETS,
	KERNEL_RECV_OFFSETS,
	KERNEL_START_PIPELINES,
	KERNEL_WAIT_PIPELINES,
	KERNEL_REQ_RESULT_WRITE,
	KERNEL_WRITE_RESULT,
	KERNEL_REQ_SUMMARY_WRITE,
	KERNEL_WRITE_SUMMARY
} KernelState deriving (Bits, Eq, FShow);

interface MemPortIfc;
	method ActionValue#(MemPortReq) readReq;
	method ActionValue#(MemPortReq) writeReq;
	method ActionValue#(Bit#(512)) writeWord;
	method Action readWord(Bit#(512) word);
endinterface

interface KernelMainIfc;
	method Action start(Bit#(32) param);
	method ActionValue#(Bool) done;
	interface Vector#(MemPortCnt, MemPortIfc) mem;
endinterface

function Bit#(512) packPipelineResult(Bit#(512) word,
					      Integer pipelineIdx,
					      PipelineResult result);
	Integer base = 64 + pipelineIdx * 96;
	Bit#(96) packedValue = 0;
	packedValue[10:0] = result.newOffset;
	packedValue[11] = pack(result.bestUpdate);
	packedValue[12] = pack(result.terminated);
	packedValue[13] = pack(result.active);
	packedValue[47:16] = pack(result.bestScore);
	packedValue[79:48] = pack(result.updateNum);
	Bit#(512) mask = zeroExtend(96'hffffffffffffffffffffffff) << base;
	Bit#(512) value = zeroExtend(packedValue) << base;
	return (word & ~mask) | value;
endfunction

module mkKernelMain(KernelMainIfc);
	Bit#(32) commandMagic = 32'h4d504c53;
	Bit#(32) resultMagic = 32'h4d50524c;
	Bit#(16) protocolVersion = 1;

	Vector#(NumPipeline, GibbsPipelineIfc) pipelines <- replicateM(mkGibbsPipeline);

	FIFO#(Bool) startQ <- mkFIFO;
	FIFO#(Bool) doneQ <- mkFIFO;
	Vector#(MemPortCnt, FIFO#(MemPortReq)) readReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(MemPortReq)) writeReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) writeWordQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) readWordQs <- replicateM(mkFIFO);

	Reg#(Bool) startedR <- mkReg(False);
	Reg#(KernelState) stateR <- mkReg(KERNEL_IDLE);
	Reg#(UInt#(32)) cycleCounterR <- mkReg(0);
	Reg#(UInt#(32)) cycleStartR <- mkReg(0);

	Reg#(Bit#(8)) commandR <- mkReg(0);
	Reg#(Bit#(5)) alphabetSizeR <- mkReg(0);
	Reg#(Bit#(11)) sequenceLengthR <- mkReg(0);
	Reg#(Bit#(8)) motifLengthR <- mkReg(0);
	Reg#(Bit#(8)) pipelineNumR <- mkReg(0);
	Reg#(UInt#(32)) scoreThresholdR <- mkReg(0);
	Reg#(UInt#(32)) maxUpdatesR <- mkReg(0);
	Reg#(UInt#(32)) batchSizeR <- mkReg(0);
	Reg#(Bit#(5)) sequenceBeatNumR <- mkReg(0);

	Reg#(Bit#(64)) readCursorR <- mkReg(0);
	Reg#(Bit#(5)) sequenceBeatIdxR <- mkReg(0);
	Reg#(UInt#(32)) itemIdxR <- mkReg(0);
	Reg#(Bit#(3)) bootstrapPipelineR <- mkReg(0);
	Reg#(Bit#(8)) bootstrapColumnR <- mkReg(0);
	Vector#(NumPipeline, Reg#(Bit#(11))) tentativeOffsetsR <- replicateM(mkReg(0));

	Reg#(Bit#(512)) resultWordR <- mkReg(0);
	Reg#(Bit#(512)) summaryWordR <- mkReg(0);
	Reg#(Bit#(64)) resultWriteAddrR <- mkReg(0);
	Reg#(UInt#(32)) processedNumR <- mkReg(0);
	Reg#(Bool) allDoneR <- mkReg(False);
	Reg#(Bit#(2)) bestPipelineR <- mkReg(0);

	rule incrementCycle;
		cycleCounterR <= cycleCounterR + 1;
	endrule

	function PipelineConfig getPipelineConfig;
		return PipelineConfig{
			sequenceLength: sequenceLengthR,
			motifLength: motifLengthR,
			alphabetSize: alphabetSizeR,
			scoreThreshold: scoreThresholdR,
			maxUpdates: maxUpdatesR
			};
	endfunction


	rule systemStart ( !startedR );
		startQ.deq;
		startedR <= True;
		stateR <= KERNEL_REQ_HEADER;
		cycleStartR <= cycleCounterR;
		readCursorR <= 0;
		itemIdxR <= 0;
		processedNumR <= 0;
		allDoneR <= False;
		bestPipelineR <= 0;
	endrule

	rule requestHeader ( startedR && stateR == KERNEL_REQ_HEADER );
		readReqQs[0].enq(MemPortReq{addr: 0, bytes: 64});
		stateR <= KERNEL_RECV_HEADER;
	endrule

	rule receiveHeader ( startedR && stateR == KERNEL_RECV_HEADER );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		if ( word[31:0] != commandMagic || word[47:32] != protocolVersion ) begin
			startedR <= False;
			stateR <= KERNEL_IDLE;
			doneQ.enq(True);
		end else begin
			commandR <= word[55:48];
			alphabetSizeR <= truncate(word[63:56]);
			sequenceLengthR <= truncate(word[79:64]);
			motifLengthR <= word[87:80];
			pipelineNumR <= word[95:88];
			scoreThresholdR <= unpack(word[159:128]);
			maxUpdatesR <= unpack(word[191:160]);
			batchSizeR <= unpack(word[223:192]);
			sequenceBeatNumR <= truncate(word[255:224]);
			readCursorR <= 64;
			sequenceBeatIdxR <= 0;
			stateR <= KERNEL_REQ_SEQUENCE;
		end
	endrule

	rule requestSequenceBeat ( startedR && stateR == KERNEL_REQ_SEQUENCE );
		readReqQs[0].enq(MemPortReq{addr: readCursorR, bytes: 64});
		stateR <= KERNEL_RECV_SEQUENCE;
	endrule

	rule receiveSequenceBeat ( startedR && stateR == KERNEL_RECV_SEQUENCE );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
			pipelines[i].loadSequenceBeat(truncate(sequenceBeatIdxR), word);
		end
		readCursorR <= readCursorR + 64;
		if ( (sequenceBeatIdxR + 1) >= sequenceBeatNumR ) begin
			sequenceBeatIdxR <= 0;
			if ( commandR == 0 ) begin
				bootstrapPipelineR <= 0;
				stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
			end else begin
				stateR <= KERNEL_REQ_OFFSETS;
			end
		end else begin
			sequenceBeatIdxR <= sequenceBeatIdxR + 1;
			stateR <= KERNEL_REQ_SEQUENCE;
		end
	endrule

	rule requestBootstrapState ( startedR && stateR == KERNEL_REQ_BOOTSTRAP_STATE );
		readReqQs[0].enq(MemPortReq{addr: readCursorR, bytes: 64});
		stateR <= KERNEL_RECV_BOOTSTRAP_STATE;
	endrule

	rule receiveBootstrapState0 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 0 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(0) >= pipelineNumR ) active = False;
		pipelines[0].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule
	rule receiveBootstrapState1 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 1 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(1) >= pipelineNumR ) active = False;
		pipelines[1].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule
	rule receiveBootstrapState2 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 2 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(2) >= pipelineNumR ) active = False;
		pipelines[2].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule
	rule receiveBootstrapState3 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 3 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(3) >= pipelineNumR ) active = False;
		pipelines[3].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule requestBootstrapBpm ( startedR && stateR == KERNEL_REQ_BOOTSTRAP_BPM );
		readReqQs[0].enq(MemPortReq{addr: readCursorR, bytes: 64});
		stateR <= KERNEL_RECV_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapBpm0 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 0 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[0].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule
	rule receiveBootstrapBpm1 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 1 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[1].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule
	rule receiveBootstrapBpm2 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 2 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[2].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule
	rule receiveBootstrapBpm3 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 3 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[3].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule requestBootstrapLpm ( startedR && stateR == KERNEL_REQ_BOOTSTRAP_LPM );
		readReqQs[0].enq(MemPortReq{addr: readCursorR, bytes: 64});
		stateR <= KERNEL_RECV_BOOTSTRAP_LPM;
	endrule

	rule receiveBootstrapLpm0 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 0 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[0].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule
	rule receiveBootstrapLpm1 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 1 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[1].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 2;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule
	rule receiveBootstrapLpm2 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 2 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[2].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 3;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule
	rule receiveBootstrapLpm3 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 3 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[3].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			stateR <= KERNEL_START_PIPELINES;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule requestOffsets ( startedR && stateR == KERNEL_REQ_OFFSETS );
		readReqQs[0].enq(MemPortReq{addr: readCursorR, bytes: 64});
		stateR <= KERNEL_RECV_OFFSETS;
	endrule

	rule receiveOffsets ( startedR && stateR == KERNEL_RECV_OFFSETS );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
			Integer low = i * 32;
			tentativeOffsetsR[i] <= truncate(word >> low);
		end
		readCursorR <= readCursorR + 64;
		stateR <= KERNEL_START_PIPELINES;
	endrule

	rule startPipelines ( startedR && stateR == KERNEL_START_PIPELINES );
		if ( commandR == 0 ) begin
			for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
				pipelines[i].startBootstrap;
			end
		end else begin
			for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
				pipelines[i].startUpdate(tentativeOffsetsR[i]);
			end
		end
		stateR <= KERNEL_WAIT_PIPELINES;
	endrule

	rule waitPipelines ( startedR && stateR == KERNEL_WAIT_PIPELINES );
		let result0 <- pipelines[0].result;
		let result1 <- pipelines[1].result;
		let result2 <- pipelines[2].result;
		let result3 <- pipelines[3].result;

		Bit#(512) word = 0;
		word[31:0] = resultMagic;
		word[47:32] = protocolVersion;
		word[63:48] = truncate(pack(itemIdxR));
		word = packPipelineResult(word, 0, result0);
		word = packPipelineResult(word, 1, result1);
		word = packPipelineResult(word, 2, result2);
		word = packPipelineResult(word, 3, result3);

		Bool allDone = result0.terminated && result1.terminated &&
				   result2.terminated && result3.terminated;
		Bit#(2) bestIdx = 0;
		UInt#(32) bestScore = result0.bestScore;
		if ( result1.active && result1.bestScore > bestScore ) begin
			bestIdx = 1;
			bestScore = result1.bestScore;
		end
		if ( result2.active && result2.bestScore > bestScore ) begin
			bestIdx = 2;
			bestScore = result2.bestScore;
		end
		if ( result3.active && result3.bestScore > bestScore ) begin
			bestIdx = 3;
			bestScore = result3.bestScore;
		end
		word[448] = pack(allDone);
		word[463:456] = zeroExtend(bestIdx);
		word[495:464] = pack(bestScore);

		resultWordR <= word;
		allDoneR <= allDone;
		bestPipelineR <= bestIdx;
		processedNumR <= processedNumR + 1;
		resultWriteAddrR <= zeroExtend(pack(itemIdxR)) << 6;
		stateR <= KERNEL_REQ_RESULT_WRITE;
	endrule

	rule requestResultWrite ( startedR && stateR == KERNEL_REQ_RESULT_WRITE );
		writeReqQs[1].enq(MemPortReq{addr: resultWriteAddrR, bytes: 64});
		stateR <= KERNEL_WRITE_RESULT;
	endrule

	rule writeResult ( startedR && stateR == KERNEL_WRITE_RESULT );
		writeWordQs[1].enq(resultWordR);
		Bool finalItem = commandR == 0 || allDoneR || (itemIdxR + 1) >= batchSizeR;
		if ( finalItem ) begin
			Bit#(512) summary = 0;
			summary[31:0] = resultMagic;
			summary[47:32] = protocolVersion;
			summary[95:64] = pack(processedNumR);
			summary[96] = pack(allDoneR);
			summary[111:104] = zeroExtend(bestPipelineR);
			summary[159:128] = pack(cycleCounterR - cycleStartR);
			for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
				Integer base = 192 + i * 64;
				summary[base + 31:base] = pack(pipelines[i].bestScore);
				summary[base + 32] = pack(pipelines[i].terminated);
			end
			summaryWordR <= summary;
			resultWriteAddrR <= zeroExtend(pack(batchSizeR)) << 6;
			stateR <= KERNEL_REQ_SUMMARY_WRITE;
		end else begin
			itemIdxR <= itemIdxR + 1;
			sequenceBeatIdxR <= 0;
			stateR <= KERNEL_REQ_SEQUENCE;
		end
	endrule

	rule requestSummaryWrite ( startedR && stateR == KERNEL_REQ_SUMMARY_WRITE );
		writeReqQs[1].enq(MemPortReq{addr: resultWriteAddrR, bytes: 64});
		stateR <= KERNEL_WRITE_SUMMARY;
	endrule

	rule writeSummary ( startedR && stateR == KERNEL_WRITE_SUMMARY );
		writeWordQs[1].enq(summaryWordR);
		startedR <= False;
		stateR <= KERNEL_IDLE;
		doneQ.enq(True);
	endrule

	Vector#(MemPortCnt, MemPortIfc) memIfc;
	for ( Integer i = 0; i < valueOf(MemPortCnt); i = i + 1 ) begin
		memIfc[i] = interface MemPortIfc;
			method ActionValue#(MemPortReq) readReq;
				MemPortReq value = readReqQs[i].first;
				readReqQs[i].deq;
				return value;
			endmethod

			method ActionValue#(MemPortReq) writeReq;
				MemPortReq value = writeReqQs[i].first;
				writeReqQs[i].deq;
				return value;
			endmethod

			method ActionValue#(Bit#(512)) writeWord;
				Bit#(512) value = writeWordQs[i].first;
				writeWordQs[i].deq;
				return value;
			endmethod

			method Action readWord(Bit#(512) word);
				readWordQs[i].enq(word);
			endmethod
		endinterface;
	end

	method Action start(Bit#(32) param) if ( !startedR );
		startQ.enq(True);
	endmethod

	method ActionValue#(Bool) done;
		Bool value = doneQ.first;
		doneQ.deq;
		return value;
	endmethod

	interface mem = memIfc;
endmodule

endpackage
