import FIFO::*;
import FIFOF::*;
import Vector::*;

import BRAM::*;
import BRAMFIFO::*;
import BLShifter::*;


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
	FIFO#(Bit#(32)) startQ <- mkFIFO;
	FIFO#(Bool) doneQ  <- mkFIFO;

	FIFO#(Bit#(64)) dataQ_X <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(64)) dataQ_Y <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(512)) resultQ <- mkSizedBRAMFIFO(64);

	BLShiftIfc#(Bit#(64), 6, 1) shifter_L_6_1 <- mkPipelinedShift(False);
	BLShiftIfc#(Bit#(64), 6, 1) shifter_R_6_1 <- mkPipelinedShift(True);
	BLShiftIfc#(Bit#(64), 6, 2) shifter_L_6_2 <- mkPipelinedShift(False);
	BLShiftIfc#(Bit#(64), 6, 2) shifter_R_6_2 <- mkPipelinedShift(True);
	BLShiftIfc#(Bit#(64), 6, 6) shifter_L_6_6 <- mkPipelinedShift(False);
	BLShiftIfc#(Bit#(64), 6, 6) shifter_R_6_6 <- mkPipelinedShift(True);
	BLShiftIfc#(Bit#(64), 5, 2) shifter_L_5_2 <- mkPipelinedShift(False);
	BLShiftIfc#(Bit#(64), 5, 2) shifter_R_5_2 <- mkPipelinedShift(True);

	FIFO#(Bit#(64)) resultQ_L_6_1 <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(64)) resultQ_R_6_1 <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(64)) resultQ_L_6_2 <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(64)) resultQ_R_6_2 <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(64)) resultQ_L_6_6 <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(64)) resultQ_R_6_6 <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(64)) resultQ_L_5_2 <- mkSizedBRAMFIFO(64);
	FIFO#(Bit#(64)) resultQ_R_5_2 <- mkSizedBRAMFIFO(64);

	Reg#(Bool) started <- mkReg(False);
	Reg#(Bool) reqReadDataOn_X <- mkReg(False);
	Reg#(Bool) readDataOn_X <- mkReg(False);
	Reg#(Bool) reqReadDataOn_Y <- mkReg(False);
	Reg#(Bool) readDataOn_Y <- mkReg(False);
	Reg#(Bool) reqWriteResultOn <- mkReg(False);
	Reg#(Bool) writeResultOn <- mkReg(False);

	Reg#(Bit#(32)) dataCntTotal <- mkReg(0);
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
	// [Memory Read / Write FIFOs]
	//------------------------------------------------------------------------------------
	Vector#(MemPortCnt, FIFO#(MemPortReq)) readReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(MemPortReq)) writeReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) writeWordQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) readWordQs <- replicateM(mkFIFO);
	//------------------------------------------------------------------------------------
	// [Counters & Addresses]
	//------------------------------------------------------------------------------------
	Reg#(Bit#(32)) reqReadDataCnt_X <- mkReg(0);
	Reg#(Bit#(32)) readDataCnt_X <- mkReg(0);
	Reg#(Bit#(32)) reqReadDataCnt_Y <- mkReg(0);
	Reg#(Bit#(32)) readDataCnt_Y <- mkReg(0);
	Reg#(Bit#(32)) runExampleCnt <- mkReg(0);
	Reg#(Bit#(32)) packResultCnt <- mkReg(0);
	Reg#(Bit#(32)) reqWriteResultCnt <- mkReg(0);
	Reg#(Bit#(32)) writeResultCnt <- mkReg(0);

	Reg#(Bit#(64)) memPortAddr_0 <- mkReg(fromInteger(valueOf(MemPortAddrStart_0)));
	Reg#(Bit#(64)) memPortAddr_1 <- mkReg(fromInteger(valueOf(MemPortAddrStart_1)));
	Reg#(Bit#(64)) resultAddr <- mkReg(fromInteger(valueOf(ResultAddrStart)));
	//------------------------------------------------------------------------------------
	// [System Start]
	//------------------------------------------------------------------------------------
	rule systemStart( !started );
		let dataCnt = startQ.first;
		startQ.deq;

		if ( dataCnt == 0 ) begin
			doneQ.enq(True);
		end else begin
			started <= True;
			reqReadDataOn_X <= True;
			reqReadDataOn_Y <= True;
			reqWriteResultOn <= False;
			writeResultOn <= False;

			dataCntTotal <= dataCnt;

			reqReadDataCnt_X <= 0;
			readDataCnt_X <= 0;
			reqReadDataCnt_Y <= 0;
			readDataCnt_Y <= 0;
			runExampleCnt <= 0;
			packResultCnt <= 0;
			reqWriteResultCnt <= 0;
			writeResultCnt <= 0;

			memPortAddr_0 <= fromInteger(valueOf(MemPortAddrStart_0));
			memPortAddr_1 <= fromInteger(valueOf(MemPortAddrStart_1));
			resultAddr <= fromInteger(valueOf(ResultAddrStart));

			cycleStart <= cycleCounter;
			cycleDone <= 0;

			$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : BLShifter example is started! (count=%u)\n", cycleCounter, dataCnt );
		end
	endrule
	//------------------------------------------------------------------------------------
	// [Memory Read]
	//------------------------------------------------------------------------------------
	// Read the example data 'X' [MEMPORT 0]
	rule reqReadDataX( reqReadDataOn_X );
		readReqQs[0].enq(MemPortReq{addr:memPortAddr_0, bytes:64});

		if ( reqReadDataCnt_X + 1 == dataCntTotal ) begin
			memPortAddr_0 <= 0;
			reqReadDataCnt_X <= 0;
			reqReadDataOn_X	<= False;
		end else begin
			memPortAddr_0 <= memPortAddr_0 + 64;
			reqReadDataCnt_X <= reqReadDataCnt_X + 1;
		end

		readDataOn_X <= True;
	endrule
	rule readDataX( readDataOn_X );
		let data = readWordQs[0].first;
		readWordQs[0].deq;
	
		dataQ_X.enq(data[63:0]);
		
		if ( readDataCnt_X + 1 == dataCntTotal ) begin
			readDataCnt_X <= 0;
			readDataOn_X <= False;
			$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : Reading data X is done!\n", cycleCounter );
		end else begin
			readDataCnt_X <= readDataCnt_X + 1;
		end
	endrule

	// Read the example data 'Y' [MEMPORT 1]
	rule reqReadDataY( reqReadDataOn_Y );
		readReqQs[1].enq(MemPortReq{addr:memPortAddr_1, bytes:64});

		if ( reqReadDataCnt_Y + 1 == dataCntTotal ) begin
			memPortAddr_1 <= 0;
			reqReadDataCnt_Y <= 0;
			reqReadDataOn_Y	<= False;
		end else begin
			memPortAddr_1 <= memPortAddr_1 + 64;
			reqReadDataCnt_Y <= reqReadDataCnt_Y + 1;
		end

		readDataOn_Y <= True;
	endrule
	rule readDataY( readDataOn_Y );
		let data = readWordQs[1].first;
		readWordQs[1].deq;
	
		dataQ_Y.enq(data[63:0]);
		
		if ( readDataCnt_Y + 1 == dataCntTotal ) begin
			readDataCnt_Y <= 0;
			readDataOn_Y <= False;
			reqWriteResultOn <= True;
			writeResultOn <= True;
			$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : Reading data Y is done!\n", cycleCounter );
		end else begin
			readDataCnt_Y <= readDataCnt_Y + 1;
		end
	endrule
	//------------------------------------------------------------------------------------
	// Example Logic
	//------------------------------------------------------------------------------------
	// Input  [MEMPORT 0 / 512b]
	//   lane0 [ 63:  0] : input data
	// Input  [MEMPORT 1 / 512b]
	//   lane0 [ 63:  0] : shift amount
	// Output [MEMPORT 1 / 512b]
	//   lane0 : Left  shift (shiftsz=6, shift_bits_per_stage=1)
	//   lane1 : Right shift (shiftsz=6, shift_bits_per_stage=1)
	//   lane2 : Left  shift (shiftsz=6, shift_bits_per_stage=2)
	//   lane3 : Right shift (shiftsz=6, shift_bits_per_stage=2)
	//   lane4 : Left  shift (shiftsz=6, shift_bits_per_stage=6)
	//   lane5 : Right shift (shiftsz=6, shift_bits_per_stage=6)
	//   lane6 : Left  shift (shiftsz=5, shift_bits_per_stage=2)
	//   lane7 : Right shift (shiftsz=5, shift_bits_per_stage=2)
	//------------------------------------------------------------------------------------
	// Step 1
	rule example_step1( started );
		let x = dataQ_X.first;
		let y = dataQ_Y.first;
		dataQ_X.deq;
		dataQ_Y.deq;

		Bit#(6) shift6 = truncate(y);
		Bit#(5) shift5 = truncate(y);

		shifter_L_6_1.enq(x, shift6);
		shifter_R_6_1.enq(x, shift6);
		shifter_L_6_2.enq(x, shift6);
		shifter_R_6_2.enq(x, shift6);
		shifter_L_6_6.enq(x, shift6);
		shifter_R_6_6.enq(x, shift6);
		shifter_L_5_2.enq(x, shift5);
		shifter_R_5_2.enq(x, shift5);

		runExampleCnt <= runExampleCnt + 1;
		if ( runExampleCnt + 1 == dataCntTotal ) begin
			$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : Feeding BLShifter input data is done!\n", cycleCounter );
		end
	endrule
	// Step 2
	rule example_step2_L_6_1( started );
		let r = shifter_L_6_1.first;
		shifter_L_6_1.deq;
		resultQ_L_6_1.enq(r);
	endrule
	rule example_step2_R_6_1( started );
		let r = shifter_R_6_1.first;
		shifter_R_6_1.deq;
		resultQ_R_6_1.enq(r);
	endrule
	rule example_step2_L_6_2( started );
		let r = shifter_L_6_2.first;
		shifter_L_6_2.deq;
		resultQ_L_6_2.enq(r);
	endrule
	rule example_step2_R_6_2( started );
		let r = shifter_R_6_2.first;
		shifter_R_6_2.deq;
		resultQ_R_6_2.enq(r);
	endrule
	rule example_step2_L_6_6( started );
		let r = shifter_L_6_6.first;
		shifter_L_6_6.deq;
		resultQ_L_6_6.enq(r);
	endrule
	rule example_step2_R_6_6( started );
		let r = shifter_R_6_6.first;
		shifter_R_6_6.deq;
		resultQ_R_6_6.enq(r);
	endrule
	rule example_step2_L_5_2( started );
		let r = shifter_L_5_2.first;
		shifter_L_5_2.deq;
		resultQ_L_5_2.enq(r);
	endrule
	rule example_step2_R_5_2( started );
		let r = shifter_R_5_2.first;
		shifter_R_5_2.deq;
		resultQ_R_5_2.enq(r);
	endrule

	rule example_step3( started );
		let r_L_6_1 = resultQ_L_6_1.first;
		let r_R_6_1 = resultQ_R_6_1.first;
		let r_L_6_2 = resultQ_L_6_2.first;
		let r_R_6_2 = resultQ_R_6_2.first;
		let r_L_6_6 = resultQ_L_6_6.first;
		let r_R_6_6 = resultQ_R_6_6.first;
		let r_L_5_2 = resultQ_L_5_2.first;
		let r_R_5_2 = resultQ_R_5_2.first;

		resultQ_L_6_1.deq;
		resultQ_R_6_1.deq;
		resultQ_L_6_2.deq;
		resultQ_R_6_2.deq;
		resultQ_L_6_6.deq;
		resultQ_R_6_6.deq;
		resultQ_L_5_2.deq;
		resultQ_R_5_2.deq;

		resultQ.enq({r_R_5_2, r_L_5_2, r_R_6_6, r_L_6_6, r_R_6_2, r_L_6_2, r_R_6_1, r_L_6_1});

		packResultCnt <= packResultCnt + 1;
		if ( packResultCnt + 1 == dataCntTotal ) begin
			$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : Running BLShifter example is done!\n", cycleCounter );
		end
	endrule
	//------------------------------------------------------------------------------------
	// [Memory Write] & [System Finish]
	// Memory Writer is going to use PLRAM[1]
	//------------------------------------------------------------------------------------
	rule reqWriteResult( reqWriteResultOn && ( reqWriteResultCnt < packResultCnt ) );
		writeReqQs[1].enq(MemPortReq{addr:resultAddr, bytes:64});
		
		if ( reqWriteResultCnt + 1 == dataCntTotal ) begin
			resultAddr <= 0;
			reqWriteResultCnt <= reqWriteResultCnt + 1;
			reqWriteResultOn <= False;
		end else begin
			resultAddr <= resultAddr + 64;
			reqWriteResultCnt <= reqWriteResultCnt + 1;
		end
	endrule
	rule writeResult( writeResultOn && ( writeResultCnt < reqWriteResultCnt ) );
		let r = resultQ.first;
		resultQ.deq;
		writeWordQs[1].enq(r);

		if ( writeResultCnt + 1 == dataCntTotal ) begin
			cycleDone <= cycleCounter;
			writeResultCnt <= writeResultCnt + 1;
			writeResultOn <= False;
			started	<= False;
			doneQ.enq(True);
			$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : Writing BLShifter result is done!\n", cycleCounter );
			$write( "\033[1;32mCycle %u\033[0m -> \033[1;33m[KernelMain]\033[0m : Total cycle = %u\n", cycleCounter, cycleCounter - cycleStart );
		end else begin
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
	method Action start(Bit#(32) param) if ( started == False );
		startQ.enq(param);
	endmethod
	method ActionValue#(Bool) done;
		let d = doneQ.first;
		doneQ.deq;
		return d;
	endmethod
	interface mem = mem_;
endmodule
