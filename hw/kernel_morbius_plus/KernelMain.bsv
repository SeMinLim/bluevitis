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
					      Integer resultSlot,
					      PipelineResult result);
	Integer base = 64 + resultSlot * 96;
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
	Bit#(16) protocolVersion = 2;

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
	Reg#(Bit#(PipelineIndexWidth)) bootstrapPipelineR <- mkReg(0);
	Reg#(Bit#(8)) bootstrapColumnR <- mkReg(0);
	Vector#(NumPipeline, Reg#(Bit#(11))) tentativeOffsetsR <- replicateM(mkReg(0));

	Vector#(ResultBeatNum, Reg#(Bit#(512))) resultWordsR <- replicateM(mkReg(0));
	Reg#(Bit#(ResultBeatIndexWidth)) resultBeatIdxR <- mkReg(0);
	Reg#(Bit#(512)) summaryWordR <- mkReg(0);
	Reg#(Bit#(64)) resultWriteAddrR <- mkReg(0);
	Reg#(UInt#(32)) processedNumR <- mkReg(0);
	Reg#(Bool) allDoneR <- mkReg(False);
	Reg#(Bit#(PipelineIndexWidth)) bestPipelineR <- mkReg(0);

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

	rule receiveBootstrapState4 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 4 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(4) >= pipelineNumR ) active = False;
		pipelines[4].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState5 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 5 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(5) >= pipelineNumR ) active = False;
		pipelines[5].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState6 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 6 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(6) >= pipelineNumR ) active = False;
		pipelines[6].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState7 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 7 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(7) >= pipelineNumR ) active = False;
		pipelines[7].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState8 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 8 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(8) >= pipelineNumR ) active = False;
		pipelines[8].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState9 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 9 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(9) >= pipelineNumR ) active = False;
		pipelines[9].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState10 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 10 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(10) >= pipelineNumR ) active = False;
		pipelines[10].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState11 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 11 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(11) >= pipelineNumR ) active = False;
		pipelines[11].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState12 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 12 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(12) >= pipelineNumR ) active = False;
		pipelines[12].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState13 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 13 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(13) >= pipelineNumR ) active = False;
		pipelines[13].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState14 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 14 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(14) >= pipelineNumR ) active = False;
		pipelines[14].configure(getPipelineConfig,
				       word[127:0],
				       unpack(word[159:128]),
				       active);
		readCursorR <= readCursorR + 64;
		bootstrapColumnR <= 0;
		stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
	endrule

	rule receiveBootstrapState15 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_STATE && bootstrapPipelineR == 15 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		Bool active = unpack(word[160]);
		if ( fromInteger(15) >= pipelineNumR ) active = False;
		pipelines[15].configure(getPipelineConfig,
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

	rule receiveBootstrapBpm4 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 4 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[4].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm5 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 5 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[5].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm6 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 6 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[6].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm7 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 7 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[7].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm8 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 8 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[8].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm9 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 9 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[9].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm10 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 10 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[10].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm11 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 11 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[11].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm12 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 12 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[12].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm13 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 13 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[13].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm14 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 14 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[14].loadBpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapColumnR <= 0;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_BPM;
		end
	endrule

	rule receiveBootstrapBpm15 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_BPM && bootstrapPipelineR == 15 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[15].loadBpmColumn(bootstrapColumnR, truncate(word));
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
			bootstrapPipelineR <= 4;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm4 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 4 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[4].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 5;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm5 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 5 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[5].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 6;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm6 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 6 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[6].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 7;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm7 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 7 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[7].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 8;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm8 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 8 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[8].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 9;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm9 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 9 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[9].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 10;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm10 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 10 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[10].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 11;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm11 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 11 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[11].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 12;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm12 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 12 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[12].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 13;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm13 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 13 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[13].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 14;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm14 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 14 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[14].loadLpmColumn(bootstrapColumnR, truncate(word));
		readCursorR <= readCursorR + 64;
		if ( (bootstrapColumnR + 1) >= motifLengthR ) begin
			bootstrapPipelineR <= 15;
			stateR <= KERNEL_REQ_BOOTSTRAP_STATE;
		end else begin
			bootstrapColumnR <= bootstrapColumnR + 1;
			stateR <= KERNEL_REQ_BOOTSTRAP_LPM;
		end
	endrule

	rule receiveBootstrapLpm15 ( startedR && stateR == KERNEL_RECV_BOOTSTRAP_LPM && bootstrapPipelineR == 15 );
		Bit#(512) word = readWordQs[0].first;
		readWordQs[0].deq;
		pipelines[15].loadLpmColumn(bootstrapColumnR, truncate(word));
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
		let result4 <- pipelines[4].result;
		let result5 <- pipelines[5].result;
		let result6 <- pipelines[6].result;
		let result7 <- pipelines[7].result;
		let result8 <- pipelines[8].result;
		let result9 <- pipelines[9].result;
		let result10 <- pipelines[10].result;
		let result11 <- pipelines[11].result;
		let result12 <- pipelines[12].result;
		let result13 <- pipelines[13].result;
		let result14 <- pipelines[14].result;
		let result15 <- pipelines[15].result;

		Vector#(NumPipeline, PipelineResult) result = newVector;
		result[0] = result0;
		result[1] = result1;
		result[2] = result2;
		result[3] = result3;
		result[4] = result4;
		result[5] = result5;
		result[6] = result6;
		result[7] = result7;
		result[8] = result8;
		result[9] = result9;
		result[10] = result10;
		result[11] = result11;
		result[12] = result12;
		result[13] = result13;
		result[14] = result14;
		result[15] = result15;

		Bool allDone = True;
		Bit#(PipelineIndexWidth) bestIdx = 0;
		UInt#(32) bestScore = 0;
		for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
			allDone = allDone && result[i].terminated;
			if ( result[i].active && result[i].bestScore > bestScore ) begin
				bestIdx = fromInteger(i);
				bestScore = result[i].bestScore;
			end
		end

		Vector#(ResultBeatNum, Bit#(512)) resultWords = replicate(0);
		for ( Integer beatIdx = 0; beatIdx < valueOf(ResultBeatNum); beatIdx = beatIdx + 1 ) begin
			Bit#(512) word = 0;
			word[31:0] = resultMagic;
			word[47:32] = protocolVersion;
			word[55:48] = fromInteger(beatIdx);
			for ( Integer slotIdx = 0;
			      slotIdx < valueOf(PipelinePerResultBeat);
			      slotIdx = slotIdx + 1 ) begin
				Integer pipelineIdx = beatIdx * valueOf(PipelinePerResultBeat) + slotIdx;
				word = packPipelineResult(word, slotIdx, result[pipelineIdx]);
			end
			resultWords[beatIdx] = word;
		end
		for ( Integer i = 0; i < valueOf(ResultBeatNum); i = i + 1 ) begin
			resultWordsR[i] <= resultWords[i];
		end

		allDoneR <= allDone;
		bestPipelineR <= bestIdx;
		processedNumR <= processedNumR + 1;
		resultBeatIdxR <= 0;
		resultWriteAddrR <= zeroExtend(pack(itemIdxR)) << 8;
		stateR <= KERNEL_REQ_RESULT_WRITE;
	endrule

	rule requestResultWrite ( startedR && stateR == KERNEL_REQ_RESULT_WRITE );
		writeReqQs[1].enq(MemPortReq{addr: resultWriteAddrR, bytes: 64});
		stateR <= KERNEL_WRITE_RESULT;
	endrule

	rule writeResult ( startedR && stateR == KERNEL_WRITE_RESULT );
		Vector#(ResultBeatNum, Bit#(512)) resultWords = readVReg(resultWordsR);
		writeWordQs[1].enq(resultWords[resultBeatIdxR]);
		if ( resultBeatIdxR != fromInteger(valueOf(ResultBeatNum) - 1) ) begin
			resultBeatIdxR <= resultBeatIdxR + 1;
			resultWriteAddrR <= resultWriteAddrR + 64;
			stateR <= KERNEL_REQ_RESULT_WRITE;
		end else begin
			Bool finalItem = commandR == 0 || allDoneR || (itemIdxR + 1) >= batchSizeR;
			if ( finalItem ) begin
				Bit#(512) summary = 0;
				summary[31:0] = resultMagic;
				summary[47:32] = protocolVersion;
				summary[55:48] = 8'hff;
				summary[95:64] = pack(processedNumR);
				summary[96] = pack(allDoneR);
				summary[111:104] = zeroExtend(bestPipelineR);
				summary[159:128] = pack(cycleCounterR - cycleStartR);
				summaryWordR <= summary;
				resultWriteAddrR <= zeroExtend(pack(batchSizeR)) << 8;
				stateR <= KERNEL_REQ_SUMMARY_WRITE;
			end else begin
				itemIdxR <= itemIdxR + 1;
				sequenceBeatIdxR <= 0;
				stateR <= KERNEL_REQ_SEQUENCE;
			end
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
