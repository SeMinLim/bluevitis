package TestKernelTrace;

import RegFile::*;
import KernelMain::*;

(* synthesize *)
module mkTestKernelTrace(Empty);
	KernelMainIfc dut <- mkKernelMain;
	RegFile#(Bit#(16), Bit#(512)) inputMemory <- mkRegFileLoad("input.hex", 0, 65535);
	RegFile#(Bit#(16), Bit#(512)) expectedMemory <- mkRegFileLoad("expected.hex", 0, 65535);
	RegFile#(Bit#(8), Bit#(64)) commands <- mkRegFileLoad("commands.hex", 0, 255);
	Reg#(Bool) runningR <- mkReg(False);
	Reg#(Bool) readStartedR <- mkReg(False);
	Reg#(Bool) writeStartedR <- mkReg(False);
	Reg#(Bool) doneSeenR <- mkReg(False);
	Reg#(Bit#(8)) commandIdxR <- mkReg(0);
	Reg#(Bit#(16)) inputIdxR <- mkReg(0);
	Reg#(Bit#(16)) outputIdxR <- mkReg(0);
	Reg#(UInt#(32)) inputRemainingR <- mkReg(0);
	Reg#(UInt#(32)) outputRemainingR <- mkReg(0);
	Reg#(UInt#(32)) cycleCntR <- mkReg(0);

	rule tick;
		cycleCntR <= cycleCntR + 1;
		if ( cycleCntR == 10000000 ) begin
			$display("FAIL: kernel trace timeout");
			$finish(1);
		end
	endrule

	rule start1 ( !runningR );
		Bit#(64) command = commands.sub(commandIdxR);
		if ( command == 0 ) begin
			$display("PASS: kernel trace commands=%0d output_words=%0d cycles=%0d",
				commandIdxR, outputIdxR, cycleCntR);
			$finish(0);
		end else begin
			Bit#(32) inputWords = command[63:32];
			dut.start(inputWords << 6);
			inputRemainingR <= unpack(inputWords);
			outputRemainingR <= unpack(command[31:0]);
			readStartedR <= False;
			writeStartedR <= False;
			doneSeenR <= False;
			runningR <= True;
		end
	endrule

	rule readRequest1 ( runningR && !readStartedR );
		let request <- dut.inputReadReq;
		Bit#(32) inputBytes = pack(inputRemainingR) << 6;
		if ( request.addr != 0 || request.bytes != inputBytes ) begin
			$display("FAIL: input request length/address");
			$finish(1);
		end
		readStartedR <= True;
	endrule

	rule writeRequest1 ( runningR && !writeStartedR );
		let request <- dut.outputWriteReq;
		Bit#(32) outputBytes = pack(outputRemainingR) << 6;
		if ( request.addr != 0 || request.bytes != outputBytes ) begin
			$display("FAIL: output request length/address");
			$finish(1);
		end
		writeStartedR <= True;
	endrule

	rule send1 ( runningR && readStartedR && inputRemainingR != 0 && cycleCntR % 17 != 7 );
		dut.inputReadWord(inputMemory.sub(inputIdxR));
		inputIdxR <= inputIdxR + 1;
		inputRemainingR <= inputRemainingR - 1;
	endrule

	rule receive1 ( runningR && writeStartedR && outputRemainingR != 0 && cycleCntR % 19 != 5 );
		let actual <- dut.outputWriteWord;
		Bit#(512) expected = expectedMemory.sub(outputIdxR);
		Bit#(512) mask = '1;
		// Only the device cycle counter differs from the software oracle.
		if ( expected[55:48] == 8'hff ) mask[159:128] = 0;
		$display("TRACE_WORD:%h", actual & mask);
		if ( (actual & mask) != (expected & mask) ) begin
			$display("FAIL: command=%0d output_word=%0d", commandIdxR, outputIdxR);
			$display("expected=%h", expected);
			$display("actual  =%h", actual);
			$finish(1);
		end
		outputIdxR <= outputIdxR + 1;
		outputRemainingR <= outputRemainingR - 1;
	endrule

	rule done1 ( runningR && !doneSeenR );
		let done <- dut.done;
		if ( !done ) begin
			$display("FAIL: invalid completion");
			$finish(1);
		end
		doneSeenR <= True;
	endrule

	rule next1 ( runningR && doneSeenR && inputRemainingR == 0 && outputRemainingR == 0 );
		commandIdxR <= commandIdxR + 1;
		runningR <= False;
	endrule
endmodule

endpackage
