import FIFO::*;
import Vector::*;
import Serializer::*;


typedef 0 ResultAddrStart;
typedef 2 MemPortCnt;
typedef enum {
	ST_IDLE,
	ST_READ_REQ,
	ST_READ_WAIT,
	ST_SER_PUT,
	ST_SER_GET,
	ST_DESER_GET,
	ST_REP_PUT,
	ST_REP_GET,
	ST_LAST_PUT,
	ST_LAST_GET,
	ST_SKIP_FEED0,
	ST_SKIP_GET0,
	ST_SKIP_FEED1,
	ST_SKIP_GET1,
	ST_SKIP_TAIL,
	ST_SHIFT_PUT,
	ST_SHIFT_GET,
	ST_FREE_RUN,
	ST_PACK,
	ST_WRITE_REQ,
	ST_WRITE_WORD,
	ST_DONE
} TestState deriving (Bits, Eq);
typedef struct {
	Bit#(64) addr;
	Bit#(32) bytes;
} MemPortReq deriving (Eq, Bits);


function Bit#(8) skipInput(UInt#(4) idx);
	case (idx)
		0:       return 8'hA0;
		1:       return 8'hA1;
		2:       return 8'hA2;
		3:       return 8'hA3;
		4:       return 8'hB0;
		5:       return 8'hB1;
		6:       return 8'hB2;
		7:       return 8'hB3;
		default: return 8'h00;
	endcase
endfunction
function Bit#(10) freeInput(UInt#(3) idx);
	case (idx)
		0:       return 10'h3AB;
		1:       return 10'h155;
		2:       return 10'h2C3;
		default: return 10'h000;
	endcase
endfunction


