import FIFO::*;
import FIFOF::*;
import Vector::*;

import BRAM::*;
import BRAMFIFO::*;

import URAM::*;
import URAMFIFO::*;


typedef 1 DataCntTotal512b_X;
typedef 1 DataCntTotal512b_Y;

typedef 0 MemPortAddrStart_0;
typedef 0 MemPortAddrStart_1;
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
	FIFO#(Bool) startQ <- mkFIFO;
	FIFO#(Bool) doneQ  <- mkFIFO;

	FIFO#(Bit#(512)) dataQ_X <- mkSizedBRAMFIFO(8);
	FIFO#(Bit#(512)) dataQ_Y <- mkSizedBRAMFIFO(8);
	FIFO#(Bit#(512)) resultQ <- mkSizedBRAMFIFO(8);

	Reg#(Bool) started <- mkReg(False);

	Reg#(Bool) reqReadDataOn_X <- mkReg(False);
	Reg#(Bool) readDataOn_X <- mkReg(False);
	Reg#(Bool) reqReadUramOn_X <- mkReg(False);
	Reg#(Bool) readUramOn_X <- mkReg(False);

	Reg#(Bool) reqReadDataOn_Y <- mkReg(False);
	Reg#(Bool) readDataOn_Y <- mkReg(False);
	Reg#(Bool) reqReadUramOn_Y <- mkReg(False);
	Reg#(Bool) readUramOn_Y <- mkReg(False);

	Reg#(Bool) examOn <- mkReg(False);
	Reg#(Bool) reqWriteResultOn <- mkReg(False);
	Reg#(Bool) writeResultOn <- mkReg(False);
	//------------------------------------------------------------------------------------
	// [Cycle Counter]
	//------------------------------------------------------------------------------------
	Reg#(Bit#(32)) cycleCounter <- mkReg(0);
	Reg#(Bit#(32)) cycleStart <- mkReg(0);
	Reg#(Bit#(32)) cycleDone <- mkReg(0);
	rule incCycle;
		cycleCounter <= cycleCounter + 1;
	endrule
	//------------------------------------------------------------------------------------
	// [URAM]
	//------------------------------------------------------------------------------------
	URAM_Configure cfg = defaultValue;
	URAM2Port#(Bit#(10), Bit#(512)) uramX <- mkURAM2Server(cfg);
	URAM2Port#(Bit#(10), Bit#(512)) uramY <- mkURAM2Server(cfg);
	//------------------------------------------------------------------------------------
	// [System Start]
	//------------------------------------------------------------------------------------
	rule systemStart( !started );
		startQ.deq;
		started <= True;
		reqReadDataOn_X	<= True;
		reqReadDataOn_Y	<= True;
		examOn <= True;
	endrule
	//------------------------------------------------------------------------------------
	// [Memory Read]
	//------------------------------------------------------------------------------------
	Vector#(MemPortCnt, FIFO#(MemPortReq)) readReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(MemPortReq)) writeReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) writeWordQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) readWordQs <- replicateM(mkFIFO);

	// Read the example data 'X'		[MEMPORT 0]
	Reg#(Bit#(32)) reqReadDataCnt_X <- mkReg(0);
	Reg#(Bit#(64)) memPortAddr_0 <- mkReg(fromInteger(valueOf(MemPortAddrStart_0)));
	rule reqReadDataX( reqReadDataOn_X );
		readReqQs[0].enq(MemPortReq{addr:memPortAddr_0, bytes:64});

		if ( reqReadDataCnt_X + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			memPortAddr_0 <= 0;
			reqReadDataCnt_X <= 0;
			reqReadDataOn_X <= False;
			$display( "[KernelMain] Requesting Global Memory Port A is Done!" );
		end else begin
			if ( reqReadDataCnt_X == 0 ) $display( "[KernelMain] Requesting Global Memory Port A is Started!" );
			memPortAddr_0 <= memPortAddr_0 + 64;
			reqReadDataCnt_X <= reqReadDataCnt_X + 1;
		end

		readDataOn_X <= True;
	endrule
	Reg#(Bit#(32)) readDataCnt_X <- mkReg(0);
	Reg#(Bit#(10)) uramWriteAddr_X <- mkReg(0);
	rule readDataX( readDataOn_X );
		readWordQs[0].deq;
		let data = readWordQs[0].first;
	
		uramX.portA.request.put(URAMRequest{write:True, responseOnWrite:False, address:uramWriteAddr_X, datain:data});
		
		if ( readDataCnt_X + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			uramWriteAddr_X <= 0;
			readDataCnt_X <= 0;
			readDataOn_X <= False;
			reqReadUramOn_X <= True;
			$display( "[KernelMain] Reading Global Memory Port A is Done!" );
		end else begin
			if ( readDataCnt_X == 0 ) $display( "[KernelMain] Reading Global Memory Port A is Started!" );
			uramWriteAddr_X <= uramWriteAddr_X + 1;
			readDataCnt_X <= readDataCnt_X + 1;
		end

		cycleStart <= cycleCounter;
	endrule
	Reg#(Bit#(32)) reqReadUramCnt_X <- mkReg(0);
	Reg#(Bit#(10)) uramReadAddr_X <- mkReg(0);
	rule reqReadUramX( reqReadUramOn_X );
		uramX.portB.request.put(URAMRequest{write:False, responseOnWrite:False, address:uramReadAddr_X, datain:?});

		if ( reqReadUramCnt_X + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			uramReadAddr_X <= 0;
			reqReadUramCnt_X <= 0;
			reqReadUramOn_X <= False;
			$display( "[KernelMain] Requesting URAM_X is Done!" );
		end else begin
			if ( reqReadUramCnt_X == 0 ) $display( "[KernelMain] Requesting URAM_X is Started!" );
			uramReadAddr_X <= uramReadAddr_X + 1;
			reqReadUramCnt_X <= reqReadUramCnt_X + 1;
		end

		readUramOn_X <= True;
	endrule
	Reg#(Bit#(32)) readUramCnt_X <- mkReg(0);
	rule readUramX( readUramOn_X );
		let d <- uramX.portB.response.get();
		dataQ_X.enq(d);

		if ( readUramCnt_X + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			readUramCnt_X <= 0;
			readUramOn_X <= False;
			$display( "[KernelMain] Reading URAM_X is Done!" );
		end else begin
			if ( readUramCnt_X == 0 ) $display( "[KernelMain] Reading URAM_X is Started!" );
			readUramCnt_X <= readUramCnt_X + 1;
		end
	endrule

	// Read the example data 'Y'		[MEMPORT 1]
	Reg#(Bit#(32)) reqReadDataCnt_Y <- mkReg(0);
	Reg#(Bit#(64)) memPortAddr_1 <- mkReg(fromInteger(valueOf(MemPortAddrStart_1)));
	rule reqReadDataY( reqReadDataOn_Y );
		readReqQs[1].enq(MemPortReq{addr:memPortAddr_1, bytes:64});

		if ( reqReadDataCnt_Y + 1 == fromInteger(valueOf(DataCntTotal512b_Y)) ) begin
			memPortAddr_1 <= 0;
			reqReadDataCnt_Y <= 0;
			reqReadDataOn_Y <= False;
			$display( "[KernelMain] Requesting Global Memory Port B is Done!" );
		end else begin
			if ( reqReadDataCnt_Y == 0 ) $display( "[KernelMain] Requesting Global Memory Port B is Started!" );
			memPortAddr_1 <= memPortAddr_1 + 64;
			reqReadDataCnt_Y <= reqReadDataCnt_Y + 1;
		end

		readDataOn_Y <= True;
	endrule
	Reg#(Bit#(32)) readDataCnt_Y <- mkReg(0);
	Reg#(Bit#(10)) uramWriteAddr_Y <- mkReg(0);
	rule readDataY( readDataOn_Y );
		readWordQs[1].deq;
		let data = readWordQs[1].first;
	
		uramY.portA.request.put(URAMRequest{write:True, responseOnWrite:False, address:uramWriteAddr_Y, datain:data});
		
		if ( readDataCnt_Y + 1 == fromInteger(valueOf(DataCntTotal512b_Y)) ) begin
			uramWriteAddr_Y <= 0;
			readDataCnt_Y <= 0;
			readDataOn_Y <= False;
			reqReadUramOn_Y <= True;
			$display( "[KernelMain] Reading Global Memory Port B is Done!" );
		end else begin
			if ( readDataCnt_Y == 0 ) $display( "[KernelMain] Reading Global Memory Port B is Started!" );
			uramWriteAddr_Y <= uramWriteAddr_Y + 1;
			readDataCnt_Y <= readDataCnt_Y + 1;
		end
	endrule
	Reg#(Bit#(32)) reqReadUramCnt_Y <- mkReg(0);
	Reg#(Bit#(10)) uramReadAddr_Y <- mkReg(0);
	rule reqReadUramY( reqReadUramOn_Y );
		uramY.portB.request.put(URAMRequest{write:False, responseOnWrite:False, address:uramReadAddr_Y, datain:?});

		if ( reqReadUramCnt_Y + 1 == fromInteger(valueOf(DataCntTotal512b_Y)) ) begin
			uramReadAddr_Y <= 0;
			reqReadUramCnt_Y <= 0;
			reqReadUramOn_Y <= False;
			$display( "[KernelMain] Requesting URAM_Y is Done!" );
		end else begin
			if ( reqReadUramCnt_Y == 0 ) $display( "[KernelMain] Reading URAM_Y is Started!" );
			uramReadAddr_Y <= uramReadAddr_Y + 1;
			reqReadUramCnt_Y <= reqReadUramCnt_Y + 1;
		end

		readUramOn_Y <= True;
	endrule
	Reg#(Bit#(32)) readUramCnt_Y <- mkReg(0);
	rule readUramY( readUramOn_Y );
		let d <- uramY.portB.response.get();
		dataQ_Y.enq(d);

		if ( readUramCnt_Y + 1 == fromInteger(valueOf(DataCntTotal512b_Y)) ) begin
			readUramCnt_Y <= 0;
			readUramOn_Y <= False;
			$display( "[KernelMain] Reading URAM_Y is Done!" );
		end else begin
			if ( readUramCnt_Y == 0 ) $display( "[KernelMain] Reading URAM_Y is Started!" );
			readUramCnt_Y <= readUramCnt_Y + 1;
		end

		reqWriteResultOn <= True;
	endrule
	//------------------------------------------------------------------------------------
	// Example Logic
	//------------------------------------------------------------------------------------
	Reg#(Bit#(32)) examCnt <- mkReg(0);
	rule example_2( examOn );
		dataQ_X.deq;
		dataQ_Y.deq;
		let x = dataQ_X.first;
		let y = dataQ_Y.first;

		Bit#(512) r = x + y;
		
		resultQ.enq(r);

		if ( examCnt + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			examCnt <= 0;
			examOn <= False;
			$display( "[KernelMain] Running Example Logic is Done!" );
		end else begin
			if ( examCnt == 0 ) $display( "[KernelMain] Running Example Logic is Started!" );
			examCnt <= examCnt + 1;
		end
	endrule
	//------------------------------------------------------------------------------------
	// [Memory Write] & [System Finish]
	// Memory Writer is going to use global memory port 2 
	//------------------------------------------------------------------------------------
	Reg#(Bit#(32)) reqWriteResultCnt <- mkReg(0);
	rule reqWriteResult( reqWriteResultOn );
		writeReqQs[1].enq(MemPortReq{addr:fromInteger(valueOf(ResultAddrStart)), bytes:64});
		

		if ( reqWriteResultCnt + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			reqWriteResultCnt <= 0;
			reqWriteResultOn <= False;
			$display( "[KernelMain] Requesting of Writing Result is Done!" );
		end else begin
			if ( reqWriteResultCnt == 0 ) $display( "[KernelMain] Requesting of Writing Result is Started!" );
			reqWriteResultCnt <= reqWriteResultCnt + 1;
		end

		writeResultOn <= True;
	endrule
	Reg#(Bit#(32)) writeResultCnt <- mkReg(0);
	rule writeResult( writeResultOn );
		resultQ.deq;
		let r = resultQ.first;
		writeWordQs[1].enq(r);
		
		if ( writeResultCnt + 1 == fromInteger(valueOf(DataCntTotal512b_X)) ) begin
			writeResultCnt <= 0;
			writeResultOn <= False;
			started <= False;
			doneQ.enq(True);
			$display( "[KernelMain] Writing Result is Done!" );
		end else begin
			if ( writeResultCnt == 0 ) $display( "[KernelMain] Writing Result is Started!" );
			writeResultCnt <= writeResultCnt + 1;
		end
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
