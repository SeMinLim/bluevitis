import FIFO::*;
import FIFOF::*;
import Vector::*;

import BRAM::*;
import BRAMFIFO::*;
import GetPut::*;
import CRC32::*;


typedef 1 DataCntTotal512b_X;
typedef 0 MemPortAddrStart_0;
typedef 0 ResultAddrStart;
typedef 2 MemPortCnt;
typedef struct {
	Bit#(64) addr;
	Bit#(32) bytes;
} MemPortReq deriving (Eq,Bits);


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
module mkKernelMain(KernelMainIfc);
	CRC32Ifc crc32Reflected <- mkCRC32;
	CRC32CIfc crc32cReflected <- mkCRC32C;

	FIFO#(Bool) startQ <- mkFIFO;
	FIFO#(Bool) doneQ  <- mkFIFO;
	
	FIFO#(Bit#(512)) dataQ_X <- mkSizedBRAMFIFO(8);
	FIFO#(Bit#(512)) resultQ <- mkSizedBRAMFIFO(8);

	Reg#(Bool) started <- mkReg(False);
	Reg#(Bool) reqReadDataOn_X <- mkReg(False);
	Reg#(Bool) readDataOn_X <- mkReg(False);
	Reg#(Bool) exampleStartPhase1 <- mkReg(False);
	Reg#(Bool) exampleStartPhase2 <- mkReg(False);
	Reg#(Bool) reqWriteResultOn <- mkReg(False);
	Reg#(Bool) writeResultOn <- mkReg(False);
	//------------------------------------------------------------------------------------
	// [Cycle Counter]
	//------------------------------------------------------------------------------------
	Reg#(Bit#(32)) cycleCounter <- mkReg(0);
	rule incCycle;
		cycleCounter <= cycleCounter + 1;
	endrule
	//------------------------------------------------------------------------------------
	// [System Start]
	//------------------------------------------------------------------------------------
	rule systemStart( !started );
		startQ.deq;
		started <= True;
		reqReadDataOn_X <= True;
	endrule
	//------------------------------------------------------------------------------------
	// [Memory Read / Write Plumbing]
	//------------------------------------------------------------------------------------
	Vector#(MemPortCnt, FIFO#(MemPortReq)) readReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(MemPortReq)) writeReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) writeWordQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) readWordQs <- replicateM(mkFIFO);

	// Read one 512-bit input word from MEMPORT 0
	Reg#(Bit#(32)) reqReadDataCnt_X <- mkReg(0);
	Reg#(Bit#(64)) memPortAddr_0 <- mkReg(fromInteger(valueOf(MemPortAddrStart_0)));
	rule reqReadDataX( reqReadDataOn_X );
		readReqQs[0].enq(MemPortReq{addr:memPortAddr_0, bytes:64});

		if ( reqReadDataCnt_X + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			memPortAddr_0 <= 0;
			reqReadDataCnt_X <= 0;
			reqReadDataOn_X <= False;
		end else begin
			memPortAddr_0 <= memPortAddr_0 + 64;
			reqReadDataCnt_X <= reqReadDataCnt_X + 1;
		end

		readDataOn_X <= True;
	endrule
	Reg#(Bit#(32)) readDataCnt_X <- mkReg(0);
	rule readDataX( readDataOn_X );
		let data = readWordQs[0].first;
		readWordQs[0].deq;

		dataQ_X.enq(data);

		if ( readDataCnt_X + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			readDataCnt_X <= 0;
			readDataOn_X <= False;
			$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : Read 1 input word\n", cycleCounter );
		end else begin
			readDataCnt_X <= readDataCnt_X + 1;
		end

		exampleStartPhase1 <= True;
	endrule
	//------------------------------------------------------------------------------------
	// Example Logic: compute CRC32 / CRC32C on the lower 64 bits of the input word
	// Uses functions imported from CRC32.bsv
	//------------------------------------------------------------------------------------
	rule examplePhase1( exampleStartPhase1 );
		let inWord = dataQ_X.first;
		dataQ_X.deq;

		Bit#(64) data64 = truncate(inWord);
		
		let req = Crc32Req {crcInit: 32'hFFFF_FFFF, data64: data64};
		crc32Reflected.in.put(req);
		crc32cReflected.in.put(req);

		exampleStartPhase2 <= True;
	endrule
	rule examplePhase2( exampleStartPhase2 );
		let resultCrc32 <- crc32Reflected.out.get;
		let resultCrc32c <- crc32cReflected.out.get;

		Bit#(64) packedFinal = {resultCrc32c.crcOut, resultCrc32.crcOut};
		Bit#(512) result = zeroExtend(packedFinal);

		resultQ.enq(result);
		reqWriteResultOn <= True;
	endrule
	//------------------------------------------------------------------------------------
	// [Memory Write] & [System Finish]
	// Write result to MEMPORT 1, first 64 bytes only.
	// result[31:0]  = CRC32
	// result[63:32] = CRC32C
	//------------------------------------------------------------------------------------
	rule reqWriteResult( reqWriteResultOn );
		writeReqQs[1].enq(MemPortReq{addr:fromInteger(valueOf(ResultAddrStart)), bytes:64});
		reqWriteResultOn <= False;
		writeResultOn <= True;
	endrule
	rule writeResult( writeResultOn );
		let r = resultQ.first;
		resultQ.deq;
		writeWordQs[1].enq(r);

		$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : Wrote result word\n", cycleCounter );

		writeResultOn <= False;
		started <= False;
		doneQ.enq(True);
	endrule
	//------------------------------------------------------------------------------------
	// Interface
	//------------------------------------------------------------------------------------
	Vector#(MemPortCnt, MemPortIfc) mem_;
	for (Integer i = 0; i < valueOf(MemPortCnt); i = i + 1) begin
		mem_[i] = interface MemPortIfc;
			method ActionValue#(MemPortReq) readReq;
				readReqQs[i].deq;
				return readReqQs[i].first;
			endmethod
			method ActionValue#(MemPortReq) writeReq;
				writeReqQs[i].deq;
				return writeReqQs[i].first;
			endmethod
			method ActionValue#(Bit#(512)) writeWord;
				writeWordQs[i].deq;
				return writeWordQs[i].first;
			endmethod
			method Action readWord(Bit#(512) word);
				readWordQs[i].enq(word);
			endmethod
		endinterface;
	end
	method Action start(Bit#(32) param) if ( started == False );
		startQ.enq(True);
	endmethod
	method ActionValue#(Bool) done;
		doneQ.deq;
		return doneQ.first;
	endmethod
	interface mem = mem_;
endmodule