interface MemPortIfc;
	method ActionValue#(MemPortReq) readReq;
	method ActionValue#(MemPortReq) writeReq;
	method ActionValue#(Bit#(512))  writeWord;
	method Action readWord(Bit#(512) word);
endinterface
interface KernelMainIfc;
	method Action start(Bit#(32) param);
	method ActionValue#(Bool) done;
	interface Vector#(MemPortCnt, MemPortIfc) mem;
endinterface
module mkKernelMain(KernelMainIfc);
	FIFO#(Bool) startQ <- mkFIFO;
	FIFO#(Bool) doneQ  <- mkFIFO;

	Reg#(Bool) started <- mkReg(False);
	Reg#(TestState) state <- mkReg(ST_IDLE);

	Vector#(MemPortCnt, FIFO#(MemPortReq)) readReqQs   <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(MemPortReq)) writeReqQs  <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512)))  writeWordQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512)))  readWordQs  <- replicateM(mkFIFO);
	//-----------------------------------------------------------------------------------
	// passMask Bit Assignment
	// bit0: mkSerializer,   bit1: mkStreamReplicate, bit2: mkStreamSerializeLast
	// bit3: mkDeSerializer, bit4: mkStreamSkip,      bit5: mkPipelineShiftRight
	// bit6: mkSerializerFreeform
	//-----------------------------------------------------------------------------------
	SerializerIfc#(32, 4)         ser      <- mkSerializer;
	DeSerializerIfc#(8, 4)        deser    <- mkDeSerializer;
	FIFO#(Bit#(8))                rep      <- mkStreamReplicate(3);
	FIFO#(Bool)                   lastFlag <- mkStreamSerializeLast(4);
	FIFO#(Bit#(8))                skip     <- mkStreamSkip(4, 2);
	PipelineShiftIfc#(64, 6)      shifter  <- mkPipelineShiftRight;
	SerializerFreeformIfc#(10, 6) freeform <- mkSerializerFreeform;

	Reg#(Bit#(7))  passMask  <- mkReg(0);
	Reg#(UInt#(3)) serCount  <- mkReg(0);
	Reg#(Bit#(32)) serObs    <- mkReg(0);
	Reg#(Bit#(32)) deserObs  <- mkReg(0);

	Reg#(UInt#(2)) repCount  <- mkReg(0);
	Reg#(Bit#(24)) repObs    <- mkReg(0);

	Reg#(UInt#(3)) lastCount <- mkReg(0);
	Reg#(Bit#(4))  lastObs   <- mkReg(0);

	Reg#(UInt#(4)) skipFeedIdx <- mkReg(0);
	Reg#(Bit#(16)) skipObs     <- mkReg(0);

	Reg#(Bit#(64)) shiftObs <- mkReg(0);

	Reg#(UInt#(3)) freeInCount  <- mkReg(0);
	Reg#(UInt#(3)) freeOutCount <- mkReg(0);
	Reg#(Bit#(30)) freeObs      <- mkReg(0);

	Reg#(Bit#(32)) inputObs  <- mkReg(0);
	Reg#(Bool)     inputPass <- mkReg(False);
	
	Reg#(Bit#(512)) resultWord <- mkReg(0);

	Reg#(Bit#(32)) cycleCounter <- mkReg(0);
	Reg#(Bit#(32)) cycleStart   <- mkReg(0);
	rule incCycle;
		cycleCounter <= cycleCounter + 1;
	endrule

	rule systemStart (!started);
		startQ.deq;

		rep.clear;
		lastFlag.clear;
		skip.clear;

		started      <= True;
		state        <= ST_READ_REQ;
		cycleStart   <= cycleCounter;
		passMask     <= 0;
		serCount     <= 0;
		serObs       <= 0;
		deserObs     <= 0;
		repCount     <= 0;
		repObs       <= 0;
		lastCount    <= 0;
		lastObs      <= 0;
		skipFeedIdx  <= 0;
		skipObs      <= 0;
		shiftObs     <= 0;
		freeInCount  <= 0;
		freeOutCount <= 0;
		freeObs      <= 0;
		inputObs     <= 0;
		inputPass    <= False;
		resultWord   <= 0;
	endrule
	//-----------------------------------------------------------------------------------
	// Read one 512-bit word from the input BO (port 0). The host writes 32'h11223344 to lane 0. 
	// Test the host -> PLRAM(URAM-mapped) -> kernel read path.
	//-----------------------------------------------------------------------------------
	rule requestInputWord (started && state == ST_READ_REQ);
		readReqQs[0].enq(MemPortReq{addr: 64'd0, bytes: 32'd64});
		state <= ST_READ_WAIT;
	endrule
	rule receiveInputWord (started && state == ST_READ_WAIT);
		let w = readWordQs[0].first;
		readWordQs[0].deq;
		
		Bit#(32) hostWord = truncate(w);
		inputObs  <= hostWord;
		inputPass <= (hostWord == 32'h11223344);
		state <= ST_SER_PUT;
	endrule
	//-----------------------------------------------------------------------------------
	// 1) mkSerializer and 2) mkDeSerializer round-trip
	//-----------------------------------------------------------------------------------
	rule testSerializerPut (started && state == ST_SER_PUT);
		ser.put(inputObs);
		state <= ST_SER_GET;
	endrule
	rule testSerializerGet (started && state == ST_SER_GET);
		let x <- ser.get;
		Bit#(32) nextSer = (zeroExtend(x) << 24) | (serObs >> 8);

		serObs <= nextSer;
		deser.put(x);

		if (serCount == 3) begin
			if (nextSer == inputObs) passMask <= passMask | 7'b0000001;
			serCount <= 0;
			state <= ST_DESER_GET;
		end else begin
			serCount <= serCount + 1;
		end
	endrule
	rule testDeSerializerGet (started && state == ST_DESER_GET);
		let x <- deser.get;
		deserObs <= x;
		
		if (x == inputObs) passMask <= passMask | 7'b0001000;
		state <= ST_REP_PUT;
	endrule
	//-----------------------------------------------------------------------------------
	// 3) mkStreamReplicate
	//-----------------------------------------------------------------------------------
	rule testReplicatePut (started && state == ST_REP_PUT);
		rep.enq(8'hA6);
		state <= ST_REP_GET;
	endrule
	rule testReplicateGet (started && state == ST_REP_GET);
		let x = rep.first;
		rep.deq;

		Bit#(24) nextRep = {repObs[15:0], x};
		repObs <= nextRep;

		if (repCount == 2) begin
			if (nextRep == 24'hA6A6A6) passMask <= passMask | 7'b0000010;
			repCount <= 0;
			state <= ST_LAST_PUT;
		end else begin
			repCount <= repCount + 1;
		end
	endrule
	//-----------------------------------------------------------------------------------
	// 4) mkStreamSerializeLast
	//-----------------------------------------------------------------------------------
   	rule testLastPut (started && state == ST_LAST_PUT);
		lastFlag.enq(True);
		state <= ST_LAST_GET;
	endrule
	rule testLastGet (started && state == ST_LAST_GET);
		let b = lastFlag.first;
		lastFlag.deq;

		Bit#(4) nextLast = {lastObs[2:0], pack(b)};
		lastObs <= nextLast;

		if (lastCount == 3) begin
			if (nextLast == 4'b0001) passMask <= passMask | 7'b0000100;
			lastCount <= 0;
			state <= ST_SKIP_FEED0;
		end else begin
			lastCount <= lastCount + 1;
		end
	endrule
	//-----------------------------------------------------------------------------------
	// 5) mkStreamSkip
	//-----------------------------------------------------------------------------------
	rule testSkipFeed0 (started && state == ST_SKIP_FEED0);
		skip.enq(skipInput(skipFeedIdx));
		
		if (skipFeedIdx == 2) begin
			skipFeedIdx <= 3;
			state <= ST_SKIP_GET0;
		end else begin
			skipFeedIdx <= skipFeedIdx + 1;
		end
	endrule
	rule testSkipGet0 (started && state == ST_SKIP_GET0);
		let x = skip.first;
		skip.deq;

		skipObs <= {8'h00, x};
		state <= ST_SKIP_FEED1;
	endrule
	rule testSkipFeed1 (started && state == ST_SKIP_FEED1);
		skip.enq(skipInput(skipFeedIdx));
		
		if (skipFeedIdx == 6) begin
			skipFeedIdx <= 7;
			state <= ST_SKIP_GET1;
		end else begin
			skipFeedIdx <= skipFeedIdx + 1;
		end
	endrule
	rule testSkipGet1 (started && state == ST_SKIP_GET1);
		let x = skip.first;
		skip.deq;

		Bit#(16) nextSkip = {skipObs[7:0], x};
		skipObs <= nextSkip;

		if (nextSkip == 16'hA2B2) passMask <= passMask | 7'b0010000;
		state <= ST_SKIP_TAIL;
	endrule
	rule testSkipTail (started && state == ST_SKIP_TAIL);
	// Complete the frame so the internal index returns to 0 before the next run.
		skip.enq(skipInput(7));
		state <= ST_SHIFT_PUT;
	endrule
	//-----------------------------------------------------------------------------------
	// 6) mkPipelineShiftRight
   	//-----------------------------------------------------------------------------------
	rule testShiftPut (started && state == ST_SHIFT_PUT);
		shifter.put(64'hFEDCBA9876543210, 6'd12);
		state <= ST_SHIFT_GET;
	endrule
	rule testShiftGet (started && state == ST_SHIFT_GET);
		let x <- shifter.get;
		shiftObs <= x;

		if (x == 64'h000FEDCBA9876543) passMask <= passMask | 7'b0100000;
		state <= ST_FREE_RUN;
	endrule
	//-----------------------------------------------------------------------------------
	// 7) mkSerializerFreeform (3 x 10-bit -> 5 x 6-bit).
	// Expected outputs: 2B, 1E, 15, 0D, 2C
	// Packed observation: 0x2B79536C
	//-----------------------------------------------------------------------------------
	rule testFreeformFeed (started && state == ST_FREE_RUN && freeInCount < 3);
		freeform.put(freeInput(freeInCount));
		freeInCount <= freeInCount + 1;
	endrule
	rule testFreeformGet (started && state == ST_FREE_RUN && freeOutCount < 5);
		let x <- freeform.get;
		Bit#(30) nextFree = {freeObs[23:0], x};
		freeObs <= nextFree;

		if (freeOutCount == 4) begin
			if (nextFree == 30'h2B79536C) passMask <= passMask | 7'b1000000;
			state <= ST_PACK;
		end else begin
			freeOutCount <= freeOutCount + 1;
		end
	endrule
	//-----------------------------------------------------------------------------------
	// Results
	// 16 x 32-bit lanes in one 512-bit result word.
	// lane  0: magic,                                  lane  1: status (3 means PASS),
	// lane  2: passMask,                               lane  3: elapsed cycles,
	// lane  4: serializer observation,                 lane  5: deserializer observation
	// lane  6: replicate observation,                  lane  7: serialize-last observation, 
	// lane  8: skip observation,                       lane  9: shift observation low 32b, 
	// lane 10: shift observation high 32b,             lane 11: freeform observation
	// lane 12: host input word observed by the kernel, lane 13: host input pass flag (1 if lane12 == 0x11223344)
	// lane 14: zero, 				    lane 15: zero
	//-----------------------------------------------------------------------------------
	rule packResults (started && state == ST_PACK);
		Bit#(32) magic      = 32'h53524C5A; // 'SRLZ'
		Bit#(32) cycles     = cycleCounter - cycleStart;
		Bit#(32) passMask32 = zeroExtend(passMask);
		Bit#(32) repObs32   = zeroExtend(repObs);
		Bit#(32) lastObs32  = zeroExtend(lastObs);
		Bit#(32) skipObs32  = zeroExtend(skipObs);
		Bit#(32) freeObs32  = zeroExtend(freeObs);
		Bit#(32) shiftLo32  = shiftObs[31:0];
		Bit#(32) shiftHi32  = shiftObs[63:32];
		Bit#(32) inputPass32 = zeroExtend(pack(inputPass));
		Bit#(32) status     = (inputPass && (passMask == 7'b1111111)) ? 32'd3 : (32'hBAD00000 | zeroExtend(passMask));

		resultWord <= { 32'h0, 32'h0, inputPass32, inputObs, freeObs32, shiftHi32, shiftLo32, skipObs32,
				lastObs32, repObs32, deserObs, serObs, cycles, passMask32, status, magic };
		state <= ST_WRITE_REQ;
	endrule

	rule reqWriteResult (started && state == ST_WRITE_REQ);
		writeReqQs[1].enq(MemPortReq{addr: fromInteger(valueOf(ResultAddrStart)), bytes: 64});
		state <= ST_WRITE_WORD;
	endrule
	rule writeResult (started && state == ST_WRITE_WORD);
		writeWordQs[1].enq(resultWord);
		state <= ST_DONE;
	endrule

	rule finish (started && state == ST_DONE);
		started <= False;
		state <= ST_IDLE;
		doneQ.enq(True);
	endrule

	Vector#(MemPortCnt, MemPortIfc) mem_;
	for (Integer i = 0; i < valueOf(MemPortCnt); i = i + 1) begin
		mem_[i] = interface MemPortIfc;
			method ActionValue#(MemPortReq) readReq;
				let r = readReqQs[i].first;
				readReqQs[i].deq;
				return r;
			endmethod
			method ActionValue#(MemPortReq) writeReq;
				let r = writeReqQs[i].first;
				writeReqQs[i].deq;
				return r;
			endmethod
			method ActionValue#(Bit#(512)) writeWord;
				let w = writeWordQs[i].first;
				writeWordQs[i].deq;
				return w;
			endmethod
			method Action readWord(Bit#(512) word);
				readWordQs[i].enq(word);
			endmethod
		endinterface;
	end


	method Action start(Bit#(32) param) if (!started);
		startQ.enq(True);
	endmethod
	method ActionValue#(Bool) done;
		let d = doneQ.first;
		doneQ.deq;
		return d;
	endmethod
	interface mem = mem_;
endmodule
